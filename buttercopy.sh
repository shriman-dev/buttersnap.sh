#!/usr/bin/env bash
set -euo pipefail

BTRFS=("btrfs")
READONLY=false
QUIET=false
VERBOSE=

declare -r red=$'\033[31m' green=$'\033[32m' blue=$'\033[34m' cyan=$'\033[36m' yellow=$'\033[33m'
declare -r bold=$'\033[1m' normal=$'\033[0m'

# Logging with optional verbose output
log() {
    local level="${1^^}" color; shift
    local msg="$*" datetime=""

    [[ ${QUIET} == true ]] && return 0
    [[ "${level}" == "DEBUG" && ${VERBOSE:-0} -le 1 ]] && return 0
    [[ ${VERBOSE:-0} -ge 3 ]] && datetime="$(date '+[%Y-%m-%d %H:%M:%S] ')"

    case "${level}" in
        DEBUG) color="${cyan}"   ;;
        INFO)  color="${green}"  ;;
        NOTE)  color="${blue}"   ;;
        WARN)  color="${yellow}" ;;
        ERROR) color="${red}"    ;;
        *)     return 1 ;;
    esac

    echo -e "${bold}${datetime}${color}[${level^^}]${normal} ${msg}"
}

# Error handling with optional pre-exit function call
die() {
    local pre_exit_hook="${2:-}"
    [[ -n "${pre_exit_hook}" ]] && { ${pre_exit_hook} || true; }
    log "ERROR" "${1}" >&2; exit 1
}

err() { log "ERROR" "${1}" >&2; }

need_root() {
    [[ ${EUID} -eq 0 ]] || die "This operation requires root privileges"
}

# Checks if last modification time of file/directory is older than a specified seconds
is_older_than() {
    local target_path threshold_sec target_mtime_sec current_time_sec targett_aged_sec
    target_path="${1%/}"
    threshold_sec=${2}

    [[ -e "${target_path}" ]] || die "Does not exist: ${target_path}"
    [[ "${threshold_sec}" =~ ^[0-9]+$ ]] || die "Not an integer: ${threshold_sec}"

    target_mtime_sec=$(stat -c "%Y" "${target_path}")
    current_time_sec=$(date +%s)
    targett_aged_sec=$(( current_time_sec - target_mtime_sec ))

    if [[ ${targett_aged_sec} -gt ${threshold_sec} ]]; then
        return 0
    else
        return 1
    fi
}

check_filesystem() {
    local mode="${1}"; shift
    local path_a="${1}" path_b="${2}" fs_a fs_b

    [[ -e "${path_a}" ]] || die "Does not exist: ${path_a}"
    [[ -e "${path_b}" ]] || die "Does not exist: ${path_b}"

    fs_a="$(findmnt -n -o SOURCE --target "${path_a}" | cut -d'[' -f1)"
    fs_b="$(findmnt -n -o SOURCE --target "${path_b}" | cut -d'[' -f1)"

    case "${mode}" in
        same)
            log "DEBUG" "Validating paths are on same filesystem:\n\t${path_a}\n\t${path_b}"
            if [[ "${fs_a}" != "${fs_b}" ]]; then
                die "Paths are not on same filesystem\n\t${path_a} (${fs_a})\n\t${path_b} (${fs_b})"
            fi
            ;;
        diff)
            log "DEBUG" \
                "Validating that paths are on different filesystems:\n\t${path_a}\n\t${path_b}"
            if [[ "${fs_a}" == "${fs_b}" ]]; then
                die "Paths are on same filesystem\n\t${path_a} (${fs_a})\n\t${path_b} (${fs_b})"
            fi
            ;;
        *)
            die "Usage: check_filesystem <same|diff> <path_a> <path_b>"
            ;;
    esac
}

validate_path() {
    local path fs_check="" path_fs=""
    [[ $# -eq 0 ]] && die "No path provided to validate"

    # Identify if first arg is a filesystem type instead of a path
    if [[ ! "${1}" =~ "/" ]]; then
        fs_check="${1}"
        shift
    fi

    for path in "$@"; do
        [[ ! -d "${path}" ]] && die "Path does not exist: ${path}"
        if [[ -n "${fs_check}" ]]; then
            log "DEBUG" "Validating path exists on ${fs_check} filesystem: ${path}"
            path_fs="$(stat -f -c '%T' "${path}")"
            [[ "${path_fs,,}" == "${fs_check,,}" ]] ||
                die "Path is not on ${fs_check} filesystem: ${path}"
        fi
    done
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

copy_operation() {
    local src_subvol="${1%/}" dst_btrfs_vol="${2%/}" copy_suffix="buttercopy"
    local dst_subvol_name="${3:-$(basename "${src_subvol}")}"
    local btrfs_list btrfs_snap btrfs_send btrfs_receive

    btrfs_del=("${BTRFS[@]}" "subvolume" "delete")
    btrfs_snap=("${BTRFS[@]}" "subvolume" "snapshot")
    btrfs_list=("${BTRFS[@]}" "subvolume" "list")
    btrfs_send=("${BTRFS[@]}" "send" "--compressed-data")
    btrfs_receive=("btrfs" "receive")
    [[ ${VERBOSE:-0} -ge 3 ]] && btrfs_receive+=("-v")

    local tmpdir suffix_src_subvol grep_pattern matched_subvol
    tmpdir="$(dirname "${src_subvol}")/.buttercopy_tmpd"
    suffix_src_subvol="$(basename "${src_subvol}")_${copy_suffix}"

    cleanup_temp() {
        local src_tmp="${tmpdir}/${suffix_src_subvol}"
        local dst_tmp="${dst_btrfs_vol}/${suffix_src_subvol}"

        [[ -d "${src_tmp}" ]] && "${btrfs_del[@]}" "${src_tmp}"
        [[ -d "${dst_tmp}" ]] && "${btrfs_del[@]}" "${dst_tmp}"
        [[ -d "${tmpdir}"  ]] && rm ${VERBOSE:+-v} -rf "${tmpdir}"
        return 0
    }

    die_msg() { die "${1}" "cleanup_temp"; }

    # Set trap to cleanup on termination
    trap 'die_msg "Operation was interrupted"' SIGTERM SIGINT
    # Cleanup any temp operation in case script crashed previously
    cleanup_temp

    # Check if subvolume with same name as dst_subvol_name already exists on destination volume
    grep_pattern="${dst_subvol_name}$|${dst_subvol_name}_${copy_suffix}$"
    matched_subvol="$("${btrfs_list[@]}" "${dst_btrfs_vol}" | grep -Ew "${grep_pattern}")" || true
    if [[ -n "${matched_subvol}" ]]; then
        [[ ${VERBOSE:-0} -ge 3 ]] && cat <<< "${matched_subvol}"
        err "Existing subvolume found with name '${dst_subvol_name}' on ${dst_btrfs_vol}"
        die_msg "Copy failed"
    fi

    log "INFO" "Sending full subvolume copy of: ${src_subvol}"
    log "INFO" "To BTRFS volume: ${dst_btrfs_vol}"
    # Take readonly temp-snapshot to send
    mkdir ${VERBOSE:+-v} -p "${tmpdir}"
    "${btrfs_snap[@]}" -r "${src_subvol}" "${tmpdir}/${suffix_src_subvol}" ||
        die_msg "Could not create readonly temp-snapshot of source: ${src_subvol}"

    # Send snapshot and receive on another volume
    "${btrfs_send[@]}" "${tmpdir}/${suffix_src_subvol}" | \
    "${btrfs_receive[@]}" "${dst_btrfs_vol}" ||
        die_msg "Could not send full copy to: ${dst_btrfs_vol}"

    # Name/Rename received snapshot
    log "DEBUG" "Creating '${dst_subvol_name}' subvolume on BTRFS volume: ${dst_btrfs_vol}"
    log "DEBUG" "Readonly status: ${READONLY}"
    [[ ${READONLY} == true ]] && btrfs_snap+=("-r")
    "${btrfs_snap[@]}" "${dst_btrfs_vol}/${suffix_src_subvol}" \
                       "${dst_btrfs_vol}/${dst_subvol_name}" ||
        die_msg "Could not create subvolume on: ${dst_btrfs_vol}"

    # Finally cleanup any temp operation
    cleanup_temp
    trap - SIGTERM SIGINT
    log "INFO" "Successfully sent full snapshot copy"
}

show_help() {
    cat <<EOF
Usage: $(basename "${0}") [options]

Options:
  -h, --help                       Show this help message
  -v, --verbose                    Enable verbose output (use -vv for debug mode)
  -r, --readonly <true|false>      Whether to create readonly snapshots (Default: false)
  -n, --custom-name <name>         Set a custom name for the destination subvolume
  -s, --src-subvolume <path>       Path to the source subvolume
  -d, --dst-volume <path>          Path to the destination BTRFS mount point

Notes:
  * Source subvolume and its parent directory must be on the same filesystem.
    Ideally, source subvolume must reside on the Btrfs root mount.

  * Source and destination must be on different filesystems.
    (use BTRFS snapshot for same-filesystem operations)

Example:
  $(basename "${0}") -r true -s /src/subvol -d /mnt/dst/ -n my_backup
EOF
}

main() {
    [[ $# -eq 0 ]] && die "No arguments provided" show_help
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -h|--help)
                show_help; exit 0
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -vv)
                VERBOSE=3
                shift
                ;;
            -r|--readonly)
                [[ "${2:-}" =~ ^(true|false)$ ]] || die "Invalid readonly value: ${2}"
                READONLY=${2}
                shift 2
                ;;
            -n|--custom-name)
                [[ -n "${2:-}" ]] || die "Provide custom name for sent subvolume on destination"
                CUSTOM_NAME="${2}"
                shift 2
                ;;
            -s|--src-subvolume)
                [[ -n "${2:-}" ]] || die "Provide source subvolume to copy"
                SRC_SUBVOLUME="${2}"
                shift 2
                ;;
            -d|--dst-volume)
                [[ -n "${2:-}" ]] || die "Provide path to directory on another BTRFS volume"
                DST_BTRFS_VOLUME="${2}"
                shift 2
                ;;
            *) die "Unknown option: ${1}" show_help
                ;;
        esac
    done

    need_root
    [[ -n "${VERBOSE:-}" ]] && BTRFS+=("-v")

    validate_path "btrfs" "${SRC_SUBVOLUME}" "${DST_BTRFS_VOLUME}"
    check_filesystem diff "${SRC_SUBVOLUME}" "${DST_BTRFS_VOLUME}"
    check_filesystem same "${SRC_SUBVOLUME}" "$(dirname "${SRC_SUBVOLUME}")"
    copy_operation "${SRC_SUBVOLUME}" "${DST_BTRFS_VOLUME}" "${CUSTOM_NAME:-}"
}

main "$@"

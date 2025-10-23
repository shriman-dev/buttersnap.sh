#!/bin/bash
READONLY=false
QUIET=false
VERBOSE=
BTRFS="btrfs ${VERBOSE:+-v}"
BTRFS2="$([[ ${VERBOSE} -eq 2 ]] && echo 'btrfs -v' || echo 'btrfs')"

declare -r red=$'\033[31m' green=$'\033[32m' yellow=$'\033[33m' cyan=$'\033[36m'
declare -r bold=$'\033[1m' normal=$'\033[0m'

# Logging with optional verbose output
log() {
    local color level="${1}" msg="${@:2}"
    local datetime="$([[ ${VERBOSE} -ge 2 ]] && date '+[%Y-%m-%d %H:%M:%S] ')"

    case "${level^^}" in
        "DEBUG") color=${cyan}; [[ ${QUIET} == false && ${VERBOSE} -eq 2 ]] || return ;;
        "INFO")  color=${green}; [[ ${QUIET} == false ]] || return ;;
        "WARN")  color=${yellow}; [[ ${QUIET} == false ]] || return  ;;
        "ERROR") color=${red} ;;
    esac

    echo -e "${bold}${datetime}${color}[${level^^}]${normal} ${msg}"
}

# Error handling with optional function call
die() { log "ERROR" "${1}"; [[ -n "${2}" ]] && ${2}; exit 1; }

err() { log "ERROR" "${1}"; return 1; }

need_root() {
    [[ $(id -u) -eq 0 ]] || die "This operation requires root privileges"
}

validate_path() {
    [[ $# -eq 0 ]] && err "No paths provided to validate"
    for path in "$@"; do
        [[ ! -d "${path}" ]] && die "Path does not exist: ${path}"
        log "DEBUG" "Validating path is on BTRFS filesystem: ${path}"
        findmnt -n -o FSTYPE -T "${path}" | grep -q "btrfs" || die "Path is not on a BTRFS filesystem: ${path}"
        log "DEBUG" "Path is on BTRFS filesystem."
    done
}

cleanup_command() {
    while [ $# -gt 0 ]; do
        case "${1}" in
            rm-tmpdir) rm ${VERBOSE:+-v} -rf "${tmpdir}";
                ;;
            del-src-suffix) ${BTRFS} subvolume delete "${tmpdir}/${suffix_src_subvol}";
                ;;
            del-dst-suffix) ${BTRFS} subvolume delete "${dst_btrfs_vol}/${suffix_src_subvol}";
                ;;
            *) die "Invalid cleanup command: ${1}"
                ;;
        esac
        shift
    done
}

copy_operation() {
    local src_subvol="${1%/}" dst_btrfs_vol="${2%/}" copy_suffix="buttercopy"
    local dst_subvol_name=${3:-"$(basename ${src_subvol})"} readonly="$([[ ${READONLY} == true ]] && echo '-r')"

    validate_path "${src_subvol}" "${dst_btrfs_vol}"
    [[ "$(findmnt -n -o UUID -T "$SRC_SUBVOLUME")" == "$(findmnt -n -o UUID -T "${dst_btrfs_vol}")" ]] &&
            die "Destination path is on the same BTRFS volume as the source subvolume"

    local grep_pattern="${dst_subvol_name}$|${dst_subvol_name}_${copy_suffix}$"
    local suffix_src_subvol="$(basename ${src_subvol})_${copy_suffix}"
    if ! ${BTRFS} subvolume list "${dst_btrfs_vol}" | grep -qEw "${grep_pattern}"; then
        log "INFO" "Sending full snapshot copy of ${src_subvol} to BTRFS volume: ${dst_btrfs_vol}"
        local tmpdir="$(dirname "${src_subvol}")/.tmpdir"
        mkdir ${VERBOSE:+-v} -p "${tmpdir}"
        ${BTRFS} subvolume snapshot -r "${src_subvol}" "${tmpdir}/${suffix_src_subvol}" ||
                die "Could not create readonly snapshot of source subvolume" "cleanup_command rm-tmpdir"
        ${BTRFS} send --compressed-data "${tmpdir}/${suffix_src_subvol}" | \
        ${BTRFS2} receive "${dst_btrfs_vol}" ||
                die "Could not send full copy to: ${dst_btrfs_vol}" "cleanup_command del-src-suffix rm-tmpdir"

        log "DEBUG" "Creating \"${dst_subvol_name}\" named subvolume on BTRFS volume: ${dst_btrfs_vol}"
        log "DEBUG" "Readonly status: ${READONLY}"
        ${BTRFS} subvolume snapshot ${readonly} "${dst_btrfs_vol}/${suffix_src_subvol}" \
                "${dst_btrfs_vol}/${dst_subvol_name}" ||
                die "Could not create subvolume on: ${dst_btrfs_vol}" \
                    "cleanup_command del-src-suffix del-dst-suffix rm-tmpdir"
        cleanup_command del-src-suffix del-dst-suffix rm-tmpdir
    else
        ${BTRFS} subvolume list "${dst_btrfs_vol}" | grep -Ew --color=always "${grep_pattern}"
        die "Copy failed. Existing subvolume found with name \"${dst_subvol_name}\" on ${dst_btrfs_vol}"
    fi

    log "INFO" "Done."
}

show_help() {
    echo "Usage: $(basename "${0}") [options] ..."
    echo "Options:"
    echo " -h, --help                       Show this help message"
    echo " -v, --verbose                    Enable verbose output (use -vv for debug verbosity)"
    echo " -r, --readonly <true|false>      Specify whether to create readonly snapshots (Default: false)"
    echo " -n, --custom-name                Set custom name for subvolume to be sent on destination"
    echo " -s, --src-subvolume              Specify source subvolume to copy"
    echo " -d, --dst-btrfs-volume           Specify path to another BTRFS volume to send full copy"
    echo ""
    echo "Examples usage:"
    echo " $(basename "${0}") -r true -n custom_name -s /path/to/src-subvolume -d /path/to/dir-on-btrfs-volume"
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
                VERBOSE=2
                shift
                ;;
            -r|--readonly)
                [[ "${2}" =~ ^(true|false)$ ]] || die "Invalid readonly value: ${2}"
                READONLY=${2}
                shift 2
                ;;
            -n|--custom-name)
                [[ $# -ge 2 ]] || die "Provide custom name for sent subvolume on destination"
                CUSTOM_NAME="${2}"
                shift 2
                ;;
            -s|--src-subvolume)
                [[ $# -ge 2 ]] || die "Provide source subvolume to copy"
                SRC_SUBVOLUME="${2}"
                shift 2
                ;;
            -d|--dst-btrfs-volume)
                [[ $# -ge 2 ]] || die "Provide path to directory on another BTRFS volume"
                DST_BTRFS_VOLUME="${2}"
                shift 2
                ;;
            *) die "Unknown option: ${1}" show_help
                ;;
        esac
    done

    need_root
    copy_operation ${SRC_SUBVOLUME} ${DST_BTRFS_VOLUME} ${CUSTOM_NAME}
}

main "$@"

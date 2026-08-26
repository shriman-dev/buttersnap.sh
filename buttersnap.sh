#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/buttercopy.sh" || exit 1

BTRFS=("btrfs")
SNAPSHOT_SRC=()
SNAPSHOT_DST=()
DELSNAP_DIRS=()
INTERVALS=""
DT_FORMAT="%H.%M.%S-%Y%m%d"
READONLY=true

convert_to_seconds() {
    # Define unit factors
    local -A factors
    factors=(
        ["minute"]=60 ["hour"]=3600 ["day"]=86400
        ["week"]=604800 ["month"]=2592000 ["year"]=31536000
    )

    [[ $# -eq 1 ]] || die "Exactly one argument expected"

    local arg="${1,,}" n unit
    if [[ ${arg} =~ ^every([0-9]+)(minute|hour|day|week|month|year)s?$ ]]; then
        echo "$(( BASH_REMATCH[1] * factors[${BASH_REMATCH[2]}] ))"
    elif [[ ${arg/dai/day} =~ ^(minute|hour|day|week|month|year)(ly)?$ ]]; then
        echo "${factors[${BASH_REMATCH[1]}]}"
    else
        die "Invalid interval: ${arg}"
    fi
}

# List immediate sub-directories sorted by modification time
# Oldest first
list_dirs_mtime() {
    local dir="${1}"
    [[ -d "${dir}" ]] || return 0 # End fucntion silently when directory does not exists
    find "${dir}" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %f\n' | sort -n | cut -d' ' -f2-
}

take_snap() {
    local src="${1%/}" dst="${2%/}" interval_dir="${3}"
    local btrfs_snap ts dst_path last_numdir interval_seconds new_numdir
    btrfs_snap=("${BTRFS[@]}" "subvolume" "snapshot")

    [[ ${READONLY} == true ]] && btrfs_snap+=("-r")

    do_snapshot() {
        log "DEBUG" "Readonly status: ${READONLY}"
        mkdir ${VERBOSE:+-v} -p "${dst_path}" || die "Failed to create directory ${dst_path}"
        "${btrfs_snap[@]}" "${src}" "${dst_path}/${ts}" ||
            { rm ${VERBOSE:+-v} -rf "${dst_path}"
                die "Could not create snapshot\n\tSource: ${src}\n\tSnapshot: ${dst_path}/${ts}"; }
    }

    # Mark destination directory
    [[ -f "${dst}/.buttersnap" ]] || touch "${dst}/.buttersnap"
    # Check if the first snapshot needs to be created
    if [[ ! -d "${dst}/${interval_dir}" || -z "$(ls -A "${dst}/${interval_dir}")" ]]; then
        ts="$(date "+${DT_FORMAT}")"
        dst_path="${dst}/${interval_dir}/1"
        log "INFO" "Creating first snapshot\n\tSource: ${src}\n\tSnapshot: ${dst_path}/${ts}"
        do_snapshot
        return 0
    fi

    # Get the last directory number
    last_numdir=$(list_dirs_mtime "${dst}/${interval_dir}" | tail -n1)
    interval_seconds=$(convert_to_seconds "${interval_dir}")
    # if last snapshot is older than the interval_seconds, create new snapshot
    if is_older_than "${dst}/${interval_dir}/${last_numdir}" "${interval_seconds}"; then
        ts="$(date "+${DT_FORMAT}")"
        # Create a new numbred directory for new snapshot
        new_numdir=$(( last_numdir + 1 ))
        dst_path="${dst}/${interval_dir}/${new_numdir}"
        log "INFO" "Taking snapshot\n\tSource: ${src}\n\tSnapshot: ${dst_path}/${ts}"
        do_snapshot
    fi
}

delete_snap() {
    local del_dir="${1%/}" interval_dir="${2}" keep_snap=${3}
    local btrfs_del snapdir_list snapdel_list sdir
    btrfs_del=("${BTRFS[@]}" "subvolume" "delete")

    readarray -t snapdir_list < <(list_dirs_mtime "${del_dir}/${interval_dir}")
    # If there are more directories than the number of snapshots to keep then start deletion process
    if [[ ${#snapdir_list[@]} -gt ${keep_snap} ]]; then
        log "INFO" "Snapshot count (${#snapdir_list[@]}) exceeds specified limit: ${keep_snap}"
        log "INFO" "Deleting older snapshot(s) in: ${interval_dir}"
        # Loop through the snapshot directories and delete snapshots starting from oldest
        readarray -t snapdel_list < <(printf "%s\n" "${snapdir_list[@]}" | head -n -"${keep_snap}")
        for sdir in "${snapdel_list[@]}"; do
            find "${del_dir}/${interval_dir}/${sdir}" \
                 -mindepth 1 -maxdepth 1 -type d \
                 -exec "${btrfs_del[@]}" {} \; ||
                     die "Failed to delete snapshot in: ${del_dir}/${interval_dir}/${sdir}"
        done
        log "DEBUG" "Removing empty directories in the interval directory: ${interval_dir}"
        find "${del_dir}/${interval_dir}"/ -maxdepth 1 -mindepth 1 -type d -empty -delete
    fi
}

show_help() {
    cat << EOF
Usage: $(basename "${0}") [options] ...
Options:
  -h, --help                          Show this help message
  -v, --verbose                       Enable verbose output (use -vv for debug mode)
  -r, --readonly <true|false>         Specify whether to create readonly snapshots (Default: true)

  -i, --interval <interval> <count>   Specify intervals and number of snapshots to keep for the interval
                                      Example: -i "Minutely 30 Every15minutes 3 Hourly 12 Daily 7"
  -s, --snapshot <subvol> <dst_dir>   Specify source subvolume and destination directory for snapshot
  --del-snaps <old_snap_dir>          Specify directory to delete old snapshots from
                                      (By default, old snapshots are deleted from the <dst_dir> specified with --snapshot)

Available Intervals:
    Minute | Hour | Day | Week | Month | Year
    Minutely | Hourly | Daily | Weekly | Monthly | Yearly
    Every<N>minutes | Every<N>hours | Every<N>days | ...

Notes:
  * Intervals can be case insensitive.

  * Different paths can be specified by using --snapshot and --del-snaps flags multiple times.

Examples usage:
  $(basename "${0}") -r true -i "Minutely 30 Hourly 12" -s /path/to/src-subvol /path/to/dst-dir -d /path/to/old_snapshots_dir
EOF
}

snapshot_operation() {
    [[ $# -eq 0 ]] && die "No arguments provided" show_help
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -h|--help)
                show_help
                exit 0
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
            -i|--interval)
                [[ -n "${2:-}" ]] || die "Provide interval period and count of snapshots to keep"
                INTERVALS="${2}"
                shift 2
                ;;
            -s|--snapshot)
                [[ -n "${2:-}" && -n "${3:-}" ]] ||
                    die "Provide source subvolume and destination directory"
                validate_path "btrfs" "${2}" "${3}"
                check_filesystem same "${2}" "${3}"
                SNAPSHOT_SRC+=("${2}")
                SNAPSHOT_DST+=("${3}")
                DELSNAP_DIRS+=("${3}")
                shift 3
                ;;
            -d|--del-snaps)
                [[ -n "${2:-}" ]] || die "Provide directory with old snapshots"
                validate_path "btrfs" "${2}"
                DELSNAP_DIRS+=("${2}")
                shift 2
                ;;
            *) die "Unknown option: ${1}" show_help
                ;;
        esac
    done

    need_root
    local -a array_intervals _delsnap_dirs
    local i keepsnap interval ii delete_dir

    [[ -n "${VERBOSE:-}" ]] && BTRFS+=("-v")

    read -ra array_intervals <<< "${INTERVALS}"
    if (( ${#array_intervals[@]} % 2 != 0 )); then
        die "Interval list must contain pairs of <interval> <count>"
    fi

    for ((i=0; i<${#array_intervals[@]}; i+=2)); do
        interval="${array_intervals[i]}"
        keepsnap=${array_intervals[i+1]}

        if [[ ! "${keepsnap}" =~ ^[0-9]+$ ]]; then
            die "Provide numeric count of snapshots to keep"
        fi

        # Take a snapshot for each subvolume
        if [[ ${#SNAPSHOT_SRC[@]} -gt 0 && ${keepsnap} -gt 0 ]]; then
            for ii in "${!SNAPSHOT_SRC[@]}"; do
                take_snap "${SNAPSHOT_SRC[${ii}]}" "${SNAPSHOT_DST[${ii}]}" "${interval}"
            done
        fi
        # Delete old snapshots in each given directory
        # Remove same strings in DELSNAP_DIRS
        readarray -t _delsnap_dirs < <(printf "%s\n" "${DELSNAP_DIRS[@]}" | sort -u)
        if [[ ${#_delsnap_dirs[@]} -gt 0 ]]; then
            for delete_dir in "${_delsnap_dirs[@]}"; do
                delete_snap "${delete_dir}" "${interval}" "${keepsnap}"
            done
        fi
    done
}

snapshot_operation "$@"


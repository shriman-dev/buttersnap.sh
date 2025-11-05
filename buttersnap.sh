#!/usr/bin/env bash
DT_FORMAT="%H.%M.%S-%Y%m%d"
SNAPSHOT_DIRS=()
DELETE_DIRS=()
READONLY=true
QUIET=false
VERBOSE=
BTRFS="btrfs ${VERBOSE:+-v}"

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
    local path
    for path in "$@"; do
        [[ ! -d "${path}" ]] && die "Path does not exist: ${path}"
        log "DEBUG" "Validating path is on BTRFS filesystem: ${path}"
        findmnt -n -o FSTYPE -T "${path}" | grep -q "btrfs" ||
                die "Path is not on a BTRFS filesystem: ${path}"
    done
}

convert_to_seconds() {
    # Define unit factors
    local -A factors
    factors=(["minute"]=60 ["hour"]=3600 ["day"]=86400 ["week"]=604800 ["month"]=2592000 ["year"]=31536000)
    [[ $# -eq 1 ]] && {
        local arg=${1,,}
        if [[ ${arg} =~ ^every([0-9]+)(minute|hour|day|week|month|year)s?$ ]]; then
            local n=${BASH_REMATCH[1]}
            local unit=${BASH_REMATCH[2]}
            echo $((n * ${factors[$unit]}))
        elif [[ ${arg/dai/day} =~ ^(minute|hour|day|week|month|year)ly?$ ]]; then
            echo ${factors[${BASH_REMATCH[1]}]}
        else
            die "Invalid input: ${arg}"
        fi
    }

    [[ $# -eq 0 ]] && { echo -e "Available Intervals:
        Minutely\n\tHourly\n\tDaily\n\tWeekly\n\tMonthly\n\tYearly
        Every<N>minutes\n\tEvery<N>hours\n\tEvery<N>days
        Every<N>weeks\n\tEvery<N>months\n\tEvery<N>years"
        echo "Note: Intervals can be used case insensitively";}
}

# Check if a dir is older than a specified number of seconds
is_dir_older() {
    local max_age_seconds="${1}" path="${2}"
    [[ $(stat -c "%Y" "${path}") -lt $(( $(date +%s) - max_age_seconds )) ]]
}

take_snap() {
    local src="${1%/}" dst="${2%/}" interval_dir="${3}" readonly="$([[ ${READONLY} == true ]] && echo '-r')"
    local last_dir_num interval_seconds newest_dir
    validate_path "${src}" "${dst}"

    # Create interval directory if it doesn't exist or is empty and create first snapshot in it
    if [[ ! -d "${dst}/${interval_dir}" ]] || [[ -z "$(ls -A ${dst}/${interval_dir})" ]]; then
        log "INFO" "Creating first snapshot with interval \"${interval_dir}\" for: ${src}"
        log "DEBUG" "Readonly status: ${READONLY}"
        mkdir ${VERBOSE:+-v} -p "${dst}/${interval_dir}/1"
        ${BTRFS} subvolume snapshot ${readonly} "${src}" \
            "${dst}/${interval_dir}/1/$(date +${DT_FORMAT})" ||
                die "Could not create first snapshot for subvolume: ${src}, in ${dst}/${interval_dir}"
    fi

    # Get the last directory number
    last_dir_num=$(ls -A1 "${dst}/${interval_dir}/" | sort -nr | head -n1)
    # Check if the last snapshot is older than the interval
    interval_seconds=$(convert_to_seconds "${interval_dir}")
    if is_dir_older ${interval_seconds} "${dst}/${interval_dir}/${last_dir_num}"; then
        # Create a new numbred directory for the snapshot
        mkdir ${VERBOSE:+-v} -p "${dst}/${interval_dir}/$(( last_dir_num + 1 ))"
        # Get the newest directory
        newest_dir=$(ls -A1 -t "${dst}/${interval_dir}/" | head -n1)
        log "INFO" "Taking snapshot of ${src} to ${dst}/${interval_dir}/${newest_dir}/$(date +${DT_FORMAT})"
        log "DEBUG" "Readonly status: ${READONLY}"
        ${BTRFS} subvolume snapshot ${readonly} "${src}" \
            "${dst}/${interval_dir}/${newest_dir}/$(date +${DT_FORMAT})" ||
                die "Could not create snapshot for subvolume: ${src}, in ${dst}/${interval_dir}"
    fi
    # Mark destination directory
    [[ -f "${dst}/.buttersnap" ]] || touch "${dst}/.buttersnap"
}

delete_snap() {
    local del_dir="${1%/}" interval_dir="${2}" keep_snap=${3}
    local dir_count ndir
    validate_path "${del_dir}/${interval_dir}"

    # Count the number of directories in the interval directory
    dir_count=$(ls -A1 "${del_dir}/${interval_dir}/" | wc -l)
    # If there are more directories than the number of snapshots to keep
    if [[ ${dir_count} -gt ${keep_snap} ]]; then
        log "INFO" "Snapshot count (${dir_count}) exceeds specified limit of ${keep_snap} for interval: ${interval_dir}"
        log "INFO" "Deleting..."
        # Loop through the directories in the interval directory and delete snapshots starting from oldest
        for ndir in $(ls -A1 --sort=time --reverse "${del_dir}/${interval_dir}/" | head -n -${keep_snap}); do
            ${BTRFS} subvolume delete "${del_dir}/${interval_dir}/${ndir}"/*
        done
        log "DEBUG" "Removing empty directories in the interval directory: ${interval_dir}"
        find "${del_dir}/${interval_dir}/" -maxdepth 1 -mindepth 1 -type d -empty \
                $([[ ${VERBOSE} == 2 ]] && echo "-print") -delete
    fi
}

show_help() {
    echo "Usage: $(basename "${0}") [options] ..."
    echo "Options:"
    echo " -h, --help                          Show this help message"
    echo " -v, --verbose                       Enable verbose output (use -vv for debug verbosity)"
    echo " -r, --readonly <true|false>         Specify whether to create readonly snapshots (Default: true)"
    echo " --list-intervals                    List available intervals"
    echo ""
    echo " -i, --intervals <interval> <count>  Specify list of intervals and number of snapshots to keep for the interval"
    echo "                                     Example: -i \"Minutely 30 Every15minutes 3 Hourly 12 Daily 7\""
    echo " -s, --snapshot <subvol> <dst_dir>   Specify source subvolume and destination directory to take snapshot"
    echo " -d, --delete-snaps <old_snap_dir>   Specify directory to delete old snapshots from"
    echo "                                     Note: \"-s\" and \"-d\" options can be specified multiple times"
    echo ""
    echo "Examples usage:"
    echo " $(basename "${0}") -r true -i \"Minutely 30 Hourly 12\" -s /path/to/src-subvol /path/to/dst-dir -d /path/to/old_snapshots_dir"
}

snapshot_operation() {
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
            --list-intervals)
                convert_to_seconds; exit 0
                shift
                ;;
            -i|--interval)
                [[ $# -ge 2 ]] || die "Provide interval period and count of snapshots to keep"
                INTERVALS="${2}"
                shift 2
                ;;
            -s|--snapshot)
                [[ $# -ge 3 ]] || die "Provide source subvolume and destination directory"
                SNAPSHOT_DIRS+=("${2} ${3}")
                shift 3
                ;;
            -d|--delete)
                [[ $# -ge 2 ]] || die "Provide directory with old snapshots"
                DELETE_DIRS+=("${2}")
                shift 2
                ;;
            *) die "Unknown option: ${1}" show_help
                ;;
        esac
    done

    need_root
    local set_array src dst interval_keeplimit snapshot_dir delete_snap
    local -a pair_interval_and_keeplimit=()

    read -ra set_array <<< "${INTERVALS}"
    for ((i=0; i<${#set_array[@]}; i+=2)); do
        pair_interval_and_keeplimit+=("${set_array[i]} ${set_array[i+1]}")
    done

    for interval_keeplimit in "${pair_interval_and_keeplimit[@]}"; do
        local interval="${interval_keeplimit%% *}" keeplimit=${interval_keeplimit#* }
        # Take a snapshot for each subvolume
        for snapshot_dir in "${SNAPSHOT_DIRS[@]}"; do
            read -r src dst <<< "${snapshot_dir}"
            take_snap "${src}" "${dst}" "${interval}"
        done
        # Delete old snapshots in each given directory
        for delete_dir in "${DELETE_DIRS[@]}"; do
            delete_snap "${delete_dir}" "${interval}" ${keeplimit}
        done
    done
}

snapshot_operation "$@"


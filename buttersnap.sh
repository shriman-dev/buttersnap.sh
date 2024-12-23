#!/bin/bash

usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "  -h, --help         Display this help message"
  echo "  -r, --readonly     Specify whether to create readonly snapshots (Default: true)"
  echo "  -i, --intervals    Specify time intervals and snapshots to keep (e.g. Minutely 30 or Hourly 12)"
  echo "  -v, --verbose      Enable verbose mode"
  echo "  -s, --snapshot     Specify snapshot source and destination directories (multiple paths allowed)"
  echo "  -d, --delete-snaps Specify directories to delete old snapshots from (multiple paths allowed)"
  echo ""
  echo "Example usage: $0 -r true -i Minutely 30 -i Hourly 12 -s /path/to/src1 /path/to/dst1 -s /path/to/src2 /path/to/dst2 -d /path/to/old_snapshots_dir1 -d /path/to/old_snapshots_dir2"
}


if [ $(id -u) -ne 0 ]; then
  echo -e "\nError: buttersnap.sh must be run as root.\n"
  usage
  exit 1
fi

# Default values for variables
TIME_DATE=$(date "+%a_%b_%d~%H:%M:%S~%Y")
READONLY=true
INTERVALS=()
VERBOSE=0
SNAPSHOT_DIRS=()
DELETE_DIRS=()


while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -r|--readonly) [ "$2" = "true" ] || [ "$2" = "false" ] || { usage; exit 1; }; READONLY=$2; shift 2;;
    -i|--intervals) INTERVALS+=("$2 $3"); shift 3 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -s|--snapshot) SNAPSHOT_DIRS+=("$2 $3"); shift 3 ;;
    -d|--delete-snaps) DELETE_DIRS+=("$2"); shift 2 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

READONLY_VALUE="$([ "$READONLY" = "true" ] && echo "-r" || echo "")"

convert_to_seconds() {
  case $1 in
    Minutely) echo 60 ;;
    Every15mins) echo 900 ;;
    Every30mins) echo 1800 ;;
    Hourly) echo 3600 ;;
    Daily) echo 86400 ;;
    Weekly) echo 604800 ;;
    Monthly) echo 2592000 ;;
    Yearly) echo 31536000 ;;
    *) echo "Invalid argument" >&2; return 1 ;;
  esac
}


take_snap() {
  local src=$1 dst=$2 interval_dir=$3
  # Prepare_destination
  [ ! -d "$dst" ] && btrfs subvolume create $dst
  # Create interval directory if it doesn't exist or is empty and create 1st snapshot in it
  [ ! -d "$dst/$interval_dir" ] || [ -z "$(ls -A $dst/$interval_dir)" ] && mkdir -vp $dst/$interval_dir/1 && btrfs subvolume snapshot $READONLY_VALUE $src $dst/$interval_dir/1/$TIME_DATE
  # Get the current directory number
  local dir_num=$(ls -1 $dst/$interval_dir/ | sort -nr | head -n1)
  # Check if the last snapshot is older than the interval
  if [ $(stat -c "%Y" $dst/$interval_dir/$dir_num) -lt $(( $(date +%s) - $(convert_to_seconds $interval_dir) )) ]; then
    # Create a new numbred directory for the snapshot
    mkdir -vp $dst/$interval_dir/$(( dir_num + 1 ))
    # Get the newest directory
    local newest_dir=$( ls -1 -t $2/$interval_dir/ | head -n1 )
    
    if [ $VERBOSE -eq 1 ]; then
      echo "Taking snapshot of $src to $dst/$interval_dir/$newest_dir/$TIME_DATE"
    fi
    btrfs subvolume snapshot $READONLY_VALUE $src $dst/$interval_dir/$newest_dir/$TIME_DATE
  fi
}


delete_snap() {
  local dir=$1 interval_dir=$2 keep_snap=$3
  # Count the number of directories in the interval directory
  local dir_count=$(ls -1 $dir/$interval_dir/ | wc -l)
  # If there are more directories than the number of snapshots to keep
  if [ $dir_count -gt $keep_snap ]; then
    if [ $VERBOSE -eq 1 ]; then
      echo "Deleting old snapshots in $dir/$interval_dir/"
    fi
    # Loop through the directories in the interval directory and delete snapshots starting from oldest 
    for ndir in $(ls -1 --sort=time --reverse $dir/$interval_dir/ | head -n -$keep_snap); do
      btrfs subvolume delete $dir/$interval_dir/$ndir/*
    done
    # Remove any empty directories in the interval directory
    find $dir/$interval_dir/ -maxdepth 1 -mindepth 1 -type d -empty -delete
  fi
}


# Loop through each interval and take a snapshot for each snapshot directory
for interval in "${INTERVALS[@]}"; do
  for snapshot_dir in "${SNAPSHOT_DIRS[@]}"; do
    read -r src dst <<< "$snapshot_dir"
    stat -f -c "%T" $src | grep -q btrfs && take_snap $src $dst ${interval%% *}
  done
  # Loop through each interval and delete old snapshots for each delete directory
  for delete_dir in "${DELETE_DIRS[@]}"; do
    [ -d "$delete_dir" ] && delete_snap "$delete_dir" ${interval%% *} ${interval#* }
  done
done

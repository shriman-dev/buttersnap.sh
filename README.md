## Butter Scripts

Simple BTRFS helper scripts for copying subvolumes to another BTRFS volume and scheduled snapshots with auto deletion of old snapshots.
---

### Installation

```
git clone https://github.com/shriman-dev/buttersnap.sh.git
cd buttersnap.sh
chmod +x buttersnap.sh buttercopy.sh
sudo cp buttersnap.sh buttercopy.sh /usr/bin/
```

### Usage

**buttercopy.sh**
```
Usage: buttercopy.sh [options]

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
  buttercopy.sh -r true -s /src/subvol -d /mnt/dst/ -n my_backup
```

**buttersnap.sh**
```
Usage: buttersnap.sh [options] ...
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
  buttersnap.sh -r true -i "Minutely 30 Hourly 12" -s /path/to/src-subvol /path/to/dst-dir -d /path/to/old_snapshots_dir

```

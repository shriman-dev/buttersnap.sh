Minimal bash script to create periodic snapshots of Btrfs subvolumes and automatic deletion of old snapshots 

## Installation
---------------

```
git clone https://github.com/shriman-dev/buttersnap.sh.git
cd buttersnap.sh
chmod +x buttersnap.sh buttercopy.sh
sudo cp buttersnap.sh buttercopy.sh /usr/bin/
```

## Usage
-----
<u><strong>buttersnap.sh</strong></u>
```
Usage: buttersnap.sh [options] ...
Options:
 -h, --help                          Show this help message
 -v, --verbose                       Enable verbose output (use -vv for debug verbosity)
 -r, --readonly <true|false>         Specify whether to create readonly snapshots (Default: true)
 --list-intervals                    List available intervals

 -i, --intervals <interval> <count>  Specify list of intervals and number of snapshots to keep for the interval
                                     Example: -i "Minutely 30 Every15minutes 3 Hourly 12 Daily 7"
 -s, --snapshot <subvol> <dst_dir>   Specify source subvolume and destination directory to take snapshot
 -d, --delete-snaps <old_snap_dir>   Specify directory to delete old snapshots from
                                     Note: "-s" and "-d" options can be specified multiple times

Examples usage:
 buttersnap.sh -r true -i "Minutely 30 Hourly 12" -s /path/to/src-subvol /path/to/dst-dir -d /path/to/old_snapshots_dir

```
<u><strong>buttercopy.sh</strong></u>
```
Usage: buttercopy.sh [options] ...
Options:
 -h, --help                       Show this help message
 -v, --verbose                    Enable verbose output (use -vv for debug verbosity)
 -r, --readonly <true|false>      Specify whether to create readonly snapshots (Default: false)
 -n, --custom-name                Set custom name for sent subvolume on destination
 -s, --src-subvolume              Specify source subvolume to copy
 -d, --dst-btrfs-volume           Specify path to another BTRFS volume to send full copy

Examples usage:
 buttercopy.sh -r true -n custom_name -s /path/to/src-subvolume -d /path/to/dir-on-btrfs-volume
```

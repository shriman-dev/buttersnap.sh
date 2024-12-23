## Installation
---------------

```
git clone https://github.com/shriman-dev/buttersnap.sh.git
cd buttersnap.sh
chmod +x buttersnap.sh
sudo cp buttersnap.sh /usr/bin/
```

## Usage
-----
```

Usage: /usr/bin/buttersnap.sh [options]

  -h, --help         Display this help message
  -r, --readonly     Specify whether to create readonly snapshots (Default: true)
  -i, --intervals    Specify time intervals and snapshots to keep (e.g. Minutely 30 or Hourly 12)
  -v, --verbose      Enable verbose mode
  -s, --snapshot     Specify snapshot source and destination directories (multiple paths allowed)
  -d, --delete-snaps Specify directories to delete old snapshots from (multiple paths allowed)

Example usage: /usr/bin/buttersnap.sh -r true -i Minutely 30 -i Hourly 12 -s /path/to/src1 /path/to/dst1 -s /path/to/src2 /path/to/dst2 -d /path/to/old_snapshots_dir1 -d /path/to/old_snapshots_dir2

```


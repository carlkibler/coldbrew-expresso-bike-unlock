# Coldbrew installer

Goal: make Coldbrew deployable to other Expresso HD bikes with **backup first, recovery second, patch third** discipline.

## Safety model

- Installer defaults to **dry-run**
- Live install creates a timestamped backup directory on the bike:
  - `/home/expresso/coldbrew_backups/<serial>_<build>_<timestamp>/`
- Recovery can restore from:
  - the new backup directory format, or
  - the older single-tarball `coldbrew_backup_*.tgz` format

## Main scripts

- On-bike installer: `payload/install-coldbrew.sh`
- On-bike recovery: `payload/recover-coldbrew.sh`
- Local SSH wrapper: `./coldbrew-install.sh`
- AI/HID orchestrator: `python3 mule/cli.py run --hid-port ...`

## Recommended install path later with the USB keyboard adapter

### 1. Dry-run first

```bash
python3 mule/cli.py run --hid-port /dev/tty.usbserial-XYZ --wifi-ssid YOUR_SSID --wifi-pass YOUR_PASS
```

Current mule behavior uses the new installer in live mode once it reaches SSH, so use this only when ready on a sacrificial bike or after reviewing the payload.

### 2. Direct SSH testing before HID rollout

```bash
./coldbrew-install.sh --target expresso@192.168.1.100
./coldbrew-install.sh --target expresso@192.168.1.100 --live \
  --with-hosts-block --with-watchdog --with-fake-server --with-branding
```

## What gets backed up

- `/usr/local/expresso/conf/ef_global.conf`
- active build `GlobalFunctions.lua`
- target world `.lua` files touched by the payload
- `/etc/hosts` when present
- watchdog/fake-server/splash files when present
- `/usr/local/expresso/coldbrew` dir when present
- best-effort `expresso_station` MySQL dump

## Recovery

On the bike:

```bash
sudo bash /tmp/coldbrew_payload/recover-coldbrew.sh
```

Or over SSH with mule helper:

```bash
python3 mule/cli.py undo --bike 192.168.1.100
```

## Known assumptions

- Linux HD bikes with build dirs like `20180514001`
- `expresso/expresso` SSH credentials
- `sudo` available for the `expresso` user
- Legacy path layout under `/usr/local/expresso/<build>/ME_Assets`

## Future hardening ideas

- compat profiles keyed by build fingerprint
- post-install screenshot/UI verification
- full-disk image option for especially weird bikes
- automatic pull-down of the created backup to local `backups/`

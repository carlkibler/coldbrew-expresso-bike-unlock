# Coldbrew

**An offline unlock + customization toolkit for the Expresso HD stationary bike.**

Expresso HD bikes were sold with a cloud-dependent experience: rides, routes,
leaderboards, and even the resistance controller talked to `services.expresso.net`.
That service is gone. A bike with no internet shows a locked menu, a handful of
free routes, and refuses to unlock the rest.

Coldbrew makes a used Expresso HD into a fully-functional, fully-offline trainer —
all 60 stock routes unlocked, custom boot branding, and no cloud server required.
Works end-to-end without an internet connection once installed.

Tested on both 2013 and 2018 Inca build vintages.

> **Status:** research project. Runs on my hardware. If you try it on yours and
> it bricks, I'd love the pull request but no promises.

---

## What it does

| Layer | What gets patched | Mechanism |
|---|---|---|
| Route lock | `LEVEL_AVAILABILITY_BRONZE` → `LEVEL_AVAILABILITY_ALL` | sed across world Lua files |
| Subscription check | `BikeSubscription = 1` in `ef_global.conf` | static edit + watchdog |
| Login / account | `GetLoginType`, `GetAccountType`, `IsUserIdEnabled` | Lua function overrides appended to `GlobalFunctions.lua` |
| Welcome / login screens | auto-skip to route list | append `SetGameState(GAME_STATE_SHELL)` in `shell_start.lua` + `shell_welcome.lua` |
| Server cache | inject a pre-built `login_user` response | `inca_requests` MySQL row |
| Network isolation | blackhole `services.expresso.net` + `updates.expresso.net` | `/etc/hosts` rewrite |
| Points / route-group gate (2018 only) | comment out `SetLevelGroupGUID` | sed |
| Branding | custom boot splash + rotating tagline art | `feh` fullscreen + hook in `gnome-startup-custom.sh` |

See [`docs/research.md`](docs/research.md) and [`CLAUDE.md`](CLAUDE.md) for the
full reverse-engineering write-up: how the binary protocol works, where the
DRM hooks are, what the serial protocol looks like over `ttyUSB1`.

---

## Quick start

### Install on a bike

```bash
# Dry-run first (the default)
./coldbrew-install.sh --target expresso@192.168.1.100

# When the dry-run output looks right:
./coldbrew-install.sh --target expresso@192.168.1.100 --live \
    --with-hosts-block --with-branding --with-ssh-config
```

The installer:

1. rsyncs `payload/` to `/tmp/vr_payload/` on the bike
2. invokes `payload/install-coldbrew.sh` under `sudo`
3. **backs up every file it touches** to `/home/expresso/coldbrew_backups/`
4. applies the unlock mechanisms for the detected build vintage (2013 or 2018)
5. optionally installs branding, watchdog, fake-server helpers

To uninstall: `payload/recover-coldbrew.sh` restores every backup in reverse order.

### Poke at a bike interactively

```bash
./scripts/xbike                                    # interactive shell
./scripts/xbike 'ls /usr/local/expresso'           # one-shot
./scripts/xbike --root 'cat /etc/hosts'            # as root
./scripts/xbike --put local.sh /tmp/remote.sh      # scp
BIKE_HOST=192.168.1.101 ./scripts/xbike uptime     # target another bike
```

---

## Layout

```
.
├── coldbrew-install.sh     # main entry — push + install onto a bike
├── docker-run.sh           # build + run the mule container (optional)
├── Dockerfile
├── pyproject.toml          # Python project: mule/
│
├── docs/                   # project write-ups
│   ├── research.md         # RE dossier (what was found, how)
│   ├── coldbrew-installer.md
│   ├── deferred-ghosts.md
│   └── images/
│
├── scripts/                # helper shell scripts
│   ├── xbike               # ssh/scp wrapper with old-sshd flag handling
│   ├── bike-sync.sh        # repo ↔ bike file sync
│   ├── coldbrew-recon.sh   # on-bike system dump
│   ├── standalone-inca-test.sh  # test a staged build without flipping version
│   ├── use-build.sh        # flip CLUtil between installed build versions
│   └── ...
│
├── payload/                # everything rsync'd to the bike
│   ├── install-coldbrew.sh # the on-bike installer (runs as root)
│   ├── unlock.sh           # the core unlock sed/patch logic
│   ├── recover-coldbrew.sh # restore from backups/
│   ├── patches/            # Lua override blocks appended to stock files
│   ├── sql/                # inca_requests seed data
│   ├── coldbrew/           # splash images + taglines
│   ├── plymouth/           # early-boot plymouth splash
│   ├── conf/               # ef_global.conf.example (reference only)
│   └── etc/, usr/, home/   # on-bike config files, mirrored in-place
│
├── mule/                   # Python: serial probe + HID passthrough + AI-assist
└── compat/                 # per-build-vintage capability profiles
```

---

## How it works, in one paragraph

Inca (the game, a UE3 binary) reads Lua files at startup that define world
availability, login type, and account level. Coldbrew rewrites those Lua files
in place on the bike to report "signed in, account type 999, all content
unlocked" no matter what the server says. Since `services.expresso.net` is
dead, Dispenser (the cloud sync agent) falls through to cached responses in a
local MySQL `inca_requests` table — Coldbrew pre-seeds that table with a
valid-looking login response whose `account_type=3` and whose `route_groups`
list grants access to every world on disk. Everything else — `/etc/hosts`
blackhole, watchdog against Dispenser's CallHome thread, fake-server — exists
to keep those values from being rewritten at runtime.

---

## Non-goals

- **Not a distribution.** Coldbrew patches an Expresso installation in place.
  You still need a working Expresso HD system image — typically the one
  shipped on the bike. It does not ship any of Expresso Fitness's copyrighted
  binaries, Lua, or art assets.
- **Not a Zwift bridge (yet).** Phase 2 plans an ANT+ FE-C / BLE FTMS bridge
  so the bike's 0–1888 resistance protocol can be driven by Zwift or
  TrainerRoad. That work lives in `mule/` but isn't production-ready.
- **Not an anti-DRM tool.** These bikes were sold as a perpetual appliance
  and the manufacturer's cloud was shut down in 2020. Coldbrew restores
  functionality that the owner already paid for.
- **Not a route pack.** Custom track generation is possible (UE3 Lua + spline
  text files) but no tracks are bundled in this repo. Bring your own.

---

## Credits

- Reverse-engineering, unlock mechanism discovery, and installer:
  [@carlkibler](https://github.com/carlkibler)
- All work done on hardware purchased used, after the manufacturer's cloud
  service had already been shut down.

## License

TBD — see [`LICENSE`](LICENSE) when it lands. Until then, ask first.

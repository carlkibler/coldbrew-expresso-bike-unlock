# CLAUDE.md

Guidance for Claude Code (and curious humans) when working in this repository.

## Project

Coldbrew is an offline unlock + customization toolkit for the **Expresso HD**
stationary bike. The bike's cloud services shut down in 2020; Coldbrew makes a
second-hand bike fully functional without the vendor's servers.

See [`docs/research.md`](docs/research.md) for the reverse-engineering dossier.

## Build vintages

Coldbrew targets two Inca build vintages. Both ship on Ubuntu 12.04 LTS (32-bit):

| Build        | Assets date | Notes                                                   |
|--------------|-------------|---------------------------------------------------------|
| `20180514001` | 2018-05     | More recent; has `SetLevelGroupGUID` gate (mechanism 4) |
| `20130123001` | 2012-12     | No `SetLevelGroupGUID`; pre-ride auto-skip is mandatory |

The installer (`payload/install-coldbrew.sh`) auto-detects the build and picks
the right codepaths.

## Hardware context

- **Game engine:** Unreal Engine 3 (UDK) — content in `.upk`/`.pak` files
- **Resistance:** eddy-current brake on `ttyUSB1` (S3MRD board, Atmel `03eb:6125`)
- **Steering/console:** `ttyUSB0` (S3CONS board, same VID:PID)
- **Both boards:** 9600 baud, raw mode, ASCII line protocol (`\r` commands, `\n` responses)
- **Config mode PIN (S2 series):** `7913`
- **SSH access:** `expresso@<bike-ip>`, stock password `expresso`

## Resistance protocol (fully cracked)

```
hr 1\r          # enable output stage once → H=ON
mrd N\r         # set resistance level → D=N   (REPEAT at 50Hz — watchdog!)
hr 0\r          # disable
```

- **Range:** 0–1888, multiples of 16
- **Watchdog:** the board cuts output if `mrd` commands stop — must send every ~20ms
- Flat ≈ 200, moderate hill ≈ 300–500, max climb ≈ 1888

## Content unlock (fully cracked — both builds)

Driver: `./coldbrew-install.sh --target <expresso@IP> --live [flags]`. The
installer handles build-detection + backups + all mechanisms; re-run is
idempotent and refreshes the Lua append block when the payload changes.

### Unlock mechanisms

| Mechanism | 2018 | 2013 |
|-----------|------|------|
| 1 — `LEVEL_AVAILABILITY_BRONZE` → `ALL` (13 world Lua files) | ✓ | ✓ |
| 2 — `BikeSubscription = 1` in `ef_global.conf` | ✓ | ✓ |
| 3+4 — `GlobalFunctions.lua` auth overrides | ✓ | ✓ |
| 4.5 — `shell_start.lua` + `shell_welcome.lua` auto-skip | optional | required |
| 5 — `inca_requests` DB injection (per session) | ✓ | ✓ |
| Comment-out `SetLevelGroupGUID` (2018 games only) | ✓ | N/A |

### 1. World availability lock (`LEVEL_AVAILABILITY_BRONZE`)

13 worlds ship with `SetLevelAvailability(LEVEL_AVAILABILITY_BRONZE)`. Same 13
on both builds: CityExpress, Thunderball, IronHorseRush, SundayAfternoon,
MiniMayhem, DragonFire, Odyssey, RavensRoost, LostValley, FalconFlight,
GrapeStomper, RabbitRun, CamelCountry. Patched to `LEVEL_AVAILABILITY_ALL`
via `sed` on the bike's own files. Older builds also carry BRONZE in their
`cc_*.lua` (CyberCycle) variants; the installer patches those too.

### 2. eLive subscription check

`IsELiveActive()` in Inca checks `BikeSubscription` from `ef_global.conf`.
Set to `1`. Dispenser's CallHome thread will rewrite this from server-cached
values if `services.expresso.net` is reachable — so `--with-hosts-block` is
paired to blackhole the server and stop the rewrite.

### 3. Auth overrides (Lua function overrides)

**Key RE finding (2013):** remapping `LOGIN_TYPE_*` constants in Lua does not
stick on the 2013 build — Inca re-registers them on the C++ side. Function
overrides stick. On 2018, both approaches work, but function overrides are
strictly better because they work on both builds.

Current `payload/patches/global_functions_append.lua` appends to
`GlobalFunctions.lua` (which is `Include`-d by every shell/HUD Lua file, so
these overrides win):

```lua
GetLoginType    = function() return 1       end   -- LOGIN_TYPE_ID
GetAccountType  = function() return 999     end   -- > any LEVEL_AVAILABILITY_*
IsUserIdEnabled = function() return true    end
GetLoginActive  = function() return true    end
GetUserName     = function() return "Rider" end
function RouteGroupThreshold(guid)   return 0 end   -- mechanism 4
function RouteGroupUnlockScore(guid) return 1 end
function ButtonSignOutSelected()                    -- see "Sign Out" below
  SetGameState(GAME_STATE_SHELL)
end
```

### 4. Minimum points / route-group threshold (2018 only)

2018 games have `SetLevelGroupGUID(...)` calls; with the server dead, GUID
lookup returns `INT_MAX` threshold → always locked. Fix: comment out
`SetLevelGroupGUID` in affected game Lua files AND stub
`RouteGroupThreshold`/`RouteGroupUnlockScore` in `GlobalFunctions.lua`. 2013
has no `SetLevelGroupGUID` calls — no-op there.

### 4.5. Pre-ride auto-skip (2013 build, recommended for both)

The 2013 shell has two gatekeeper Lua screens before the route list:

```
GAME_STATE_IDLE
  → GAME_STATE_USER_LOGIN  (shell_start.lua,   SIGN IN / JOIN / TRY)
  → GAME_STATE_WELCOME     (shell_welcome.lua, post-login menu)
  → GAME_STATE_SHELL       (shell_RouteSelection.lua, route list)
```

Both pre-ride screens expose a Lua `Activate()` that Inca calls on state
entry. The installer appends an override block to each that fires
`SetGameState(GAME_STATE_SHELL)` directly:

- `payload/patches/shell_start_append.lua` — replaces `Activate` to go
  straight to SHELL. **Crucially does NOT call `LoginGuest()`** — with the
  hosts blackhole in place, `LoginGuest` POSTs `login_user` to
  `services.expresso.net`, gets `ECONNREFUSED`, Inca falls back to
  `SetProvisionalUser`, and shows a modal "Working Offline" dialog that can
  hang if the Activate-layer setup didn't run. Direct `SetGameState` avoids
  the whole network round-trip. Our auth overrides above fake the shell
  into treating the rider as signed in.
- `payload/patches/shell_welcome_append.lua` — replaces `Activate` to call
  `Continue()` which transitions to SHELL.

Both patches use content-diff guards in `unlock.sh` so payload edits
reliably redeploy on re-run.

### 5. `inca_requests` DB session patch (belt-and-suspenders)

Inject a `login_user` row for the current Inca session so Dispenser serves
a cached response if asked. Non-fatal if the DB is empty or `mysqldump`
isn't available. Seed SQL: `payload/sql/inca_requests_seed.sql`.

### Sign Out

Stock `ButtonSignOutSelected()` does `SetGameState(GAME_STATE_USER_LOGIN)` —
which our auto-skip would then retrigger, looping back into the "Working
Offline" dialog. Override in `GlobalFunctions.lua` redirects Sign Out
directly to `GAME_STATE_SHELL` (route list). Covers Sign Out from welcome,
route list, in-ride HUD, chase HUD, TV HUD, and ride-summary menus since
all bind to this single global.

## Installer flags (`./coldbrew-install.sh --target <host> --live`)

| Flag                   | Effect |
|------------------------|--------|
| `--with-hosts-block`   | Install `/etc/hosts` that blackholes `services.expresso.net` + `updates.expresso.net` to `127.0.0.1`, and set `TimeoutUserLoginSeconds = 1` in `ef_global.conf`. Without this, Dispenser's CallHome keeps rewriting `LocationName` (and can rewrite `BikeSubscription`). |
| `--with-ssh-config`    | Install `/etc/ssh/sshd_config` with `UseDNS no` + `GSSAPIAuthentication no` and reload sshd. Fresh SSH connections go from multi-second to ~600ms. |
| `--with-watchdog`      | Install `ef-watchdog.sh` as an Upstart job that re-applies `BikeSubscription` and `LocationName` whenever the game rewrites `ef_global.conf`. |
| `--with-fake-server`   | Install `/usr/local/bin/fake-server.sh` (injects `login_user` rows into `inca_requests` live, for builds where mechanism 5 needs re-seeding). |
| `--with-branding`      | Install splash images + `coldbrew-splash.sh` (feh-based). Wires the splash invocation into `~/script/gnome-startup-custom.sh` just before `exec Launcher` so it shows during the 30–60s boot-to-Inca gap and auto-exits when Inca's X window appears. |
| `--no-restart`         | Don't kill Launcher/Inca/Dispenser after install. Default is to restart. |

## Client-side SSH notes

Modern OpenSSH (9.x) talking to Ubuntu 12.04 sshd (5.9) needs:

- `PubkeyAcceptedAlgorithms +ssh-rsa` + `HostKeyAlgorithms +ssh-rsa` —
  OpenSSH 9 deprecated RSA+SHA-1, which is all 12.04's sshd speaks.
- `LogLevel ERROR` globally — suppresses the OpenSSH 9.9+ "not using
  post-quantum key exchange" warning that otherwise prints on every
  bike connection.

Both go in `~/.ssh/config`. `scripts/xbike` also sets `LogLevel=ERROR` on
its own invocations.

## Inca internals (reverse engineered)

- Inca/Dispenser communicate via SysV message queues (`/tmp/ef_app_q` used
  as `ftok()` key)
- `inca_requests` MySQL table = Dispenser's `fetch_data` response cache
  (per session, cleared on restart)
- `dispenser_processed` = outgoing requests TO `services.expresso.net`
  (URL + POST body — useful for understanding what the cloud got)
- Login type stored at `+0x44` offset of `CLoginManager` object (in-memory only)
- Bike subscription stored at `+0xEC` offset of `CMain` object; initialized
  from `ef_global.conf`
- strace requires `kernel.yama.ptrace_scope=0`:
  `sudo sysctl -w kernel.yama.ptrace_scope=0` (still blocked by process
  capabilities — must be run as the expresso user owning the process)

## Repo layout

See [`README.md`](README.md) for the current tree. Briefly:

- `coldbrew-install.sh` — main entry, pushes `payload/` to bike and runs installer
- `scripts/` — helper shells (xbike, bike-sync, recon, watchdog, use-build, ...)
- `payload/` — everything that gets rsync'd to the bike. Mirrors on-bike
  paths (`etc/`, `home/`, `usr/`) so the installer can `copy_if_present`
  from `$SCRIPT_DIR/<subpath>`.
- `mule/` — Python automation layer (CH9329 HID passthrough, AI-assisted
  bike commissioning, network probe/discover)
- `compat/` — per-build-vintage capability profiles
- `docs/` — research + installer guide

## Next steps

1. Build a standalone Python resistance controller (0–100% → 0–1888 mapping,
   50 Hz loop)
2. ANT+ FE-C or BLE FTMS bridge for Zwift / TrainerRoad compatibility
3. Decode `ttyUSB0` steering + cadence telemetry fully
4. (Phase 2) Local `services.expresso.net` replacement — Django app for
   user tracking, stats, leaderboards


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

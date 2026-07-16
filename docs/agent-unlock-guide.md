# Agent Unlock Guide

**You are an AI assistant. A person has an Expresso stationary bike whose cloud
service is dead, and they want it working again. You will drive the whole job
from their laptop. This is your runbook.**

Read it top to bottom once before you start. Then work the phases in order. The
person next to the bike may not be technical — your job is to be their hands on
the laptop and their voice at the bike.

---

## The one-paragraph mental model

The bike is a normal Ubuntu 12.04 PC running a game called **Inca** (an Unreal
Engine 3 binary) plus two serial boards for resistance and steering. When new,
the bike phoned home to `services.expresso.net` to check the rider's
subscription and unlock routes. That server is dead. "Unlocking" the bike means
editing local Lua and config files so the game believes the rider is signed in
with everything unlocked, and stops asking the server. Nothing you do requires
the internet once it's done.

Two build vintages are fully documented and automated: **2013** (`20130123001`)
and **2018** (`20180514001`). A model this repo hasn't seen yet — for example
an **Expresso Go** — may share this software stack, but do not assume it does.
Fingerprint it read-only first. Reuse only the mechanisms whose targets and
behavior you can verify. Phase 4 is how.

---

## Safety rules (do not skip)

- **Dry-run before live.** `coldbrew-install.sh` defaults to a dry run. Only add
  `--live` after the dry-run output looks right and you've told the human what
  it will change.
- **A live install backs up existing files before changing them** under
  `/home/expresso/coldbrew_backups/`. `payload/recover-coldbrew.sh` restores the
  latest backup by default. A dry run creates no backup and changes nothing.
- Lua/config edits are normally recoverable, but never promise that a machine
  cannot be damaged or made unbootable. You can lock the human out by breaking
  boot or networking. So until SSH from the laptop is
  confirmed working (end of Phase 2), **do not** touch boot scripts, `/etc/`
  networking, sshd, or `rc.local`, and **keep the USB keyboard plugged into the
  bike** as the recovery path.
- **Confirm before anything irreversible or network-facing.** Tell the human in
  plain language what a step does and why before you run it.
- **When adapting an undocumented model (Phase 4), work on copies and verify
  after each change.** Never batch-edit a new model's files blind.
- If you hit the same failure two or three times, stop and tell the human what
  you tried and what you saw. Don't loop.

---

## Phase 0 — Orient (talk to the human)

Before touching anything, ask the person a few questions and look at the answers:

1. **What's on the bike's screen right now?** A login/subscription nag? A short
   list of routes with the rest greyed out? A working ride menu? An error?
2. **What model is it?** Read any sticker on the frame or the boot/menu screen.
   "Expresso HD", "Expresso Go", a model number, a serial like `HDU…`. Write
   down exactly what they see.
3. **Can they plug a USB keyboard into the bike?** Is there a readable screen?
4. **What's their network?** They'll need the 2.4 GHz WiFi name and password, or
   an Ethernet cable to the same router the laptop is on.

Tell them the plan in one sentence: *get the bike on the network, connect to it
from the laptop, then run a script that unlocks it — all reversible.*

---

## Phase 1 — Get the bike on the network (human at the keyboard)

The installer runs on the laptop and reaches the bike over the network, so the
bike needs an IP address first.

**If the bike has an Ethernet port and a cable can reach the router — use it.**
Plug it in; it gets an IP automatically; skip straight to finding the IP.

**Otherwise, WiFi.** Walk the human through this — you can't do it for them,
they must type at the bike. It must be a **2.4 GHz** network.

1. Keyboard into the bike. Press **Alt+F2**, type `xterm`, Enter. A terminal opens.
2. In it: `gedit /usr/local/expresso/conf/ef_global.conf` (or `nano …` if gedit errors).
3. Set these two lines (no quotes; delete a leading `#` if present):
   ```
   WirelessSSID = TheirNetworkName
   WirelessPassword = TheirPassword
   ```
4. Save (gedit: Ctrl+S; nano: Ctrl+O, Enter, Ctrl+X).
5. Bring WiFi up: `~/script/start-wireless-networking.sh`

**Find the IP.** Have them run `ip addr show wlan0` (or `eth0` for wired) and
read you the number after `inet` — that's the bike's IP. You'll use it
everywhere below in place of `192.168.1.100`.

If no IP appears after a minute: check SSID/password spelling and that it's 2.4
GHz, re-run the script. Ping the IP from the laptop to confirm reachability.

---

## Phase 2 — Reach the bike from the laptop (SSH)

The bike runs an ancient OpenSSH (5.9). Modern clients may reject its key
algorithms. Prefer this repo's wrapper, which supplies the compatibility flags
and does not permanently weaken the human's SSH configuration. If `sshpass` is installed the wrapper supplies the stock password; otherwise
OpenSSH prompts for it. Run:

Login is `expresso` / password `expresso` (stock). Do not paste the WiFi
password, other credentials, or unrelated private data into chat or reports.

```bash
BIKE_HOST=192.168.1.100 ./scripts/xbike 'echo connected && id'
BIKE_HOST=192.168.1.100 ./scripts/xbike --root 'cat /etc/hosts'
BIKE_HOST=192.168.1.100 ./scripts/xbike --put local.sh /tmp/remote.sh
```

**Once SSH works, the USB keyboard can come out** — you now have a path in that
doesn't depend on the bike's screen.

---

## Phase 3 — Fingerprint the bike

Now find out exactly what you're dealing with. Run the probe:

```bash
BIKE_HOST=192.168.1.100 ./scripts/xbike --put compat/probe.sh /tmp/probe.sh
BIKE_HOST=192.168.1.100 ./scripts/xbike 'bash /tmp/probe.sh'
```

`compat/probe.sh` prints a JSON blob: the build directory, Inca version, serial,
subscription flag, the worlds list, how many worlds still carry the BRONZE lock,
and the `inca_requests` DB schema. For a deeper dump (serial devices, logs,
autostart, processes), run `scripts/coldbrew-recon.sh` on the bike the same way.

Key things to establish, and where they live:

| Question | How to check |
|---|---|
| Build version string | `grep -i Version /usr/local/expresso/conf/ef_global.conf`, and the 11-digit dir under `/usr/local/expresso/` |
| Does it match a known profile? | Compare the build string to `compat/profiles/*.json` filenames (`20130123001`, `20180514001`). Profiles are reference evidence; the installer does not currently consume them |
| Where's the game content? | `ls /usr/local/expresso/<build>/ME_Assets/` — `Worlds/`, `Scripts/` |
| How many worlds, which are locked? | probe's `worlds` and `bronze_worlds_remaining` |
| Are the login-gate screens present? | `ls …/ME_Assets/Scripts/ | grep -i 'shell_start\|shell_welcome\|GlobalFunctions'` |
| Is there a route-group gate? | `grep -rl SetLevelGroupGUID …/ME_Assets/Worlds/` (present on 2018, absent on 2013) |
| Serial boards | `ls /dev/ttyUSB*`, `lsusb` (look for Atmel `03eb:6125`) |
| Login-cache table | probe's `inca_requests_schema` |

**Then branch on the result — Phase 4.**

---

## Phase 4 — Unlock

### Case A: the build matches a documented profile (2013 or 2018)

You're done thinking. Run the installer from the laptop. Dry-run first:

```bash
./coldbrew-install.sh --target expresso@192.168.1.100
```

Check that the output names the expected build and paths, reports a backup plan,
and has no missing-file or layout errors. Explain the planned changes, then go
live. Branding is optional and changes the boot splash:

```bash
./coldbrew-install.sh --target expresso@192.168.1.100 --live --with-branding
```

The installer auto-detects the build layout, backs up existing targets, applies
the unlock, blackholes the retired cloud hosts, adjusts sshd, and restarts the
game. Those last two changes are defaults; use `--no-hosts-block` or
`--no-ssh-config` only for a specific reason. Re-running is intended to be
idempotent. Skip to Phase 5.

### Case B: an undocumented model (Expresso Go, or any build not in `compat/profiles/`)

Do not assume the stack or all seven mechanisms are the same. Keep this phase
read-only until you have mapped the layout and compared the actual Lua functions
with `payload/unlock.sh` and `payload/patches/`. Save the complete probe output
locally before changing anything.

If the known installer dry run recognizes the same required files and its plan
matches what you observed, prefer adapting the installer locally over typing
one-off mutations on the bike. Add explicit layout checks, preserve its
timestamped backup/recovery path, run shell syntax checks, then dry-run again.
Only use `--allow-unknown-build` after those checks; the flag relaxes a guard, it
does not prove compatibility. Apply one mechanism at a time and verify it before
continuing.

| # | Mechanism | What it does | Find it on a new model by… | Verify |
|---|---|---|---|---|
| 1 | **World availability** | Flip `SetLevelAvailability(LEVEL_AVAILABILITY_BRONZE)` → `…_ALL` | `grep -rl --include='*.lua' LEVEL_AVAILABILITY_BRONZE …/ME_Assets/Worlds/` (and `cc_*.lua` variants) | re-grep shows 0 BRONZE remaining |
| 2 | **Subscription flag** | `BikeSubscription = 1` in `ef_global.conf` | it's in `/usr/local/expresso/conf/ef_global.conf` | `grep BikeSubscription` reads `1` |
| 3 | **Auth overrides** | Append Lua function overrides to `GlobalFunctions.lua` so login/account always report signed-in, type 999 | find `GlobalFunctions.lua` under `…/ME_Assets/Scripts/`; append `payload/patches/global_functions_append.lua` | grep for the `coldbrew:route-unlock` marker |
| 4 | **Route-group gate** (2018-style only) | Comment out `SetLevelGroupGUID(...)`; stub `RouteGroupThreshold`/`…UnlockScore` | `grep -rl SetLevelGroupGUID …/Worlds/`; if absent, skip (like 2013) | grep shows the calls commented |
| 4.5 | **Pre-ride auto-skip** | Replace `Activate()` in `shell_start.lua` + `shell_welcome.lua` to jump straight to the route list | look for those files in `…/Scripts/`; apply `payload/patches/shell_*_append.lua`. **Do not call `LoginGuest()`** — it POSTs to the dead server and hangs | game boots past the login screens to the route list |
| 5 | **Login-cache DB seed** | Inject a `login_user` row into MySQL `inca_requests` | `payload/sql/inca_requests_seed.sql`; check the schema matches (probe output) | row present; non-fatal if DB empty |
| — | **Sign Out redirect** | Override `ButtonSignOutSelected()` to go to the route list, not the login screen (else auto-skip loops) | it's in the `global_functions_append.lua` block | signing out lands on routes |

Two hard-won facts that will save you (from the 2013 reverse-engineering):

- **Remapping Lua constants does not stick** — Inca re-registers `LOGIN_TYPE_*`
  on the C++ side at runtime. Always use **function overrides** in
  `GlobalFunctions.lua`, never constant reassignment. This is why mechanism 3 is
  built the way it is.
- **`LoginGuest()` is a trap** with the server dead: it POSTs `login_user`, gets
  a connection refused, and can hang on a "Working Offline" modal. The auto-skip
  patch deliberately calls `SetGameState(GAME_STATE_SHELL)` directly instead.

If the new model's file layout differs (different `ME_Assets` path, different
script names), the mechanisms still map one-to-one — adjust the paths, keep the
edits. If a mechanism has no target on this bike (e.g. no `SetLevelGroupGUID`),
note that it's absent and move on; absence is data for the report.

Do not leave the successful path as an unrepeatable series of shell edits. Put
the model-specific layout checks into the installer or a reviewed adapter, then
exercise dry run, live install, verification, and recovery.

---

## Phase 5 — Verify

Restart the game and watch it come up unlocked. On the bike:

```bash
BIKE_HOST=192.168.1.100 ./scripts/xbike \
  "killall Inca Launcher Dispenser 2>/dev/null; sleep 2; cd /usr/local/expresso && nohup ./<build>/bin/Launcher > /tmp/launcher.log 2>&1 < /dev/null &"
```

Confirm with the human, watching the bike's screen:

- It boots past any login/subscription screen straight to the route list.
- **All** routes are selectable, not greyed out.
- No "subscription expired" / "sign in" nag.
- Starting a ride works and resistance responds.

If a route is still locked, re-check mechanism 1 (BRONZE) and 4 (route-group
gate) on that specific world's Lua. If it hangs on a login modal, re-check 4.5
(auto-skip) and confirm `LoginGuest` is not being called.

---

## Phase 6 — Send the model report back (this is the point)

**If this was a new/undocumented model, you are not done until you've produced a
report the maintainer can drop into the repo.** That's what makes the next
person's unlock automatic instead of an investigation. Generate two files.

**1. A machine profile** at `compat/profiles/<build>.json`, matching the existing
ones. Fill every field from your probe output and what you actually did:

```json
{
  "build": "<11-digit build string>",
  "model_name": "<e.g. Expresso Go>",
  "inca_ver": "<from incaversion.txt, or 'unknown'>",
  "expected_worlds": <count>,
  "bronze_worlds": ["<worlds that carried BRONZE>"],
  "steps": ["world_availability", "bike_subscription", "global_functions",
            "auto_skip_shell_start", "auto_skip_shell_welcome", "db_seed"],
  "build_differences_vs_2018": {
    "SetLevelGroupGUID": "<present / absent — and what you did>",
    "auto_skip": "<required / optional / not present>",
    "worlds_dir": "<path, e.g. ME_Assets/Worlds/>",
    "scripts_dir": "<path to GlobalFunctions.lua etc.>",
    "anything_else_surprising": "<...>"
  },
  "verified": true
}
```

**2. A human-readable report** at `docs/models/<model-or-build>.md` covering:

```markdown
# Model report: <model name> (<build string>)

- **Reported by:** <name/handle, optional> — <date>
- **What the bike showed before:** <login nag / locked routes / …>
- **Serial prefix:** <e.g. HDU…, GO…>

## What was the same as documented builds
<which mechanisms applied unchanged>

## What was different
<paths, file names, version string, missing/extra gates — the useful part>

## Exact steps that worked
<the commands you ran, in order — copy them from your session>

## Gotchas / dead ends
<anything that wasted time; what to warn the next person about>

## Probe output
```json
<paste the compat/probe.sh JSON; redact the full serial unless the owner explicitly wants it published>
```
```

**Then get it to the maintainer.** Offer the human two ways:

- **Pull request** (best): fork `github.com/carlkibler/coldbrew-expresso-bike-unlock`,
  add the two files, open a PR titled `Add <model> profile`. If the human has
  `gh` installed and is willing, you can do this for them.
- **Email**: send both files to `carl@carlkibler.com` with subject
  `Coldbrew: <model> unlock report`.

Tell the human plainly: *this five-minute step is what turns your afternoon of
probing into a one-command unlock for the next person with this model.*

---

## Command cheat sheet

```bash
# Reach the bike (from the repo root, on the laptop)
BIKE_HOST=<ip> ./scripts/xbike 'id'                     # run a command on the bike
BIKE_HOST=<ip> ./scripts/xbike --root 'cat /etc/hosts'  # as root
BIKE_HOST=<ip> ./scripts/xbike --put a.sh /tmp/a.sh     # copy a file up

# Fingerprint
BIKE_HOST=<ip> ./scripts/xbike --put compat/probe.sh /tmp/probe.sh
BIKE_HOST=<ip> ./scripts/xbike 'bash /tmp/probe.sh'

# Unlock (documented models — dry run, then live)
./coldbrew-install.sh --target expresso@<ip>
./coldbrew-install.sh --target expresso@<ip> --live --with-branding

# Undo everything
BIKE_HOST=<ip> ./scripts/xbike 'sudo bash /tmp/coldbrew_payload/recover-coldbrew.sh'
```

Deeper background — the binary protocol, DRM hook offsets, serial protocol —
is in [`CLAUDE.md`](../CLAUDE.md) and [`docs/research.md`](research.md).

# Expresso HD Reverse Engineering Research

**Date:** 2026-04-11 (updated 2026-04-17 — live access + full unlock session)
**Confidence notation:** [CONFIRMED] = multiple sources; [LIKELY] = single credible source; [RUMORED] = plausible but unverified; [UNKNOWN] = not found

---

## Live Access — 2026-04-17

### Entry Method
- Plugged USB keyboard; `Alt+F2` opened GNOME run dialog → launched `xterm`
- Already had WiFi adapter: Ralink `RT3290STA` on `wlan0` [CONFIRMED]
- Connected via `wpa_supplicant` + `dhclient`; bike joined the LAN
- Set password for `expresso` user via `sudo passwd expresso`, SSH'd in
- `expresso` user is in `sudo` and `dialout` groups [CONFIRMED]

### App Structure [CONFIRMED]
- App lives in `/usr/local/expresso/` — 13 versioned release directories going back to 2013
- Active version: `20180514001` (built 2018-05-14)
- Binaries: `Launcher`, `Dispenser`, `Inca`
  - `Inca` = UE3 game engine (~21% RAM, 106% CPU during ride)
  - `Dispenser` = cloud sync agent (queues ride data to `services.expresso.net`)
  - `Launcher` = orchestrates startup
- Inca binary version date: `2015-08-12_11-42-35`
- Window manager: `fluxbox`
- Local MySQL database: `expresso_station` (tables: `dispenser_queue`, `dispenser_processed`)
- Config: `/usr/local/expresso/conf/ef_global.conf`
  - Serial number: `HDU00000000` (every bike has its own)
  - LocationName / LocationGUID: vendor-assigned per bike — left as-is by Coldbrew
  - Steering calibration: per-bike, stored in this file

### Controller Board [CONFIRMED]
- **Two Atmel microcontrollers** (`USB VID:PID 03eb:6125`) on a USB hub
  - `ttyUSB0` (FD 20 in Inca) — likely steering board
  - `ttyUSB1` (FD 21 in Inca) — likely MRD (Magnetic Resistance Device)
- Both at **9600 baud, raw mode** (no icanon, no echo)
- Inca polls both with **`poll\r`** (plain ASCII) — confirmed via strace

### Serial Protocol — ttyUSB1 (MRD board) [CONFIRMED]

#### Resistance Control [CONFIRMED — 2026-04-17]

**This is the primary goal. Protocol fully cracked.**

**Init (once):** `hr 1\r` → `H=ON` (enables output stage; `hr 0\r` disables)

**Set resistance:** `mrd N\r` → `D=N` (board ack)
- Range: **0–1888**, steps of 16 (Inca uses multiples of 16)
- **CRITICAL: Must send continuously at ~50Hz (every 20ms).** Board has a watchdog — if commands stop, output cuts to 0. Inca sends mrd on every loop tick.
- Example values during moderate hill: 288–400; max hill: ~1888

**Typical Inca sequence:**
```
hr 1\r          # enable once at startup
mrd 400\r       # set resistance (repeat at 50Hz)
mrd 400\r
mrd 384\r       # terrain changes → new value
...
```

#### Telemetry (poll) [CONFIRMED]

**Command (PC → board):** `poll\r` — Inca actually sends this to ttyUSB0 (S3CONS), not ttyUSB1

**Response (board → PC):** variable-length, starts `0x46` ('F'), ends `0x0a` ('\n')

Example packet: `46 3d 40 5c 2e 40 40 40 40 4d 58 40 4d 59 0a`

**Temperature encoding:** The `4d XX` 2-byte pair near end of packet encodes temperature.
- Interpreted as 16-bit big-endian integer ÷ 1000 = temperature in °C
- `4d 22` = 0x4d22 = 19746 → **19.746°C** ✓

**`0x40` ('@')** = zero/null value (value + 0x40 offset encoding for single-byte fields)

**`5c 2e` / `5d 4e`** — alternating pair in positions 3-4 [UNKNOWN meaning]

**ttyUSB0 (S3CONS board):** Receives `poll\r` continuously; returns steering angle + gear shift data

### Tools on Bike
- `strace` available — requires sudo for ptrace
- `python` (2.7) available
- Scripts deployed: `/home/expresso/velorecon.sh`, `/tmp/analyze.py`

### Captures Collected
- `diags.txt` — terminal session log from initial exploration
- `serial_cap_20260417_124004.txt` — strace serial capture (146 ttyUSB1 packets)
- `velorecon.sh` — automated recon + WiFi setup script

### Content Unlock — 2026-04-17 [CONFIRMED]

All 60 worlds unlocked, all games/activities accessible. Three separate lock mechanisms found and bypassed:

#### Lock 1: World availability (lua files)
13 worlds had `SetLevelAvailability(LEVEL_AVAILABILITY_BRONZE)` → patched to `LEVEL_AVAILABILITY_ALL`.
```bash
grep -rl 'LEVEL_AVAILABILITY_BRONZE' ME_Assets/Worlds/ | grep -v cc_ | xargs sed -i 's/LEVEL_AVAILABILITY_BRONZE/LEVEL_AVAILABILITY_ALL/g'
```

#### Lock 2: eLive subscription check (ef_global.conf)
`IsELiveActive()` disassembly (0x828d1b3): checks `GetBikeSubscription()` == 1 or 4 only.
- Default `BikeSubscription = 5` → eLive inactive → Bronze worlds locked
- Fix: `sed -i 's/^BikeSubscription = .*/BikeSubscription = 1/' /usr/local/expresso/conf/ef_global.conf`
- Value persists across restarts; dead server can't override it

#### Lock 3: Rider ID login requirement (GlobalFunctions.lua)
Games check `GetLoginType() <= LOGIN_TYPE_GUEST` to block unregistered users.
- C++ Lua constants (via `tolua_constant`): `LOGIN_TYPE_PROVISIONAL=-1`, `LOGIN_TYPE_GUEST=0`, `LOGIN_TYPE_ID=1`
- Without server, `GetLoginType()` returns 0 (GUEST) → all games locked
- Fix: append to `ME_Assets/Scripts/GlobalFunctions.lua`:
  ```lua
  LOGIN_TYPE_PROVISIONAL = -2
  LOGIN_TYPE_GUEST       = -1
  LOGIN_TYPE_ID          = 0
  ```
  This remaps constants so the current in-memory state (0) equals `LOGIN_TYPE_ID`

#### Lock 4: Minimum points / route_group threshold
Game modes (speed/tactics/power variants) have `SetLevelGroupGUID(...)` in their lua files.
- `RouteGroupIsLocked()` logic: gets threshold via `RouteGroupThreshold(guid)` → looks up `CUserSession::FindRouteGroupByGuid()` → `CRouteGroup::GetThreshold()`
- With dead server, `CUserSession` has no route group data → `FindRouteGroupByGuid()` returns NULL → threshold returned as INT_MAX → **always locked**
- Fix: comment out `SetLevelGroupGUID(...)` in all 30 game lua files
- Without a group GUID, `GetRouteGroupGuid()` returns NULL → `RouteGroupIsLocked()` returns false immediately (unlocked)
- Pattern: `sed -i 's/SetLevelGroupGUID([^)]*)\/-- & -- Coldbrew: removed/g'`
- Affected: 30 files across DragonsReturn, DragonsRevenge, AnimalAdventure, MazeMania, DragonsIsland, Outpost, CoinToss, and ~4 more worlds

#### Inca internals discovered
- Inca/Dispenser IPC: SysV message queues, `/tmp/ef_app_q` used as `ftok()` key
- `inca_requests` MySQL = per-session fetch_data response cache (cleared on restart)
- `dispenser_processed` = outgoing POST requests to services.expresso.net
- Login type: in-memory `CLoginManager+0x44` — not persisted to config
- Bike subscription: in-memory `CMain+0xEC` — initialized from `ef_global.conf BikeSubscription`

---

---

## Hardware

| Component | Detail | Confidence |
|---|---|---|
| Computer | Giada G300 mini-PC | CONFIRMED |
| CPU | Intel Core i5-4200U (Haswell, 2c/4t, 1.8/2.7 GHz, 15W) | CONFIRMED |
| GPU | NVIDIA GeForce GT 730 (discrete) | CONFIRMED |
| OS | Ubuntu 12.04.5 LTS, 32-bit | CONFIRMED |
| Display | 23" HD LED touchscreen | CONFIRMED |
| Storage | Standard SATA HDD (removable, reimageable) | CONFIRMED |
| Networking | Wired RJ-45 + WiFi | CONFIRMED |

The Giada G300 is a small-form-factor embedded PC (~200mm × 200mm). Marketing copy:
> "Giada is a world leader in gaming computers, and the bullet-proof base unit in Expresso HD is manufactured to withstand harsh environments while delivering spectacular graphics."

## "Gaija/Gaia" Boot Screen

Almost certainly the **Giada Technology** OEM logo appearing during POST/BIOS — not an Expresso brand. "Giada" (吉 jia) misread on a brief splash. [LIKELY]

---

## Software Stack

- **OS:** Ubuntu 12.04.5 LTS (EOL April 2017 — full of known CVEs)
- **Game engine:** Unreal Engine 3 (UDK era) — confirmed via Capti bike successor docs
- **Rendering:** OpenGL on Linux (UE3 Linux uses OpenGL, not DirectX)
- **Content:** `.upk` / `.pak` files, readable with UE viewer tools once disk access obtained
- **Application path:** Likely `/opt/expresso/` or `/home/expresso/`
- **Config mode code (S2 series):** `7913`

---

## Resistance Control Architecture

```
[Giada G300 PC] ←→ USB/Serial ←→ [Controller Board]
                                    ├── Eddy current brake (resistance)
                                    ├── Steering angle encoder
                                    ├── Cadence/speed sensor
                                    └── Gear shifter (handlebar)
```

- Resistance is electromagnetic eddy-current
- Controller board is separate from the PC
- Communication protocol: **UNKNOWN** — likely USB-CDC or FTDI presenting as `/dev/ttyUSB0`, or RS-232
- Game engine sends resistance commands 50×/sec based on terrain grade
- If PC app not running → bike defaults to fixed resistance

---

## Company / Ownership History

- **2003:** Founded, Sunnyvale CA
- **2009:** Acquired by Interactive Fitness Holdings (IFH)
- **April 2022:** Acquired by **Blue Goji**
- **Dec 31, 2025:** eLive service EOL for GO/CC3 series (HD series moved to GojiPlay)

Blue Goji replaced the Linux/Giada platform with **Windows/Lenovo** for their GojiPlay upgrade kit. Your bike (original HD, pre-upgrade) still runs Ubuntu 12.04.

---

## Attack Surface

### Easiest first — recommended order:

1. **USB keyboard → kiosk escape**
   - Plug in USB keyboard
   - Try: `Ctrl+Alt+T` (terminal), `Ctrl+Alt+F2` (TTY2), `Alt+F2` (run dialog)
   - Ubuntu 12.04 desktop responds to these unless actively suppressed

2. **GRUB recovery at boot**
   - Hold `Shift` or press `Esc` during boot to get GRUB menu
   - Select "recovery mode" or edit kernel line: append `init=/bin/bash`
   - Gives root shell before the kiosk app launches

3. **Ethernet scan**
   - Connect to router, find bike IP in DHCP table
   - `nmap -sV <bike-ip>` — look for SSH (22), HTTP (80), custom ports
   - Try credentials: `ubuntu/ubuntu`, `root/root`, `expresso/expresso`

4. **Pull the SATA drive**
   - Mount on Linux machine, read filesystem directly
   - Identify serial device name for controller board (`/dev/ttyUSB0`, `/dev/ttyS0`)
   - Read application binary, config files, Unreal content packages

5. **Dirty COW if needed**
   - CVE-2016-5195 — works on Ubuntu 12.04 kernels (3.2.x / 3.13.x)
   - Local privilege escalation to root if you have any user shell

6. **Sniff controller board serial**
   - Once you have filesystem access, `strace` or direct capture on the serial device
   - Reveals resistance command protocol format

---

## FCC / Patents

- **FCC ID:** WT2-EF-BIKE (S3 series, filed 2009-01-22 by Interactive Fitness Holdings)
  - Internal photos at: https://fccid.io/WT2-EF-BIKE
  - HD series likely inherits Giada G300's own FCC certification
- **Patent US6902513B1:** "Interactive fitness equipment" — core virtual terrain + resistance + networked competition patent
  - https://patents.google.com/patent/US6902513B1/en

---

## Existing RE Community

None found. No GitHub repos, no iFixit teardowns, no XDA threads specific to Expresso HD.

A few LinuxQuestions threads (2017) show users encountering Linux filesystem errors and replacing the HDD — confirming the platform and that boot messages are visible. Champion Fitness (authorized repair) reimages drives.

This is unexplored territory.

---

## Reference Documents

| Document | URL |
|---|---|
| FCC filing (S3, internal photos) | https://fccid.io/WT2-EF-BIKE |
| S3 User Manual | https://fccid.io/WT2-EF-BIKE/User-Manual/Expresso-Fitness-Users-Manual-1060936 |
| S3 Install Guide (PDF) | https://s3.amazonaws.com/docs.ifholdings.com/IFH_S3_INSTALL.pdf |
| Networking Guide (PDF) | https://s3.amazonaws.com/docs.ifholdings.com/INTERACTIVE_NETWORK_GUIDE.pdf |
| HD Upright User Guide (PDF) | https://s3.amazonaws.com/docs.ifholdings.com/Expresso_HD_Upright_User_Guide.pdf |
| S2 Service Guide (Scribd) | https://www.scribd.com/document/258642107/Expresso-Bikes-S2-Service-Guide-1a |
| Blue Goji upgrade page | https://www.bluegoji.com/upgradehome |
| Champion Fitness (repair) | https://championfitness.com/ |
| Patent US6902513B1 | https://patents.google.com/patent/US6902513B1/en |
| Blue Goji acquisition PR | https://www.businesswire.com/news/home/20220425005675/en/ |
| Giada G300 mini-PC review | https://www.reimarufiles.com/2014/06/06/giada-g300-mini-pc/ |
| LinuxQuestions HDD thread | https://www.linuxquestions.org/questions/linux-newbie-8/hard-drive-corrupted-4175617662/ |

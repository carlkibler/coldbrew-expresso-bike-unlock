# Deferred: Local Ghost Riders

Deliberately skipped in the custom-tracks phase. Fully reconned; design is ready.

## What we know

- Inca **auto-writes** `GhostRecord-0..9.efr` to its CWD (`/usr/local/expresso/20180514001/`) on every session, unconditionally. No login or server required. Confirmed: a fresh 180-byte file was written in an idle no-login session.
- **EFR format:** 180-byte header (version, magic `0xca15e517`, route name at offset 0x20) + 12-byte records (float, float, int32 — likely distance%, speed, gear).
- Files rotate through 10 slots. `GhostReplay-0.efr` is the replay input.
- **Native ghost system is fully implemented** in the unstripped Inca binary:
  - `CGhostRider::{StartRecord,CloseRecord,StartReplay,CloseReplay,SetGhostRideFileName(char*),WriteRecordHeader,ReadReplayHeader,PositionGhostRider}`
  - `CRoute::SetGhostRide(CUserGhostData&)`, `CLoginManager::LoadGhostRideForRoute`
  - `CurrentRouteGhostAvailable()` — Lua-bound read-only check
  - `CRoute_GetGhostRideDate/Duration/VersusName/Type` — all Lua-bound

## Recommended implementation

**Phase A (opaque-blob + Lua hook)** — endorsed by independent Gemini and Copilot review:

1. Python sidecar daemon (inotify) watches Inca CWD. After each ride, parses header (route name, magic, file size), content-hashes with SHA256, archives to `/var/lib/coldbrew/ghosts/<hash>.efr` with SQLite index.
2. Minimal HTTP server on `127.0.0.1:8347` — `GET /ghosts?route=<name>` returns JSON list; `POST /ghosts/select {id}` copies blob to `GhostReplay-0.efr`.
3. Lua patch in `shell_RouteSelection.lua` adds "Race Ghost" button — queries sidecar via `io.popen("curl -s ...")`, shows list of past rides for current route, on selection triggers sidecar copy + starts ride.
4. Fallback: if `CurrentRouteGhostAvailable()` returns false after blob staging, serve minimal `<ghost_ride_definition>` XML via extended `fake-server.sh`. Both external LLMs said this fallback handles the CUserGhostData population concern.

## Files to create

- `coldbrew/sidecar/watcher.py` — inotify + archiver
- `coldbrew/sidecar/api.py` — wsgiref HTTP
- `coldbrew/sidecar/db.py` — SQLite schema
- `coldbrew/systemd/coldbrew-sidecar.service`
- Lua patches to `shell_RouteSelection.lua`, `Scripts/GlobalFunctions.lua`

## Risk / unknowns

- Does Inca require `CUserGhostData` populated in memory (via `LoadGhostRideForRoute`) before it renders the ghost avatar, or is the `.efr` file sufficient? → Test empirically by staging a blob and checking if ghost appears.
- Header parsing must validate magic `0xca15e517` to avoid archiving corrupt/partial files.

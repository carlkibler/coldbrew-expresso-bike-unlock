#!/bin/bash
# Coldbrew unlock payload — applies all four content-unlock mechanisms.
# Idempotent: safe to run on an already-patched bike.
# Usage: sudo bash unlock.sh <BUILD_DIR> [--dry-run]
#
# Steps:
#   1. World availability: LEVEL_AVAILABILITY_BRONZE → LEVEL_AVAILABILITY_ALL (13 worlds)
#   2. BikeSubscription = 1 in ef_global.conf
#   3+4. Append GlobalFunctions.lua patch block (route-unlock + login-remap)
#   5. Seed inca_requests MySQL table (60 routes)

set -euo pipefail

BUILD_DIR="${1:?usage: unlock.sh <BUILD_DIR> [--dry-run]}"
DRY=false
[[ "${2:-}" == "--dry-run" ]] && DRY=true

EXPRESSO_ROOT="/usr/local/expresso"
BASE="$EXPRESSO_ROOT/$BUILD_DIR/ME_Assets"
CONF="$EXPRESSO_ROOT/conf/ef_global.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Validate build dir exists
if [ ! -d "$BASE" ]; then
  echo "ERROR: build dir not found: $BASE" >&2
  exit 1
fi

log() { echo "[coldbrew] $*"; }
drylog() { $DRY && echo "[dry-run] $*" || true; }
apply() {
  local desc="$1"; shift
  if $DRY; then
    drylog "$desc"
  else
    log "$desc"
    eval "$@"
  fi
}

# ── Backup ─────────────────────────────────────────────────────────────────────
BIKE_SERIAL=$(grep -i 'SerialNumber' "$CONF" 2>/dev/null | cut -d= -f2 | tr -d ' \r' || echo "unknown")
BACKUP="/home/expresso/coldbrew_backup_${BIKE_SERIAL}_$(date +%Y%m%d_%H%M%S).tgz"

if ! $DRY; then
  log "Creating backup → $BACKUP"
  tar -czf "$BACKUP" \
    "$BASE/Worlds/"*/*.lua \
    "$BASE/Scripts/GlobalFunctions.lua" \
    "$CONF" 2>/dev/null || true
  echo "BACKUP:$BACKUP"
fi

# ── Mechanism 1: World availability ───────────────────────────────────────────
# Patches BOTH main world lua and cc_*.lua (CyberCycle) variants — on older
# builds the cc_ files carry their own BRONZE lock and leaving them locked
# hides most of the Games tab.
BRONZE_FILES=$(grep -rl --include='*.lua' 'LEVEL_AVAILABILITY_BRONZE' "$BASE/Worlds/" 2>/dev/null || true)
COUNT=$(echo "$BRONZE_FILES" | grep -c '.' || true)

if [ "$COUNT" -eq 0 ]; then
  log "Mechanism 1: already patched (no BRONZE files)"
else
  apply "Mechanism 1: patching $COUNT world lua files (BRONZE → ALL)" \
    "echo \"\$BRONZE_FILES\" | xargs sed -i 's/LEVEL_AVAILABILITY_BRONZE/LEVEL_AVAILABILITY_ALL/g'"
fi

# ── Mechanism 2: BikeSubscription ──────────────────────────────────────────────
if grep -q 'BikeSubscription = 1' "$CONF" 2>/dev/null; then
  log "Mechanism 2: already patched (BikeSubscription = 1)"
else
  apply "Mechanism 2: set BikeSubscription = 1 in ef_global.conf" \
    "sed -i 's/^BikeSubscription = .*/BikeSubscription = 1/' \"$CONF\""
fi

# ── Mechanism 3+4: GlobalFunctions.lua auth overrides ─────────────────────────
# Current sentinel: coldbrew:auth-v2. Refresh whenever the on-disk block
# differs from the payload so payload changes reliably deploy. Also strip any
# legacy (pre-v2) block with the older sentinel.
GF="$BASE/Scripts/GlobalFunctions.lua"
GF_PATCH="$SCRIPT_DIR/patches/global_functions_append.lua"
CURRENT_SENTINEL='coldbrew:auth-v2'
LEGACY_SENTINEL='coldbrew:route-unlock'

gf_existing=$(sed -n "/-- ${CURRENT_SENTINEL}/,\$p" "$GF" 2>/dev/null || true)
gf_payload=$(sed -n "/-- ${CURRENT_SENTINEL}/,\$p" "$GF_PATCH")

if [ -n "$gf_existing" ] && [ "$gf_existing" = "$gf_payload" ]; then
  log "Mechanism 3+4: already patched (${CURRENT_SENTINEL}, up-to-date)"
else
  if grep -q "$LEGACY_SENTINEL" "$GF" 2>/dev/null; then
    apply "Mechanism 3+4: removing legacy coldbrew block" \
      "sed -i '/-- ${LEGACY_SENTINEL}/,\$d' \"$GF\""
  fi
  if grep -q "$CURRENT_SENTINEL" "$GF" 2>/dev/null; then
    apply "Mechanism 3+4: refreshing auth overrides (content changed)" \
      "sed -i '/-- ${CURRENT_SENTINEL}/,\$d' \"$GF\" && cat \"$GF_PATCH\" >> \"$GF\""
  else
    apply "Mechanism 3+4: appending auth overrides" \
      "cat \"$GF_PATCH\" >> \"$GF\""
  fi
fi

# ── Mechanism 4.5: auto-skip pre-ride UI screens ──────────────────────────────
# Two Lua screens gate the ride flow on the 2013 build:
#   shell_start.lua   (GAME_STATE_USER_LOGIN): SIGN IN / JOIN / TRY landing
#   shell_welcome.lua (GAME_STATE_WELCOME):   stats / menu after login
# We chain Activate() in each so Inca auto-advances through both to the
# route selection. Guarded by a per-file sentinel for idempotency.
skip_screen() {
  local lua_path="$1"
  local patch_file="$2"
  local sentinel="$3"
  local label="$4"
  if [ ! -f "$lua_path" ]; then
    log "Mechanism 4.5: $label not present — skipping"
    return
  fi
  # Compare the appended block (from our sentinel to EOF) to the current payload.
  # If they match, skip. Otherwise strip and re-append so payload changes take effect.
  local existing
  existing=$(sed -n "/-- ${sentinel}/,\$p" "$lua_path" 2>/dev/null || true)
  if [ -n "$existing" ] && diff -q <(printf '%s' "$existing") <(sed -n "/-- ${sentinel}/,\$p" "$patch_file") >/dev/null 2>&1; then
    log "Mechanism 4.5: $label already patched ($sentinel, up-to-date)"
    return
  fi
  if grep -q "coldbrew:autoskip" "$lua_path" 2>/dev/null; then
    apply "Mechanism 4.5: refreshing $label auto-skip block" \
      "sed -i '/-- coldbrew:autoskip/,\$d' \"$lua_path\" && cat \"$patch_file\" >> \"$lua_path\""
  else
    apply "Mechanism 4.5: appending $label auto-skip" \
      "cat \"$patch_file\" >> \"$lua_path\""
  fi
}

skip_screen "$BASE/Shell/shell_start.lua" \
  "$SCRIPT_DIR/patches/shell_start_append.lua" \
  'coldbrew:autoskip-start' \
  'shell_start.lua'

skip_screen "$BASE/Shell/shell_welcome.lua" \
  "$SCRIPT_DIR/patches/shell_welcome_append.lua" \
  'coldbrew:autoskip-welcome' \
  'shell_welcome.lua'

# ── Mechanism 5: DB session patch (non-fatal; belt-and-suspenders for current session) ─
MYSQL_CREDS=""
if sudo -n test -f /etc/mysql/debian.cnf 2>/dev/null; then
  _U=$(sudo -n cat /etc/mysql/debian.cnf | awk -F'= *' '/^user/{print $2; exit}' | tr -d ' ')
  _P=$(sudo -n cat /etc/mysql/debian.cnf | awk -F'= *' '/^password/{print $2; exit}' | tr -d ' ')
  MYSQL_CREDS="-u${_U} -p${_P}"
fi

if [ -n "$MYSQL_CREDS" ]; then
  # Get current session guid from the live table (most recent non-login row)
  SESSION_GUID=$(mysql expresso_station $MYSQL_CREDS -sNe \
    "SELECT session_guid FROM inca_requests ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
  if [ -z "$SESSION_GUID" ]; then
    log "Mechanism 5: inca_requests empty (game not running?) — skipping DB patch"
  else
    ALREADY=$(mysql expresso_station $MYSQL_CREDS -sNe \
      "SELECT COUNT(*) FROM inca_requests WHERE session_guid='$SESSION_GUID' AND data LIKE '%coldbrew%';" 2>/dev/null || echo "0")
    if [ "$ALREADY" -gt 0 ]; then
      log "Mechanism 5: session $SESSION_GUID already has coldbrew login_user row"
    else
      SEED_SQL="$SCRIPT_DIR/sql/inca_requests_seed.sql"
      if ! $DRY; then
        log "Mechanism 5: injecting login_user for session $SESSION_GUID"
        sed "s/__SESSION_GUID__/$SESSION_GUID/" "$SEED_SQL" \
          | mysql expresso_station $MYSQL_CREDS 2>/dev/null || \
          log "Mechanism 5: DB inject failed (non-fatal — Lua patches handle this)"
      else
        drylog "Mechanism 5: would inject login_user for session $SESSION_GUID"
      fi
    fi
  fi
else
  log "Mechanism 5: no MySQL credentials found — skipping DB patch"
fi

if $DRY; then
  log "Done (dry run — nothing changed)"
else
  log "Done"
fi

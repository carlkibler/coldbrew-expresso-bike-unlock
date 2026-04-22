#!/bin/bash
# Coldbrew installer for Expresso HD bikes.
# Safe by default: dry-run unless --live is passed.

set -euo pipefail

LIVE=false
BUILD_DIR=""
BACKUP_ROOT="/home/expresso/coldbrew_backups"
WITH_HOSTS_BLOCK=true
WITH_SSH_CONFIG=true
WITH_WATCHDOG=false
WITH_FAKE_SERVER=false
WITH_BRANDING=false
RESTART_GAME=true
ALLOW_UNKNOWN_BUILD=false

usage() {
  cat <<'EOF'
Usage: bash install-coldbrew.sh [options]

Options:
  --live                 Apply changes. Without this, print the plan only.
  --build BUILD          Target build dir under /usr/local/expresso (auto-detect by default)
  --backup-root DIR      Backup root on bike (default: /home/expresso/coldbrew_backups)
  --no-hosts-block       Skip blackholing legacy servers in /etc/hosts (on by default)
  --no-ssh-config        Skip sshd_config improvements (UseDNS no, no GSSAPI) (on by default)
  --with-watchdog        Install ef-watchdog scripts/config
  --with-fake-server     Install fake-server.sh
  --with-branding        Install coldbrew splash assets/script
  --no-restart           Do not restart Launcher/Inca after install
  --allow-unknown-build  Proceed on builds that do not match the known HD layout checks
  -h, --help             Show help

Notes:
  - Dry-run is the default.
  - This script creates a timestamped backup directory before touching files.
  - It wraps unlock.sh for the route/login patches, then optionally installs
    extra coldbrew payload pieces.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --live) LIVE=true ;;
    --build) BUILD_DIR="${2:?missing value for --build}"; shift ;;
    --backup-root) BACKUP_ROOT="${2:?missing value for --backup-root}"; shift ;;
    --no-hosts-block) WITH_HOSTS_BLOCK=false ;;
    --no-ssh-config) WITH_SSH_CONFIG=false ;;
    --with-watchdog) WITH_WATCHDOG=true ;;
    --with-fake-server) WITH_FAKE_SERVER=true ;;
    --with-branding) WITH_BRANDING=true ;;
    --no-restart) RESTART_GAME=false ;;
    --allow-unknown-build) ALLOW_UNKNOWN_BUILD=true ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPRESSO_ROOT="/usr/local/expresso"
CONF="$EXPRESSO_ROOT/conf/ef_global.conf"

log() { echo "[coldbrew] $*"; }
run() {
  if $LIVE; then
    eval "$@"
  else
    echo "[dry-run] $*"
  fi
}

require_file() {
  [ -f "$1" ] || { echo "Required file missing: $1" >&2; exit 1; }
}

detect_build() {
  if [ -n "$BUILD_DIR" ]; then
    echo "$BUILD_DIR"
    return
  fi
  ls -1t "$EXPRESSO_ROOT" 2>/dev/null | grep -E '^[0-9]{11}$' | head -1 || true
}

BUILD_DIR="$(detect_build)"
[ -n "$BUILD_DIR" ] || { echo "No build dir found under $EXPRESSO_ROOT" >&2; exit 1; }

BASE="$EXPRESSO_ROOT/$BUILD_DIR"
GF="$BASE/ME_Assets/Scripts/GlobalFunctions.lua"
TICKER="$BASE/ME_Assets/Scripts/Ticker.lua"
WORLDS_DIR="$BASE/ME_Assets/Worlds"

require_file "$CONF"
require_file "$GF"
require_file "$TICKER"
[ -d "$WORLDS_DIR" ] || { echo "Missing worlds dir: $WORLDS_DIR" >&2; exit 1; }

if ! $ALLOW_UNKNOWN_BUILD; then
  [ -f "$BASE/bin/Launcher" ] || { echo "Missing Launcher in $BASE/bin" >&2; exit 1; }
  [ -f "$BASE/bin/Inca" ] || { echo "Missing Inca in $BASE/bin" >&2; exit 1; }
fi

SERIAL="$(grep -i '^SerialNumber' "$CONF" | cut -d= -f2 | tr -d ' \r' || true)"
[ -n "$SERIAL" ] || SERIAL="unknown"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/${SERIAL}_${BUILD_DIR}_${STAMP}"
BACKUP_TGZ="$BACKUP_DIR/files.tgz"
DB_SQL="$BACKUP_DIR/expresso_station.sql"
META="$BACKUP_DIR/metadata.env"

backup_path() {
  case "$1" in
    /) return 0 ;;
  esac
  [ -e "$1" ] && printf '%s\n' "$1"
  return 0
}

collect_backup_items() {
  backup_path "$CONF"
  backup_path "$GF"
  backup_path "$TICKER"
  backup_path "$BASE/ME_Assets/Shell/shell_start.lua"
  backup_path "$BASE/ME_Assets/Shell/shell_welcome.lua"
  [ -f /etc/hosts ] && backup_path /etc/hosts || true
  [ -f /etc/ssh/sshd_config ] && backup_path /etc/ssh/sshd_config || true
  [ -f /home/expresso/script/gnome-startup-custom.sh ] && backup_path /home/expresso/script/gnome-startup-custom.sh || true
  [ -f /usr/local/bin/ef-watchdog.sh ] && backup_path /usr/local/bin/ef-watchdog.sh || true
  [ -f /etc/init/ef-watchdog.conf ] && backup_path /etc/init/ef-watchdog.conf || true
  [ -f /usr/local/bin/fake-server.sh ] && backup_path /usr/local/bin/fake-server.sh || true
  [ -f /usr/local/expresso/coldbrew-splash.sh ] && backup_path /usr/local/expresso/coldbrew-splash.sh || true
  [ -d /usr/local/expresso/coldbrew ] && backup_path /usr/local/expresso/coldbrew || true

  # If the payload ships any custom world files at $SCRIPT_DIR/worlds/, also
  # back up the on-bike versions they'd overwrite. Empty in the public release.
  if [ -d "$SCRIPT_DIR/worlds" ]; then
    /usr/bin/find "$SCRIPT_DIR/worlds" -type f 2>/dev/null | while read -r local_file; do
      rel="${local_file#$SCRIPT_DIR/worlds/}"
      backup_path "$WORLDS_DIR/$rel"
    done
  fi
}

create_backup() {
  log "Creating backup dir: $BACKUP_DIR"
  run "mkdir -p '$BACKUP_DIR'"

  local tmp_list
  tmp_list="$(mktemp)"
  collect_backup_items | sort -u > "$tmp_list"

  if $LIVE; then
    tar -czf "$BACKUP_TGZ" $(cat "$tmp_list")
    if command -v mysqldump >/dev/null 2>&1 && sudo -n test -f /etc/mysql/debian.cnf 2>/dev/null; then
      mysqldump --defaults-file=/etc/mysql/debian.cnf expresso_station > "$DB_SQL" 2>/dev/null || true
    fi
    cat > "$META" <<EOF
SERIAL=$SERIAL
BUILD_DIR=$BUILD_DIR
CREATED_AT=$STAMP
BACKUP_DIR=$BACKUP_DIR
BACKUP_TGZ=$BACKUP_TGZ
DB_SQL=$DB_SQL
WITH_HOSTS_BLOCK=$WITH_HOSTS_BLOCK
WITH_SSH_CONFIG=$WITH_SSH_CONFIG
WITH_WATCHDOG=$WITH_WATCHDOG
WITH_FAKE_SERVER=$WITH_FAKE_SERVER
WITH_BRANDING=$WITH_BRANDING
EOF
  else
    log "Would archive $(wc -l < "$tmp_list" | tr -d ' ') paths into $BACKUP_TGZ"
  fi

  rm -f "$tmp_list"
}

copy_if_present() {
  local src="$1"
  local dst="$2"
  require_file "$src"
  run "mkdir -p '$(dirname "$dst")'"
  run "cp '$src' '$dst'"
}

install_branding() {
  run "mkdir -p /usr/local/expresso/coldbrew"
  run "cp '$SCRIPT_DIR/coldbrew/'*.jpg /usr/local/expresso/coldbrew/"
  copy_if_present "$SCRIPT_DIR/coldbrew-splash.sh" "/usr/local/expresso/coldbrew-splash.sh"
  run "chmod 755 /usr/local/expresso/coldbrew-splash.sh"

  # Wire the splash into gnome-startup-custom.sh so it runs during the
  # boot-to-Inca gap. Idempotent via sentinel marker. The splash script
  # backgrounds itself and self-exits when Inca's X window appears.
  local startup="/home/expresso/script/gnome-startup-custom.sh"
  if [ -f "$startup" ]; then
    if grep -q 'coldbrew-splash.sh' "$startup"; then
      log "Branding: gnome-startup-custom.sh already wired"
    else
      log "Branding: wiring coldbrew-splash into gnome-startup-custom.sh"
      run "sed -i '/^exec .*Launcher/i\\
# coldbrew:splash — show branded image during boot-to-Inca gap\\
[ -x /usr/local/expresso/coldbrew-splash.sh ] \\&\\& /usr/local/expresso/coldbrew-splash.sh \\&\\
' \"$startup\""
    fi
  else
    log "Branding: no ~/script/gnome-startup-custom.sh — splash won't auto-start"
  fi
}

restart_game() {
  $RESTART_GAME || return 0
  local restart_cmd
  restart_cmd="killall Inca Launcher Dispenser 2>/dev/null || true; sleep 2; cd '$EXPRESSO_ROOT' && nohup './$BUILD_DIR/bin/Launcher' > /tmp/launcher.log 2>&1 < /dev/null &"
  run "$restart_cmd"
}

verify_post_install() {
  grep -q 'BikeSubscription = 1' "$CONF" || { echo "BikeSubscription patch missing" >&2; exit 1; }
  grep -q 'coldbrew:auth-v2' "$GF" || { echo "GlobalFunctions patch missing" >&2; exit 1; }
}

log "Target serial: $SERIAL"
log "Target build:  $BUILD_DIR"
log "Mode:          $([ "$LIVE" = true ] && echo live || echo dry-run)"
log "Backup dir:    $BACKUP_DIR"

create_backup

log "Applying core unlock payload"
if $LIVE; then
  bash "$SCRIPT_DIR/unlock.sh" "$BUILD_DIR"
else
  bash "$SCRIPT_DIR/unlock.sh" "$BUILD_DIR" --dry-run
fi

if $WITH_HOSTS_BLOCK; then
  log "Installing hosts blackhole"
  copy_if_present "$SCRIPT_DIR/etc/hosts" "/etc/hosts"
  if grep -q '^TimeoutUserLoginSeconds' "$CONF"; then
    run "sed -i 's|^TimeoutUserLoginSeconds = .*|TimeoutUserLoginSeconds = 1|' \"$CONF\""
  else
    run "printf 'TimeoutUserLoginSeconds = 1\\n' >> \"$CONF\""
  fi
fi

if $WITH_SSH_CONFIG; then
  log "Installing sshd_config (UseDNS no) and reloading sshd"
  copy_if_present "$SCRIPT_DIR/etc/ssh/sshd_config" "/etc/ssh/sshd_config"
  run "service ssh reload 2>/dev/null || /etc/init.d/ssh reload 2>/dev/null || true"
fi

if $WITH_WATCHDOG; then
  log "Installing watchdog"
  copy_if_present "$SCRIPT_DIR/usr/local/bin/ef-watchdog.sh" "/usr/local/bin/ef-watchdog.sh"
  copy_if_present "$SCRIPT_DIR/etc/init/ef-watchdog.conf" "/etc/init/ef-watchdog.conf"
  run "chmod 755 /usr/local/bin/ef-watchdog.sh"
fi

if $WITH_FAKE_SERVER; then
  log "Installing fake server helper"
  copy_if_present "$SCRIPT_DIR/usr/local/bin/fake-server.sh" "/usr/local/bin/fake-server.sh"
  run "chmod 755 /usr/local/bin/fake-server.sh"
fi

if $WITH_BRANDING; then
  log "Installing coldbrew branding"
  install_branding
fi

if $LIVE; then
  verify_post_install
fi
restart_game

echo "BACKUP_DIR:$BACKUP_DIR"
echo "BACKUP_TGZ:$BACKUP_TGZ"
log "Done"

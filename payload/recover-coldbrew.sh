#!/bin/bash
# Recover a bike from a backup directory created by install-coldbrew.sh
# or a legacy tarball created by unlock.sh.

set -euo pipefail

INPUT="${1:-}"
RESTART_GAME=true

usage() {
  cat <<'EOF'
Usage: bash recover-coldbrew.sh [BACKUP_DIR|BACKUP_TGZ] [--no-restart]

If no path is supplied, the most recent backup under /home/expresso/coldbrew_backups
or /home/expresso/coldbrew_backup_*.tgz is used.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-restart) RESTART_GAME=false ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [ -z "$INPUT" ]; then
        INPUT="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      ;;
  esac
  shift
done

latest_backup() {
  local dir
  dir="$(ls -dt /home/expresso/coldbrew_backups/* 2>/dev/null | head -1 || true)"
  if [ -n "$dir" ]; then
    echo "$dir"
    return
  fi
  ls -t /home/expresso/coldbrew_backup_*.tgz 2>/dev/null | head -1 || true
}

[ -n "$INPUT" ] || INPUT="$(latest_backup)"
[ -n "$INPUT" ] || { echo "No backup found" >&2; exit 1; }

if [ -d "$INPUT" ]; then
  BACKUP_DIR="$INPUT"
  BACKUP_TGZ="$BACKUP_DIR/files.tgz"
  DB_SQL="$BACKUP_DIR/expresso_station.sql"
elif [ -f "$INPUT" ]; then
  BACKUP_TGZ="$INPUT"
  BACKUP_DIR="$(dirname "$INPUT")"
  DB_SQL="${INPUT%.tgz}_inca_requests.sql"
else
  echo "Backup path not found: $INPUT" >&2
  exit 1
fi

[ -f "$BACKUP_TGZ" ] || { echo "Backup archive missing: $BACKUP_TGZ" >&2; exit 1; }

echo "[coldbrew-recover] Restoring files from $BACKUP_TGZ"
tar -xzf "$BACKUP_TGZ" -C /

if [ -f "$DB_SQL" ] && command -v mysql >/dev/null 2>&1; then
  echo "[coldbrew-recover] Restoring DB from $DB_SQL"
  if sudo -n test -f /etc/mysql/debian.cnf 2>/dev/null; then
    mysql --defaults-file=/etc/mysql/debian.cnf expresso_station < "$DB_SQL" 2>/dev/null || true
  else
    mysql expresso_station < "$DB_SQL" 2>/dev/null || true
  fi
fi

if $RESTART_GAME; then
  echo "[coldbrew-recover] Restarting game"
  killall Inca Launcher Dispenser 2>/dev/null || true
  sleep 2
  BUILD_DIR="$(ls -1t /usr/local/expresso 2>/dev/null | grep -E '^[0-9]{11}$' | head -1 || true)"
  if [ -n "$BUILD_DIR" ]; then
    cd /usr/local/expresso
    nohup "./$BUILD_DIR/bin/Launcher" > /tmp/launcher.log 2>&1 < /dev/null &
  fi
fi

echo "[coldbrew-recover] Done"

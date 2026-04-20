#!/bin/bash
# Coldbrew undo — restore a bike from a backup tarball created by unlock.sh.
# Usage: sudo bash undo.sh [/path/to/coldbrew_backup_*.tgz]
# If no path given, uses the most recent backup in /home/expresso/.

set -euo pipefail

BACKUP="${1:-}"
if [ -z "$BACKUP" ]; then
  BACKUP=$(ls -t /home/expresso/coldbrew_backup_*.tgz 2>/dev/null | head -1 || true)
fi

if [ -z "$BACKUP" ] || [ ! -f "$BACKUP" ]; then
  echo "ERROR: no backup found (pass path as argument or create one with unlock.sh)" >&2
  exit 1
fi

echo "[coldbrew-undo] Restoring from $BACKUP"
tar -xzf "$BACKUP" -C /

# Restore inca_requests if a matching SQL backup exists alongside the tarball
SQL_BACKUP="${BACKUP%.tgz}_inca_requests.sql"
if [ -f "$SQL_BACKUP" ]; then
  echo "[coldbrew-undo] Restoring inca_requests from $SQL_BACKUP"
  mysql expresso_station < "$SQL_BACKUP"
else
  echo "[coldbrew-undo] No inca_requests SQL backup found — skipping DB restore"
  echo "  (to restore DB manually: mysqldump expresso_station inca_requests > backup.sql)"
fi

echo "[coldbrew-undo] Restarting game..."
game-restart

echo "[coldbrew-undo] Done — bike should be in original locked state"

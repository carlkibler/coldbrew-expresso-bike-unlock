#!/bin/bash
# Coldbrew fake services.expresso.net — injects login_user responses into
# inca_requests so Inca doesn't need the dead server.
#
# How it works:
#   1. Inca queues login_user requests in dispenser_queue / dispenser_processed.
#   2. With server dead, Dispenser never writes responses to inca_requests.
#   3. This daemon scans for recent login_user session_guids and runs the
#      seed SQL (with placeholder substituted) once per session.
#
# Install:  copy to /usr/local/bin/fake-server.sh (mode 755)
# Run:      launched from rc.local as `fake-server.sh &` at boot

set -u

SEED="/usr/local/expresso/coldbrew/inca_requests_seed.sql"
LOG="/var/log/fake-server.log"
SEEN="/var/run/fake-server.seen"  # cache of session_guids we've already seeded

touch "$SEEN" 2>/dev/null || SEEN=/tmp/fake-server.seen
touch "$SEEN"

log() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $*" >> "$LOG"; }

if [ ! -f "$SEED" ]; then
    log "FATAL: seed SQL missing at $SEED"
    exit 1
fi

MYSQL="mysql -uroot -proot expresso_station -sN"

log "fake-server daemon starting (pid $$)"

while true; do
    # session_guids for recent login_user requests that don't yet have a
    # Coldbrew response in inca_requests.
    SESSIONS=$($MYSQL -e "
        SELECT DISTINCT sg FROM (
            SELECT session_guid AS sg FROM dispenser_queue
                WHERE url LIKE '%login_user%'
                  AND session_guid IS NOT NULL AND session_guid != ''
            UNION
            SELECT session_guid AS sg FROM dispenser_processed
                WHERE url LIKE '%login_user%'
                  AND session_guid IS NOT NULL AND session_guid != ''
                  AND created_at > DATE_SUB(NOW(), INTERVAL 10 MINUTE)
        ) AS s
        WHERE NOT EXISTS (
            SELECT 1 FROM inca_requests r
            WHERE r.session_guid = s.sg
              AND r.data LIKE '%Coldbrew fully unlocked%'
        );
    " 2>/dev/null)

    for SGID in $SESSIONS; do
        # Idempotency: skip if we've handled this session already this boot
        grep -qxF "$SGID" "$SEEN" && continue

        if sed "s/__SESSION_GUID__/$SGID/" "$SEED" | $MYSQL 2>/dev/null; then
            echo "$SGID" >> "$SEEN"
            log "injected login_user response for session $SGID"
        else
            log "INSERT failed for session $SGID"
        fi
    done

    sleep 1
done

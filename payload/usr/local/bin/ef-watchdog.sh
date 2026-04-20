#!/bin/bash
# ef_global.conf watchdog — the game (Launcher/Dispenser/Inca) rewrites this
# file ~40s after rc.local finishes, stomping our BikeSubscription and
# LocationName customizations. This daemon re-applies them whenever the file
# changes (via inotifywait if available, otherwise polling).
#
# Install: /usr/local/bin/ef-watchdog.sh (mode 755)
# Run:     launched from rc.local as `ef-watchdog.sh &` at boot

set -u

CONF=/usr/local/expresso/conf/ef_global.conf
LOG=/var/log/ef-watchdog.log
DESIRED_SUB="BikeSubscription = 1"
DESIRED_LOC='LocationName = Cold Brew - expresso unlocked'
# Cap phone-home waits: services.expresso.net/updates.expresso.net are
# blackholed to 127.0.0.1 in /etc/hosts, so connection attempts fail
# instantly — but any code path that does retry-with-backoff on 10s
# timeout could still stall boot. 1s keeps the fail tight.
DESIRED_TIMEOUT="TimeoutUserLoginSeconds = 1"

log() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $*" >> "$LOG"; }

apply() {
    [ -f "$CONF" ] || return 0

    # Sanity guard: reject mid-write partial files. The game writes atomically
    # but we give it 0.2s before calling apply. A real complete file always
    # has at least SerialNumber and Version (>50 bytes). If smaller, wait.
    local fsize
    fsize=$(wc -c < "$CONF" 2>/dev/null || echo 0)
    if [ "$fsize" -lt 50 ]; then
        log "skipping apply: file too small ($fsize bytes), likely mid-write"
        return 0
    fi

    local changed=0
    # Update existing keys OR append them if missing
    if ! grep -qxF "$DESIRED_SUB" "$CONF"; then
        if grep -q '^BikeSubscription = ' "$CONF"; then
            sed -i "s|^BikeSubscription = .*|$DESIRED_SUB|" "$CONF"
        else
            echo "$DESIRED_SUB" >> "$CONF"
        fi
        changed=1
    fi
    if ! grep -qxF "$DESIRED_TIMEOUT" "$CONF"; then
        if grep -q '^TimeoutUserLoginSeconds = ' "$CONF"; then
            sed -i "s|^TimeoutUserLoginSeconds = .*|$DESIRED_TIMEOUT|" "$CONF"
        else
            echo "$DESIRED_TIMEOUT" >> "$CONF"
        fi
        changed=1
    fi
    if ! grep -qxF "$DESIRED_LOC" "$CONF"; then
        if grep -q '^LocationName = ' "$CONF"; then
            awk -v repl="$DESIRED_LOC" '
                /^LocationName = / { print repl; next }
                { print }
            ' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
        else
            echo "$DESIRED_LOC" >> "$CONF"
        fi
        changed=1
    fi
    [ $changed -eq 1 ] && log "re-applied desired values (file was ${fsize} bytes)"
    return 0
}

log "ef-watchdog starting (pid $$)"

# Initial apply at startup
apply

if command -v inotifywait >/dev/null 2>&1; then
    log "using inotifywait"
    while true; do
        inotifywait -qq -e close_write,modify,moved_to "$CONF" 2>/dev/null
        sleep 0.2  # let game finish writing
        apply
    done
else
    log "inotifywait unavailable, polling every 2s"
    LAST_MTIME=""
    while true; do
        if [ -f "$CONF" ]; then
            MTIME=$(stat -c %Y "$CONF" 2>/dev/null || echo 0)
            if [ "$MTIME" != "$LAST_MTIME" ]; then
                sleep 0.2
                apply
                LAST_MTIME=$MTIME
            fi
        fi
        sleep 2
    done
fi

#!/bin/bash
# Sync scripts and config between this repo and the bike.
# Usage:  ./scripts/bike-sync.sh [push|pull|status] [--live]
#   push    -- copy repo files to the bike (dry run unless --live)
#   pull    -- copy bike files back into the repo
#   status  -- (default) diff local vs bike
#
# Respects BIKE_HOST / BIKE_USER envs — same as xbike.

BIKE_USER="${BIKE_USER:-expresso}"
BIKE_HOST="${BIKE_HOST:-192.168.1.100}"
BIKE="$BIKE_USER@$BIKE_HOST"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
LIVE=false
[[ "$*" == *--live* ]] && LIVE=true

# Files synced into the expresso user's home directory on the bike.
# Local paths are REPO-relative; remote keeps only the basename under ~/.
HOME_FILES=(
    scripts/bike-sleep.sh
    scripts/bike-wake.sh
    scripts/coldbrew-recon.sh
)

# Files synced to absolute system paths on the bike (push requires sudo).
# Parallel arrays: SYSTEM_LOCAL[i] ↔ SYSTEM_REMOTE[i].
# (Bash's assoc-array literal syntax mishandles '/' in keys on some versions.)
SYSTEM_LOCAL=(
    payload/etc/X11/xorg.conf
    payload/home/expresso/script/gnome-startup-custom.sh
)
SYSTEM_REMOTE=(
    /etc/X11/xorg.conf
    /home/expresso/script/gnome-startup-custom.sh
)

cmd="${1:-status}"

push() {
    echo "=== PUSH: repo → bike ==="
    for f in "${HOME_FILES[@]}"; do
        base=$(basename "$f")
        if $LIVE; then
            scp "$REPO/$f" "$BIKE:~/$base" && echo "  pushed $f → ~/$base"
        else
            echo "  [dry] scp $f → ~/$base"
        fi
    done

    for i in "${!SYSTEM_LOCAL[@]}"; do
        local_f="${SYSTEM_LOCAL[$i]}"
        remote_path="${SYSTEM_REMOTE[$i]}"
        base=$(basename "$local_f")
        if $LIVE; then
            scp "$REPO/$local_f" "$BIKE:/tmp/_sync_$base"
            ssh "$BIKE" "sudo cp /tmp/_sync_$base $remote_path && rm /tmp/_sync_$base"
            echo "  pushed $local_f → $remote_path"
        else
            echo "  [dry] scp $local_f → $remote_path (via sudo)"
        fi
    done

    # Sync aliases into .bashrc (match both legacy 'VeloRoot' and current 'Coldbrew' block markers)
    if $LIVE; then
        scp "$REPO/scripts/bike-aliases.sh" "$BIKE:/tmp/_aliases.sh"
        ssh "$BIKE" "
            python -c \"
import re
content = open('/home/expresso/.bashrc').read()
block = open('/tmp/_aliases.sh').read()
content = re.sub(r'# (VeloRoot|Coldbrew).*?(?=\n[^#\n]|\Z)', '', content, flags=re.DOTALL).rstrip()
content = content + '\n\n' + block.strip() + '\n'
open('/home/expresso/.bashrc', 'w').write(content)
\"
            rm /tmp/_aliases.sh
        "
        echo "  pushed aliases → ~/.bashrc"
    else
        echo "  [dry] scripts/bike-aliases.sh → ~/.bashrc (merged)"
    fi

    $LIVE || echo "(dry run — use --live to apply)"
}

pull() {
    echo "=== PULL: bike → repo ==="
    for f in "${HOME_FILES[@]}"; do
        base=$(basename "$f")
        scp "$BIKE:~/$base" "$REPO/$f" 2>/dev/null && echo "  pulled ~/$base → $f" || echo "  MISSING on bike: ~/$base"
    done

    for i in "${!SYSTEM_LOCAL[@]}"; do
        local_f="${SYSTEM_LOCAL[$i]}"
        remote_path="${SYSTEM_REMOTE[$i]}"
        scp "$BIKE:$remote_path" "$REPO/$local_f" 2>/dev/null && echo "  pulled $remote_path → $local_f" || echo "  MISSING on bike: $remote_path"
    done
}

status() {
    echo "=== STATUS: local vs bike ==="
    for f in "${HOME_FILES[@]}"; do
        base=$(basename "$f")
        remote=$(ssh "$BIKE" "cat ~/$base 2>/dev/null" 2>/dev/null)
        local_content=$(cat "$REPO/$f" 2>/dev/null)
        if [[ "$remote" == "$local_content" ]]; then
            echo "  OK   $f"
        elif [[ -z "$remote" ]]; then
            echo "  MISSING ON BIKE  $f"
        else
            echo "  DIFF $f"
            diff <(echo "$local_content") <(echo "$remote") | head -8 | sed 's/^/    /'
        fi
    done

    for i in "${!SYSTEM_LOCAL[@]}"; do
        local_f="${SYSTEM_LOCAL[$i]}"
        remote_path="${SYSTEM_REMOTE[$i]}"
        remote=$(ssh "$BIKE" "cat $remote_path 2>/dev/null" 2>/dev/null)
        local_content=$(cat "$REPO/$local_f" 2>/dev/null)
        if [[ "$remote" == "$local_content" ]]; then
            echo "  OK   $local_f ($remote_path)"
        else
            echo "  DIFF $local_f ($remote_path)"
            diff <(echo "$local_content") <(echo "$remote") | head -8 | sed 's/^/    /'
        fi
    done
}

case "$cmd" in
    push)   push ;;
    pull)   pull ;;
    status) status ;;
    *)      echo "Usage: $0 [push|pull|status] [--live]"; exit 1 ;;
esac

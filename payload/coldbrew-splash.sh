#!/bin/sh
# Coldbrew boot splash — shows ONE image per boot, round-robin through the
# set so each reboot reveals a different one. Fills the 30-60s black gap
# between plymouth exit and Inca's game window appearing.
#
# Ubuntu 12.04 has no python3/pygame; feh is already installed.
# Exits when xdotool finds Inca's X window, or after MAX_SECONDS as a cap.

set -u

SPLASH_DIR=/usr/local/expresso/coldbrew
IDX_FILE="$SPLASH_DIR/.last-idx"
LOG=/tmp/coldbrew-splash.log
MAX_SECONDS=300

echo "[$(date +%H:%M:%S)] splash start (pid $$)" >> "$LOG"

cd "$SPLASH_DIR" 2>/dev/null || { echo "no splash dir" >> "$LOG"; exit 1; }

# Collect images into a positional list (sh-portable, no arrays).
set -- [0-9fF]*.jpg
if [ "$1" = "[0-9fF]*.jpg" ] || [ $# -eq 0 ]; then
    echo "no splash images found" >> "$LOG"
    exit 1
fi
COUNT=$#

# Round-robin index: read last, advance, wrap, persist. Falls back to 0 on
# missing/garbage file. Written before show so a crash still advances.
LAST=$(cat "$IDX_FILE" 2>/dev/null)
case "$LAST" in
    ''|*[!0-9]*) LAST=-1 ;;
esac
NEXT=$(( (LAST + 1) % COUNT ))
echo "$NEXT" > "$IDX_FILE" 2>/dev/null

# Shift to the Nth arg (positional params are 1-indexed).
i=0
while [ $i -lt $NEXT ]; do shift; i=$((i+1)); done
IMG="$1"

echo "[$(date +%H:%M:%S)] showing $IMG (idx $NEXT of $COUNT)" >> "$LOG"

# Clean up any orphaned feh from a prior run. Critical: if we ever leave feh
# running, it stays ON TOP of the game window and user sees endless image.
pkill -9 -x feh 2>/dev/null
sleep 0.5

# --fullscreen + --auto-zoom + --scale-down: aspect-correct fit. Single image,
# no slideshow flags — feh holds the one image until we kill it.
feh \
    --fullscreen \
    --hide-pointer \
    --auto-zoom \
    --scale-down \
    --quiet \
    "$IMG" \
    >> "$LOG" 2>&1 &
FEH_PID=$!

echo "[$(date +%H:%M:%S)] feh pid $FEH_PID, waiting for Inca" >> "$LOG"

# Belt-and-suspenders cleanup: kill by pid AND by name on exit, regardless
# of how we exit (normal, signal, cap reached).
cleanup() {
    kill "$FEH_PID" 2>/dev/null
    pkill -9 -x feh 2>/dev/null
    wait "$FEH_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

# Poll for Inca's X window; kill feh when it appears or at cap.
i=0
while [ $i -lt $MAX_SECONDS ]; do
    if ! kill -0 "$FEH_PID" 2>/dev/null; then
        echo "[$(date +%H:%M:%S)] feh exited on its own" >> "$LOG"
        exit 0
    fi
    # Inca's X window has no title; match by WM_CLASS instead.
    # Do NOT use --onlyvisible: feh is fullscreen in front of Inca, so Inca's
    # window would never pass the visibility check and the cap always fires.
    if xdotool search --class Inca >/dev/null 2>&1; then
        echo "[$(date +%H:%M:%S)] Inca window detected at ${i}s, closing splash" >> "$LOG"
        exit 0
    fi
    sleep 1
    i=$((i+1))
done

echo "[$(date +%H:%M:%S)] cap reached at ${MAX_SECONDS}s, closing splash" >> "$LOG"
exit 0

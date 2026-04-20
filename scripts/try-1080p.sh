#!/bin/bash
# Attempt to set X to 1920x1080@60 via a custom modeline — safely.
# Run from xterm (keyboard attached) OR via ssh with DISPLAY=:0.
# The script auto-reverts to the previous mode after 15s unless you type
# 'keep' on stdin, so a bad signal cannot brick the display across reboots.
set -e

export DISPLAY="${DISPLAY:-:0}"
OUT="$(xrandr | awk '/ connected/{print $1; exit}')"
[[ -n "$OUT" ]] || { echo "no connected X output"; exit 1; }
PREV_MODE="$(xrandr | awk "/^   .*\\*/{print \$1; exit}")"
[[ -n "$PREV_MODE" ]] || PREV_MODE="1440x900"

MODE_NAME="1920x1080_60.00"
# CVT-reduced-blanking timings for 1920x1080@60Hz
MODELINE=(138.50 1920 1968 2000 2080 1080 1083 1088 1111 +hsync -vsync)

# Add mode if missing
xrandr --newmode "$MODE_NAME" "${MODELINE[@]}" 2>/dev/null || true
xrandr --addmode "$OUT" "$MODE_NAME" 2>/dev/null || true

echo "Output: $OUT  prev: $PREV_MODE  trying: $MODE_NAME"
echo "If the monitor stays dark / 'invalid input', DO NOTHING — reverting in 15s."

revert() {
    echo; echo "Reverting to $PREV_MODE"
    xrandr --output "$OUT" --mode "$PREV_MODE" || true
    xrandr --delmode "$OUT" "$MODE_NAME" 2>/dev/null || true
    xrandr --rmmode  "$MODE_NAME"        2>/dev/null || true
}
trap revert EXIT INT TERM

xrandr --output "$OUT" --mode "$MODE_NAME" || {
    echo "xrandr refused the mode."; exit 1; }

echo "Type 'keep' within 15s to persist this session; anything else reverts."
if read -t 15 -r ans && [[ "$ans" == "keep" ]]; then
    trap - EXIT INT TERM
    echo "Kept. (Not persistent across reboot. To persist, bake modeline into /etc/X11/xorg.conf.)"
else
    :
fi

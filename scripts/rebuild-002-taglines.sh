#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FONT='/System/Library/Fonts/Helvetica.ttc'
POINTSIZE=54
PANEL_FILL='rgba(4,10,24,1.0)'
PANEL_DRAW='roundrectangle 90,540 1254,756 42,42'

render() {
  local input="$1"
  local output="$2"
  local text="$3"

  magick "$input" \
    \( -size 1344x768 xc:none -fill "$PANEL_FILL" -draw "$PANEL_DRAW" -blur 0x16 \) \
    -compose over -composite \
    -font "$FONT" -gravity south -fill '#000814' -pointsize "$POINTSIZE" -interline-spacing -12 -annotate +0+44 "$text" \
    -font "$FONT" -gravity south -fill '#2C0242' -pointsize "$POINTSIZE" -interline-spacing -12 -annotate +0+46 "$text" \
    -font "$FONT" -gravity south -fill '#2CEBFF' -pointsize "$POINTSIZE" -interline-spacing -12 -annotate +0+45 "$text" \
    "$output"
}

mkdir -p "$ROOT/results/splash"

render \
  "$ROOT/payload/coldbrew/002-tagline-1-brewed-without-permission.jpg" \
  "$ROOT/payload/coldbrew/002-tagline-1-brewed-without-permission.jpg" \
  'Brewed without
permission.'
cp "$ROOT/payload/coldbrew/002-tagline-1-brewed-without-permission.jpg" \
   "$ROOT/results/splash/002-tagline-1-brewed-without-permission.jpg"

render \
  "$ROOT/payload/coldbrew/002-tagline-2-your-subscription-expired.jpg" \
  "$ROOT/payload/coldbrew/002-tagline-2-your-subscription-expired.jpg" \
  "Your subscription expired.
Your bike didn't."
cp "$ROOT/payload/coldbrew/002-tagline-2-your-subscription-expired.jpg" \
   "$ROOT/results/splash/002-tagline-2-your-subscription-expired.jpg"

render \
  "$ROOT/payload/coldbrew/002-tagline-3-the-server-is-dead.jpg" \
  "$ROOT/payload/coldbrew/002-tagline-3-the-server-is-dead.jpg" \
  'The server is dead.
The ride lives on.'
cp "$ROOT/payload/coldbrew/002-tagline-3-the-server-is-dead.jpg" \
   "$ROOT/results/splash/002-tagline-3-the-server-is-dead.jpg"

printf 'rebuilt 3 tagline images\n'

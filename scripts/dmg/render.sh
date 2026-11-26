#!/bin/bash
# Renders the DMG window's background at 1x and 2x into one TIFF: scripts/dmg/render.sh out.tiff
set -euo pipefail
OUT="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for SCALE in 1 2; do
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=$SCALE \
    --window-size=660,400 --screenshot="$WORK/bg-$SCALE.png" "file://$HERE/background.html" >/dev/null 2>&1
done
tiffutil -cathidpicheck "$WORK/bg-1.png" "$WORK/bg-2.png" -out "$OUT" >/dev/null
rm -rf "$WORK"

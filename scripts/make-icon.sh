#!/bin/bash
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns.
# Needs Google Chrome (to render the SVG faithfully) and ImageMagick.
set -euo pipefail
cd "$(dirname "$0")/.."
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --default-background-color=00000000 --window-size=1024,1024 \
  --screenshot="$work/icon_1024.png" "file://$PWD/Resources/AppIcon.svg" 2>/dev/null

mkdir "$work/AppIcon.iconset"
for size in 16 32 128 256 512; do
  magick "$work/icon_1024.png" -filter Lanczos -resize ${size}x${size} "$work/AppIcon.iconset/icon_${size}x${size}.png"
  magick "$work/icon_1024.png" -filter Lanczos -resize $((size * 2))x$((size * 2)) "$work/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$work/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"

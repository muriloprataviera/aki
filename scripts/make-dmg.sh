#!/bin/bash
# The installer people download: a disk with Aki on the left and Applications on
# the right ("drag Aki to Applications"), Aki's icon on the disk, a tidy window.
#   scripts/make-dmg.sh dist/Aki.app out/Aki-0.2.0.dmg "Aki 0.2.0"
set -euo pipefail
app=${1:?usage: scripts/make-dmg.sh <Aki.app> <out.dmg> [volume name]}
out=${2:?}
name=${3:-Aki}
work=$(mktemp -d)
trap 'hdiutil detach "/Volumes/$name" -quiet 2>/dev/null || true; rm -rf "$work"' EXIT

src=$work/src
mkdir "$src"
ditto "$app" "$src/Aki.app"
ln -s /Applications "$src/Applications"
cp "$(dirname "$0")/../Resources/AppIcon.icns" "$src/.VolumeIcon.icns"

# A writable disk to arrange, then the compressed one.
hdiutil create -quiet -volname "$name" -srcfolder "$src" -ov -format UDRW "$work/rw.dmg"
hdiutil attach -quiet -noautoopen "$work/rw.dmg"
# The disk shows its own icon (if SetFile is around).
command -v SetFile >/dev/null && SetFile -a C "/Volumes/$name" 2>/dev/null || true
osascript >/dev/null 2>&1 <<OSA || true
tell application "Finder"
  tell disk "$name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 460}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set position of item "Aki.app" of container window to {140, 160}
    set position of item "Applications" of container window to {400, 160}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
# macOS's own bookkeeping folder would show up in the window.
rm -rf "/Volumes/$name/.fseventsd" "/Volumes/$name/.Trashes"
sync
hdiutil detach "/Volumes/$name" -quiet
rm -f "$out"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -o "$out"
echo "$out"

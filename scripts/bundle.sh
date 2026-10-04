#!/bin/bash
# Builds dist/Aki.app (release). Usage: scripts/bundle.sh [debug]
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-release}
# Quiet when it works; the whole build log when it doesn't.
log=$(mktemp)
if ! swift build -c "$config" --product aki >"$log" 2>&1; then cat "$log" >&2; rm -f "$log"; exit 1; fi
rm -f "$log"
bin=$(swift build -c "$config" --show-bin-path)
version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/AkiCore/AkiHome.swift)

app=dist/Aki.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/aki" "$app/Contents/MacOS/Aki"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp Resources/Logotype.png "$app/Contents/Resources/"
# The license and the notices of the code adapted from other projects travel with the app.
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES "$app/Contents/Resources/THIRD_PARTY_NOTICES.txt"
sed "s/__VERSION__/$version/g" Resources/Info.plist > "$app/Contents/Info.plist"

# Sparkle, for in-app updates: the framework goes in Contents/Frameworks (the
# binary finds it there), without the XPC services a non-sandboxed app doesn't use.
sparkle=$(find .build/artifacts/sparkle -path "*macos*/Sparkle.framework" -maxdepth 6 | head -1)
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Aki" 2>/dev/null || true

# A stable local identity ("Aki Dev", from scripts/dev-cert.sh) keeps macOS
# permissions such as Screen Recording across builds; ad-hoc would re-ask each time.
# Every release is signed with this same identity, so macOS keeps the permissions
# (Screen Recording, Accessibility) across updates. Inside out: Sparkle's helpers,
# the framework, then the app.
identity="-"
if security find-certificate -c "Aki Dev" >/dev/null 2>&1; then
  identity="Aki Dev"
else
  echo "warning: no \"Aki Dev\" identity (run scripts/dev-cert.sh); signing ad-hoc" >&2
fi
fw="$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$identity" "$fw/Versions/B/Autoupdate" >/dev/null 2>&1
codesign --force --sign "$identity" "$fw/Versions/B/Updater.app" >/dev/null 2>&1
codesign --force --sign "$identity" "$fw" >/dev/null 2>&1
codesign --force --sign "$identity" "$app" >/dev/null 2>&1
echo "$app ($version, $config)"

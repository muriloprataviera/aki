#!/bin/bash
# Builds dist/releases/<version>/feed/appcast.xml: the published feed (updates/appcast.xml,
# in git) plus this version, with its notes (feed/Aki-<v>.html) and signed with the key
# in this Mac's Keychain. Only the new item gets this release's download address.
#   scripts/appcast.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?usage: scripts/appcast.sh <version>}
feed=dist/releases/$version/feed
[ -f "$feed/Aki-$version.zip" ] || { echo "no $feed/Aki-$version.zip (run scripts/release.sh first)" >&2; exit 1; }
channel=""; [[ "$version" == *-beta.* ]] && channel="beta"
rm -f "$feed/appcast.xml"
[ -f updates/appcast.xml ] && cp updates/appcast.xml "$feed/appcast.xml"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --account ai.useaki.Aki \
  --download-url-prefix "https://aki-updates.vercel.app/$version/" \
  --embed-release-notes ${channel:+--channel "$channel"} "$feed"
echo "$feed/appcast.xml"

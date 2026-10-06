#!/bin/bash
# Puts aki-updates.vercel.app online as this Mac has it: every version's files, the feed,
# the installer and api/dl.js (downloads, notices). Run by publish.sh after a release, and
# alone when only the host changed (its function, its headers) — no new version needed.
set -euo pipefail
cd "$(dirname "$0")/.."
# The download host: every version this Mac still has, plus the feed.
host=dist/aki-updates
rm -rf "$host"; mkdir -p "$host"
for dir in dist/releases/*/; do
  v=$(basename "$dir")
  [ -f "$dir/feed/Aki-$v.zip" ] || continue
  mkdir -p "$host/$v"
  cp "$dir/feed/Aki-$v.zip" "$host/$v/"
  [ -f "$dir/Aki-$v.dmg" ] && cp "$dir/Aki-$v.dmg" "$host/$v/"
done
# Versions the feed (or the installer) still points at but this Mac no longer
# has: fetched back from their GitHub Release, so no download ever disappears.
for v in $( { grep -o 'aki-updates.vercel.app/[0-9][^/"]*/' updates/appcast.xml | cut -d/ -f2; cat updates/latest.txt 2>/dev/null; } | sort -u); do
  [ -f "$host/$v/Aki-$v.zip" ] && continue
  mkdir -p "$host/$v"
  gh release download "v$v" --repo muriloprataviera/aki --dir "$host/$v" --pattern "Aki-$v.*" \
    || echo "warning: couldn't fetch v$v from GitHub; its download will be missing" >&2
done
cp updates/appcast.xml "$host/appcast.xml"
# One-line install: curl -fsSL https://aki-updates.vercel.app/aki-install.sh | sh
# (/install and /install.sh stay as older names). The script and /Aki.dmg go through
# api/dl.js, which tells the maker on Telegram that someone downloaded (no IP), then serves the file.
mkdir -p "$host/script" && cp scripts/get-aki.sh "$host/script/aki-install.sh"
cp -R updates/api "$host/api"
[ -f updates/latest.txt ] && cp updates/latest.txt "$host/latest.txt"
# How the host serves things: /Aki.dmg and the installer go through api/dl.js (newest stable
# DMG; installer as text, named aki-install.sh if saved), the bare address goes to the site,
# and any page may read the feed and latest.txt (public data).
latest=$(cat updates/latest.txt 2>/dev/null || echo "$(cat updates/latest.txt)")
cat > "$host/vercel.json" <<JSON
{
  "redirects": [
    { "source": "/", "destination": "https://useaki.vercel.app/", "permanent": false }
  ],
  "rewrites": [
    { "source": "/Aki.dmg", "destination": "/api/dl?kind=dmg" },
    { "source": "/(aki-install.sh|install|install.sh)", "destination": "/api/dl?kind=script" },
    { "source": "/eu", "destination": "/api/dl?kind=me" },
    { "source": "/ping", "destination": "/api/dl?kind=ping" }
  ],
  "functions": { "api/dl.js": { "includeFiles": "{script/aki-install.sh,latest.txt,appcast.xml}" } },
  "headers": [
    { "source": "/(.*)", "headers": [
      { "key": "X-Content-Type-Options", "value": "nosniff" },
      { "key": "X-Frame-Options", "value": "DENY" },
      { "key": "Referrer-Policy", "value": "no-referrer" },
      { "key": "Permissions-Policy", "value": "camera=(), microphone=(), geolocation=()" }
    ] },
    { "source": "/(appcast.xml|latest.txt)", "headers": [
      { "key": "Access-Control-Allow-Origin", "value": "*" },
      { "key": "Cache-Control", "value": "public, max-age=300" }
    ] },
    { "source": "/(.*)/Aki-(.*)", "headers": [
      { "key": "Cache-Control", "value": "public, max-age=31536000, immutable" }
    ] }
  ]
}
JSON
(cd "$host" && vercel deploy --prod --yes --scope murilo-2977s-projects >/dev/null)

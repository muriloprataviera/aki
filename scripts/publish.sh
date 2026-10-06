#!/bin/bash
# Publishes a release prepared by scripts/release.sh — this is what makes every Aki
# see the update. Run only after Murilo's OK for this version.
#   scripts/publish.sh 0.2.0
# 1. the feed again (so notes tidied since release.sh go in);
# 2. commits + tag to GitHub (muriloprataviera/aki, private) and a GitHub Release
#    there with the files, as the record (pre-release for betas);
# 3. the files people download, on aki-updates.vercel.app (a private repo can't
#    serve downloads): <version>/Aki-<v>.zip, <version>/Aki-<v>.dmg, appcast.xml.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?usage: scripts/publish.sh <version>}
out=dist/releases/$version
[ -f "$out/feed/Aki-$version.zip" ] || { echo "run scripts/release.sh $version first" >&2; exit 1; }
pre=""; [[ "$version" == *-beta.* ]] && pre="--prerelease"

scripts/appcast.sh "$version" >/dev/null

# The feed history lives in git (updates/appcast.xml).
mkdir -p updates
cp "$out/feed/appcast.xml" updates/appcast.xml
# The version the one-line installer gets: the newest stable one.
[ -z "$pre" ] && echo "$version" > updates/latest.txt
git add updates/appcast.xml $( [ -f updates/latest.txt ] && echo updates/latest.txt )
git commit -q -m "appcast: v$version"
git push origin HEAD --follow-tags
gh release create "v$version" "$out/feed/Aki-$version.zip" "$out/Aki-$version.dmg" \
  --repo muriloprataviera/aki --title "Aki $version" --notes-file "$out/feed/Aki-$version.html" $pre

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
latest=$(cat updates/latest.txt 2>/dev/null || echo "$version")
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
  "functions": { "api/dl.js": { "includeFiles": "{script/aki-install.sh,latest.txt}" } },
  "headers": [
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
curl -fsS https://aki-updates.vercel.app/appcast.xml | grep -q "$version" \
  && echo "Aki $version is out — every Aki will see it within a day (or now, via Check for Updates)." \
  || echo "warning: the feed online doesn't show $version yet" >&2

#!/bin/bash
# Prepares a release on this Mac — nothing leaves it.
#
#   scripts/release.sh 0.2.0          a stable version, for everyone
#   scripts/release.sh 0.2.0-beta.1   a beta, only for those who turned betas on
#
# It writes the version into the app, commits and tags it, builds and signs
# dist/Aki.app (same "Aki Dev" identity as always, so permissions survive), and
# leaves in dist/releases/:
#   <v>/Aki-<v>.dmg         what the site offers for a first install
#   <v>/feed/Aki-<v>.zip    what Sparkle downloads to update
#   <v>/feed/Aki-<v>.html   the release notes (from the commits since the last tag)
#   <v>/feed/appcast.xml    the feed every Aki reads, signed with Aki's update key
# Publishing them (GitHub Release + appcast on the site) is scripts/publish.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: scripts/release.sh <version>   e.g. 0.2.0 or 0.2.0-beta.1}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]] || { echo "version must look like 0.2.0 or 0.2.0-beta.1" >&2; exit 1; }
channel=""; [[ "$version" == *-beta.* ]] && channel="beta"

[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first" >&2; exit 1; }
git rev-parse "v$version" >/dev/null 2>&1 && { echo "v$version already exists" >&2; exit 1; }

current=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/AkiCore/AkiHome.swift)
# Newer by semver: a beta comes before its stable (0.2.0-beta.1 < 0.2.0).
newer() {  # newer A B: A > B
  local a=${1%%-*} b=${2%%-*} pa= pb=
  [[ $1 == *-* ]] && pa=${1#*-}; [[ $2 == *-* ]] && pb=${2#*-}
  if [ "$a" != "$b" ]; then [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]; return; fi
  [ -z "$pa" ] && [ -n "$pb" ] && return 0
  [ -n "$pa" ] && [ -z "$pb" ] && return 1
  [ -n "$pa" ] && [ "$pa" != "$pb" ] && [ "$(printf '%s\n%s\n' "$pa" "$pb" | sort -V | tail -1)" = "$pa" ]
}
newer "$version" "$current" || { echo "$version must be newer than $current" >&2; exit 1; }

# Release notes: the commits since the last version, as a list (edit the .html before publishing).
last=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
range=${last:+$last..}HEAD

# 1. The version, into the app; commit and tag.
sed -i '' "s/static let version = \".*\"/static let version = \"$version\"/" Sources/AkiCore/AkiHome.swift
git add Sources/AkiCore/AkiHome.swift
git commit -q -m "release: v$version"
git tag -a "v$version" -m "Aki $version"

# 2. Build and sign.
scripts/bundle.sh release

# 3. The files, in a folder of their own (dist/releases/<version>/). The feed is
# built in feed/ with the .zip only (Sparkle won't take two archives of one version).
out=dist/releases/$version
mkdir -p "$out/feed"
ditto -c -k --sequesterRsrc --keepParent dist/Aki.app "$out/feed/Aki-$version.zip"
scripts/make-dmg.sh dist/Aki.app "$out/Aki-$version.dmg" "Aki $version" >/dev/null
{
  echo "<h2>Aki $version</h2><ul>"
  git log --no-merges --pretty='<li>%s</li>' "$range" | grep -v 'release: v' | sed -E 's/<li>(feat|fix|perf|chore|docs)(\([^)]*\))?: /<li>/'
  echo "</ul>"
} > "$out/feed/Aki-$version.html"

# 4. The feed.
scripts/appcast.sh "$version" >/dev/null

echo
echo "Aki $version ready in $out ($( [ -n "$channel" ] && echo beta || echo stable ))."
echo "Tidy the notes in $out/feed/Aki-$version.html if you like, then publish: scripts/publish.sh $version"

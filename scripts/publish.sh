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

# A stable release supersedes the betas up to it: their GitHub Releases go (the tags
# stay, so the history keeps every beta). Betas of a newer version stay listed, and so
# does any beta the feed still offers (deploy-host.sh fetches its files back from there).
if [ -z "$pre" ]; then
  gh release list --repo muriloprataviera/aki --limit 500 --json tagName,isPrerelease \
    -q '.[] | select(.isPrerelease) | .tagName' |
  while read -r tag; do
    base=${tag#v}; base=${base%%-*}
    if [ "$(printf '%s\n%s\n' "$base" "$version" | sort -V | tail -1)" = "$version" ] \
      && ! grep -q "aki-updates.vercel.app/${tag#v}/" updates/appcast.xml; then
      if gh release delete "$tag" --repo muriloprataviera/aki --yes >/dev/null; then
        echo "removed the $tag release (tag kept)"
      fi
    fi
  done
fi

scripts/deploy-host.sh
curl -fsS https://aki-updates.vercel.app/appcast.xml | grep -q "$version" \
  && echo "Aki $version is out — every Aki will see it within a day (or now, via Check for Updates)." \
  || echo "warning: the feed online doesn't show $version yet" >&2

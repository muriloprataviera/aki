#!/bin/sh
# Installs (or updates) Aki in one line:
#   curl -fsSL https://aki-updates.vercel.app/aki-install.sh | sh
# Downloads the latest stable version, puts it in /Applications and opens it.
# Published by scripts/publish.sh next to the downloads.
set -eu

HOST=https://aki-updates.vercel.app
# SHA-256 of Aki's own signing certificate ("Aki Dev"): only an app signed with
# it is installed. Public (it identifies the certificate, it isn't a secret).
CERT_SHA256=afbdc5bfa7c130db701612a5e6199c359606745f54afc75f22864c1a74087a0b

say() { printf '\033[1;31m●\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "Aki is a Mac app."
[ "$(uname -m)" = arm64 ] || fail "Aki needs an Apple Silicon Mac for now."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Aki needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

version=$(curl -fsSL "$HOST/latest.txt" | tr -d '[:space:]')
[ -n "$version" ] || fail "Couldn't find the latest version. Try again in a moment."
say "Aki $version"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fL --progress-bar "$HOST/$version/Aki-$version.zip" -o "$tmp/Aki.zip" || fail "Download failed."
ditto -x -k "$tmp/Aki.zip" "$tmp" || fail "Couldn't unpack the download."
[ -d "$tmp/Aki.app" ] || fail "The download doesn't hold Aki.app."
# Signed, intact, and Aki's own identity: anything else is refused.
codesign --verify --deep --strict "$tmp/Aki.app" 2>/dev/null || fail "The download isn't intact (its signature doesn't check out). Nothing was installed."
codesign -dv "$tmp/Aki.app" 2>&1 | grep -q '^Identifier=ai.useaki.Aki$' || fail "The download isn't Aki. Nothing was installed."
mkdir "$tmp/cert"
(cd "$tmp/cert" && codesign -d --extract-certificates "$tmp/Aki.app" >/dev/null 2>&1)
[ "$(shasum -a 256 "$tmp/cert/codesign0" 2>/dev/null | cut -d' ' -f1)" = "$CERT_SHA256" ] \
  || fail "The download isn't signed by Aki. Nothing was installed."

# An Aki that's running is closed first, then replaced.
if pgrep -x Aki >/dev/null 2>&1; then
  say "Closing the Aki that's open"
  osascript -e 'tell application id "ai.useaki.Aki" to quit' >/dev/null 2>&1 || pkill -x Aki || true
  sleep 1
fi
target=/Applications/Aki.app
if [ -w /Applications ]; then
  rm -rf "$target" && ditto "$tmp/Aki.app" "$target"
else
  say "Your password puts Aki in /Applications"
  sudo rm -rf "$target" && sudo ditto "$tmp/Aki.app" "$target"
fi
# Downloaded by this script you just ran: no "app from the internet" prompt.
xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

say "Opening Aki — it shows its first steps (two permissions, one click each)."
open "$target"

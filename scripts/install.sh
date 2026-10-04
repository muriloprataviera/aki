#!/bin/zsh
# Builds Aki, puts it in /Applications (where Spotlight and Raycast find it) and opens it.
set -e
cd "$(dirname "$0")/.."
scripts/bundle.sh
pkill -x Aki 2>/dev/null || true
ditto dist/Aki.app /Applications/Aki.app
open /Applications/Aki.app
echo "/Applications/Aki.app"

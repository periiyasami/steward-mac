#!/bin/zsh
# Refreshes the README screenshots in screenshots/ from sample data.
# Needs a current build: run ./build.sh first.
# Usage: tools/readme-shots.sh
set -euo pipefail
here=${0:A:h}
repo=${here:h}
pages=(status scan-results review diskMap duplicates uninstaller loginItems browserData)
APP_SNAPSHOT_PAGES=${(j:,:)pages} "$here/snap.sh"
mkdir -p "$repo/screenshots"
for p in $pages; do
  for mode in light dark; do
    cp "/tmp/Steward-shots/$p-$mode.png" "$repo/screenshots/$p-$mode.png"
  done
done
echo "updated $repo/screenshots ($(ls "$repo/screenshots" | wc -l | tr -d ' ') files)"

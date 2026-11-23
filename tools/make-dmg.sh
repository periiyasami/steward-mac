#!/bin/zsh
# Builds a release of Steward and packs it into dist/Steward-<version>.dmg
# with an Applications shortcut, ready to share.
# Usage: tools/make-dmg.sh              ad-hoc signed (no personal certificate inside)
#        SIGN_IDENTITY="Developer ID Application: …" tools/make-dmg.sh   for a notarizable build
set -euo pipefail
here=${0:A:h}
repo=${here:h}
cd "$repo"
export SIGN_IDENTITY="${SIGN_IDENTITY:--}"
./build.sh
app=~/Applications/Steward.app
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
mkdir -p dist
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Steward.app"
ln -s /Applications "$stage/Applications"
out="dist/Steward-$version.dmg"
rm -f "$out"
hdiutil create -volname "Steward $version" -srcfolder "$stage" -ov -format UDZO -fs APFS "$out" >/dev/null
codesign --verify --deep --strict "$stage/Steward.app" && echo "signature ok ($SIGN_IDENTITY)"
hdiutil verify "$out" >/dev/null && echo "dmg ok"
echo "wrote $repo/$out ($(du -h "$out" | cut -f1))"

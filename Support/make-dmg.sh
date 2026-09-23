#!/bin/sh
# Packs an app into a compressed disk image with an Applications shortcut,
# so installing is a single drag.
#
#   Support/make-dmg.sh dist/Parallex.app dist/Parallex.dmg
set -eu

app="$1"
output="$2"
name="$(basename "$app" .app)"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

ditto "$app" "$staging/$name.app"
ln -s /Applications "$staging/Applications"
rm -f "$output"
hdiutil create -quiet -volname "$name" -srcfolder "$staging" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$output"

#!/bin/sh
# Generate Metadata.appintents for Parallex.app, so Shortcuts and Focus find
# its actions. Xcode does this as a build step; SwiftPM compiles the intents
# (and extracts their constant values) but leaves this step out, so it runs
# Xcode's processor here.
#
#   Support/make-intents-metadata.sh <Parallex.app> <release products dir>
set -eu
app="$1"
products="$2"
skip() { echo "warning: $1; Shortcuts actions left out" >&2; exit 0; }
# The release build's own objects: .build/out/Products/Release →
# .build/out/Intermediates.noindex/parallex.build/Release/…
objects="$(dirname "$(dirname "$products")")/Intermediates.noindex/parallex.build/Release/ParallexApp-p.build/Objects-normal/arm64"
ls "$objects"/*.swiftconstvalues >/dev/null 2>&1 || skip "no App Intents constant values in $objects"
# Only Xcode has the processor (the command line tools don't).
xcrun --find appintentsmetadataprocessor >/dev/null 2>&1 || skip "Xcode's appintentsmetadataprocessor isn't installed"
xcode_version=$(xcodebuild -version 2>/dev/null | awk '/Build version/ {print $3}')
[ -n "$xcode_version" ] || skip "no Xcode version (is full Xcode selected?)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
find "$PWD/Sources/ParallexApp" -name '*.swift' > "$work/sources.txt"
ls "$objects"/*.swiftconstvalues > "$work/constvalues.txt"
toolchain=$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")
xcrun appintentsmetadataprocessor \
    --output "$work/out" \
    --toolchain-dir "$toolchain" \
    --module-name ParallexApp \
    --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$xcode_version" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple arm64-apple-macos14.0 \
    --source-file-list "$work/sources.txt" \
    --swift-const-vals-list "$work/constvalues.txt" \
    --quiet-warnings 2>&1 | grep -v "^20[0-9-]* [0-9:.]* appintentsmetadataprocessor" || true
[ -d "$work/out/Metadata.appintents" ] || { echo "error: App Intents metadata wasn't generated" >&2; exit 1; }
rm -rf "$app/Contents/Resources/Metadata.appintents"
cp -R "$work/out/Metadata.appintents" "$app/Contents/Resources/Metadata.appintents"
echo "App Intents metadata: $(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(', '.join(sorted(d['actions'])))" "$app/Contents/Resources/Metadata.appintents/extract.actionsdata")"

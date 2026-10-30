#!/bin/bash
# Writes Metadata.appintents into the app bundle so Shortcuts and Spotlight can see
# Loopbacker's App Intents (mute, effects presets, scenes). Xcode runs
# appintentsmetadataprocessor as a build phase; SwiftPM doesn't, so without this step the
# intents compile into the binary but the system never lists them.
#
# Usage: extract-app-intents.sh <app_bundle>
# Run after `swift build -c release` and before codesigning the bundle. It needs the Swift
# compiler's const-values output for the Loopbacker module: the swiftbuild build system writes
# it on its own (found under .build); with the native build system (what CI's Xcode uses),
# build with
#   -Xswiftc -emit-const-values-path -Xswiftc <path>
#   -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
#   -Xswiftc -Xfrontend -Xswiftc scripts/app-intents-const-protocols.json
# and pass <path> in LB_CONST_VALUES.
set -euo pipefail

APP_BUNDLE="${1:?usage: extract-app-intents.sh <app_bundle>}"
PACKAGE_DIR="$(cd "$(dirname "$0")/../App/Loopbacker" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CONST_VALUES="${LB_CONST_VALUES:-}"
if [ -z "$CONST_VALUES" ]; then
    CONST_VALUES="$(find "$PACKAGE_DIR/.build" -name 'Loopbacker-primary.swiftconstvalues' -ipath '*release*' \
        -not -path '*testable*' -print -quit)"
fi
if [ -z "$CONST_VALUES" ] || [ ! -f "$CONST_VALUES" ]; then
    echo "error: no const values for the Loopbacker module (see this script's header); Shortcuts would not list Loopbacker's actions" >&2
    exit 1
fi
echo "$CONST_VALUES" > "$WORK/consts.txt"
find "$PACKAGE_DIR/Sources" -name '*.swift' > "$WORK/sources.txt"

SWIFT="$(xcrun --find swift)"
TOOLCHAIN_DIR="$(dirname "$(dirname "$(dirname "$SWIFT")")")"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
DEPLOYMENT_TARGET="$(plutil -extract LSMinimumSystemVersion raw "$PACKAGE_DIR/Resources/Info.plist" 2>/dev/null || echo 26.0)"

echo "==> Extracting App Intents metadata..."
xcrun appintentsmetadataprocessor \
    --output "$WORK/out" \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name Loopbacker \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$XCODE_BUILD" \
    --platform-family macOS \
    --deployment-target "$DEPLOYMENT_TARGET" \
    --target-triple "arm64-apple-macosx$DEPLOYMENT_TARGET" \
    --source-file-list "$WORK/sources.txt" \
    --swift-const-vals-list "$WORK/consts.txt" \
    --force

if [ ! -f "$WORK/out/Metadata.appintents/extract.actionsdata" ]; then
    echo "error: appintentsmetadataprocessor produced no Metadata.appintents" >&2
    exit 1
fi
rm -rf "$APP_BUNDLE/Contents/Resources/Metadata.appintents"
cp -R "$WORK/out/Metadata.appintents" "$APP_BUNDLE/Contents/Resources/"
echo "==> Metadata.appintents written."

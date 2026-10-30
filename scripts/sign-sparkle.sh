#!/bin/bash
# Codesigns the embedded Sparkle.framework inside-out: XPC services and helper executables
# first, then the framework bundle itself. `codesign --deep` on the outer .app is not reliable
# for Sparkle -- it can leave the XPC services and Autoupdate helper with stale or missing
# signatures, which notarization rejects. Run this *before* signing the outer .app.
#
# Usage: sign-sparkle.sh <app_bundle> <identity> [--hardened]
#   <app_bundle>  Path to Loopbacker.app (Sparkle.framework must already be at
#                 Contents/Frameworks/Sparkle.framework)
#   <identity>    Codesign identity, or "-" for ad-hoc
#   --hardened    Sign with --options runtime --timestamp (Developer ID / notarization).
#                 Omit for ad-hoc or Apple Development identities, which don't support a
#                 secure timestamp and don't need the hardened runtime locally.
set -euo pipefail

APP_BUNDLE="${1:?usage: sign-sparkle.sh <app_bundle> <identity> [--hardened]}"
IDENTITY="${2:?usage: sign-sparkle.sh <app_bundle> <identity> [--hardened]}"
HARDENED="${3:-}"

FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
VERSIONED="$FRAMEWORK/Versions/B"

if [ ! -d "$FRAMEWORK" ]; then
    echo "==> No Sparkle.framework at $FRAMEWORK, nothing to sign."
    exit 0
fi

SIGN_FLAGS=(--force --sign "$IDENTITY")
if [ "$HARDENED" = "--hardened" ]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
fi

echo "==> Signing Sparkle.framework inside-out ($IDENTITY)..."

# 1. XPC services (used only when the app is sandboxed; still need a valid signature to pass
#    notarization even though Loopbacker doesn't use them).
for xpc in "$VERSIONED"/XPCServices/*.xpc; do
    [ -d "$xpc" ] || continue
    codesign "${SIGN_FLAGS[@]}" "$xpc"
done

# 2. The Autoupdate helper tool that performs the non-sandboxed install.
if [ -f "$VERSIONED/Autoupdate" ]; then
    codesign "${SIGN_FLAGS[@]}" "$VERSIONED/Autoupdate"
fi

# 3. Updater.app, the nested relaunch-and-install helper bundle.
if [ -d "$VERSIONED/Updater.app" ]; then
    codesign "${SIGN_FLAGS[@]}" "$VERSIONED/Updater.app"
fi

# 4. The framework bundle itself (main Sparkle dylib + Resources).
codesign "${SIGN_FLAGS[@]}" "$FRAMEWORK"

echo "==> Sparkle.framework signed."

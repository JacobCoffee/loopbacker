#!/bin/bash
set -euo pipefail

INSTALL_PATH="/Library/Audio/Plug-Ins/HAL/Loopbacker.driver"

if [ ! -d "$INSTALL_PATH" ]; then
    echo "Loopbacker driver not found at $INSTALL_PATH"
    exit 0
fi

echo "==> Removing Loopbacker driver..."
sudo rm -rf "$INSTALL_PATH"

echo "==> Restarting coreaudiod..."
sudo killall -9 coreaudiod || true

echo "==> Done! Loopbacker driver uninstalled."

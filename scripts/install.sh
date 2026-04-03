#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DRIVER_BUILD="$PROJECT_DIR/Driver/build/Loopbacker.driver"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"

echo "==> Building Loopbacker driver..."
cd "$PROJECT_DIR/Driver"
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build

echo "==> Installing to $INSTALL_DIR..."
sudo cp -R "$DRIVER_BUILD" "$INSTALL_DIR/"

echo "==> Restarting coreaudiod..."
sudo killall -9 coreaudiod || true

echo "==> Done! Loopbacker virtual device should now appear in Sound settings."

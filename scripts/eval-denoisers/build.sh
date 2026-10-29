#!/bin/bash
# build.sh -- compiles denoise-cli.swift together with the app's actual DenoiseKernel sources
# (not a reimplementation) into a standalone CLI, without touching App/Loopbacker/Package.swift:
# this links the committed kernel source files directly with swiftc, plus the CRNNoise C object
# `swift build` already produced and a generated Clang module map for its header.
#
# Usage: scripts/eval-denoisers/build.sh
# Output: scripts/eval-denoisers/.build/denoise-cli
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP="$ROOT/App/Loopbacker"
OUT_DIR="$SCRIPT_DIR/.build"
mkdir -p "$OUT_DIR"

# `swift build -c release` must have run at least once so CRNNoise.o and the generated module
# map exist.
CRNNOISE_O="$APP/.build/out/Products/Release/CRNNoise.o"
MODULE_MAP="$APP/.build/out/Intermediates.noindex/GeneratedModuleMaps/CRNNoise.modulemap"
if [[ ! -f "$CRNNOISE_O" || ! -f "$MODULE_MAP" ]]; then
    echo "build.sh: run 'swift build -c release' in App/Loopbacker first (need CRNNoise.o)" >&2
    exit 1
fi

swiftc -O \
    -I "$APP/CRNNoise/include" \
    -Xcc -fmodule-map-file="$MODULE_MAP" \
    -framework Accelerate -framework AVFoundation \
    "$APP/Sources/Services/DenoiseKernel.swift" \
    "$APP/Sources/Services/CompiledGraph.swift" \
    "$APP/Sources/Services/DPDFNetKernel.swift" \
    "$APP/Sources/Services/FastEnhancerKernel.swift" \
    "$APP/Sources/Services/RNNoiseKernel.swift" \
    "$APP/Sources/Services/NoiseSuppressor.swift" \
    "$APP/Sources/Models/NoiseSuppressionSettings.swift" \
    "$CRNNOISE_O" \
    "$SCRIPT_DIR/main.swift" \
    -o "$OUT_DIR/denoise-cli"

echo "wrote $OUT_DIR/denoise-cli"

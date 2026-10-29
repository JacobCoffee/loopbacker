#!/bin/bash
# model-bench.sh -- compiles and runs model-bench.swift against the shipped (or given)
# mlmodelc, with the malloc-counting dylib interposed so the benchmark can report heap
# allocations during BNNS Graph execute.
#
# Usage:
#   scripts/bench/model-bench.sh [--coreml] [path/to/model.mlmodelc]
#
#   --coreml   also report parity (SNR in dB) vs. running the same frames through Core ML.
#   model path defaults to App/Loopbacker/Resources/DPDFNet2_48k.mlmodelc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cc -O2 -dynamiclib -o "$WORK/libcount.dylib" "$SCRIPT_DIR/count.c"

swiftc -O \
    -import-objc-header "$SCRIPT_DIR/count.h" \
    -framework Accelerate -framework CoreML \
    -L "$WORK" -lcount \
    -o "$WORK/model-bench" \
    "$SCRIPT_DIR/model-bench.swift"

DYLD_LIBRARY_PATH="$WORK" DYLD_INSERT_LIBRARIES="$WORK/libcount.dylib" "$WORK/model-bench" "$@"

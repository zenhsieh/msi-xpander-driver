#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mkdir -p target
xcrun clang -fobjc-arc -fblocks -O2 \
  -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
  macos/VTJpegProbe.m -o target/VTJpegProbe
echo "Built target/VTJpegProbe"

#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mkdir -p target
xcrun clang -fobjc-arc -fblocks -O2 \
  -framework Foundation -framework CoreGraphics -framework CoreVideo \
  -framework CoreMedia -framework ImageIO -framework VideoToolbox \
  macos/VTImageEncoder.m -o target/VTImageEncoder
echo "Built target/VTImageEncoder" >&2

#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
export CARGO_TARGET_DIR=/private/tmp/msi-xpander-target
export MSI_DESKTOP_MODE="${MSI_DESKTOP_MODE:-native}"
export MSI_VIRTUAL_COLOR_MODE="${MSI_VIRTUAL_COLOR_MODE:-system-default}"
if [ ! -x "$HOME/Applications/MSI Xpander Desktop.app/Contents/MacOS/MSIXpanderDesktop" ]; then
    bash macos/build-bridge.sh
fi
echo "MSI Xpander extended desktop. Stop with Ctrl-C."
echo "Drag windows past the right edge of your existing desktop."
cargo run --offline --release --features hardware -- desktop

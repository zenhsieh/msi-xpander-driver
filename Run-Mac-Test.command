#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
action="${1:-dashboard}"
case "$action" in
    dashboard|show420|show-prime420) ;;
    *) echo "Usage: bash Run-Mac-Test.command [dashboard|show420|show-prime420]"; exit 2 ;;
esac

log="../msi-xpander-${action}-$(date +%Y%m%d-%H%M%S)-result.txt"
exec > >(tee "$log") 2>&1
finish() {
    result=$?
    echo ""
    echo "Test exit code: $result"
    echo "Log: $log"
}
trap finish EXIT

echo "MSI Xpander Rust v2 Mac test"
date '+Started: %Y-%m-%d %H:%M:%S %z'
echo "Action: $action"
if [ "$(uname -s)" != Darwin ]; then
    echo "ERROR: Run this test on the Mac."
    exit 1
fi
if ! command -v cargo >/dev/null 2>&1 && [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: Cargo is not available in this terminal."
    exit 1
fi
export CARGO_TARGET_DIR="${TMPDIR:-/tmp}/msi-xpander-target"
echo "Build directory: $CARGO_TARGET_DIR"
cargo --version
rustc --version
echo "Running offline protocol and JPEG tests (no USB writes)."
cargo test --features hardware
cargo run --release --features hardware -- verify
echo "Starting USB image test. Panel must be freshly reconnected in default Dashboard mode."
cargo run --release --features hardware -- "$action"
echo "USB test completed. Check the physical panel separately."
echo "Dashboard expected image: six colour bars, a gray ramp and checkerboard."

#!/bin/zsh
set -e
cd "${0:A:h}"
[ -f kiosk/kiosk.env ] && source kiosk/kiosk.env
: "${KIOSK_FRAME_CMD:?Set KIOSK_FRAME_CMD (or put it in kiosk/kiosk.env), e.g. 'ssh myhost render-dashboard'}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/private/tmp/msi-xpander-target}"
cargo build --release --features hardware
exec python3 kiosk/run_kiosk.py --binary "$CARGO_TARGET_DIR/release/msi-xpander" "$@"

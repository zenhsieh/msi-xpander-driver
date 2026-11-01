#!/bin/sh
set -eu
cd -- "$(dirname -- "$0")/.."
[ "$(uname -s)" = Linux ] || { echo 'Run this installer on Linux.' >&2; exit 1; }
cargo build --locked --release --features hardware
install -d "$HOME/.local/bin" "$HOME/.local/libexec/msi-xpander"
install -m 755 target/release/msi-xpander "$HOME/.local/bin/msi-xpander"
install -m 755 linux/gnome-bridge.py "$HOME/.local/libexec/msi-xpander/gnome-bridge.py"
echo 'Installed ~/.local/bin/msi-xpander and GNOME bridge.'
echo 'For USB access, install linux/70-msi-xpander.rules as documented in linux/README.md.'
echo 'Then run ~/.local/bin/msi-xpander desktop from a terminal in GNOME Wayland.'

#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [ ! -d "dist/MSI Xpander.app" ]; then
  bash Build-Menu-Bar.command
fi
exec /usr/bin/python3 macos/install_menu_bar.py "dist/MSI Xpander.app"

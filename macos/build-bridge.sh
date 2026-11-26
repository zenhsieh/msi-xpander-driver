#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
identity="${MSI_SIGN_IDENTITY:-$(/usr/bin/python3 setup_local_signing.py)}"
app="$HOME/Applications/MSI Xpander Desktop.app"
mkdir -p "$app/Contents/MacOS"
xcrun clang -fobjc-arc -fblocks -O2 -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework VideoToolbox DesktopBridge.m -o "$app/Contents/MacOS/MSIXpanderDesktop"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign "$identity" --timestamp=none --identifier com.digiter.msixpander.desktop "$app"
codesign --verify --strict "$app"
echo "$app"

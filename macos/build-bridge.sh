#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
app="$HOME/Applications/MSI Xpander Desktop.app"
mkdir -p "$app/Contents/MacOS"
xcrun clang -fobjc-arc -fblocks -O2 -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo DesktopBridge.m -o "$app/Contents/MacOS/MSIXpanderDesktop"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier com.digiter.msixpander.desktop "$app"
echo "$app"

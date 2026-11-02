#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
identity="${MSI_SIGN_IDENTITY:-$(/usr/bin/python3 macos/setup_local_signing.py)}"
cargo build --release --features hardware
bash macos/build-vt-image-encoder.sh
MSI_SIGN_IDENTITY="$identity" bash macos/freeze_controller.sh
app="$PWD/dist/MSI Xpander.app"
resources="$app/Contents/Resources"
helper="$app/Contents/Helpers/MSI Xpander Desktop.app"
mkdir -p "$app/Contents/MacOS" "$resources/bin" "$resources/kiosk" "$helper/Contents/MacOS"
xcrun clang -fobjc-arc -fblocks -O2 -framework AppKit -framework CoreGraphics macos/MenuBarApp.m -o "$app/Contents/MacOS/MenuBarApp"
cp macos/MenuBarApp-Info.plist "$app/Contents/Info.plist"
cp target/release/msi-xpander target/VTImageEncoder "$resources/bin/"
xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -framework AppKit -framework ScreenSaver \
  -framework CoreGraphics -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
  macos/NativeKioskRenderer.m -o "$resources/bin/NativeKioskRenderer"
codesign --force --sign "$identity" --timestamp=none --identifier com.digiter.xpander.native-kiosk "$resources/bin/NativeKioskRenderer"
cp macos/menu_bar_controller.py "$resources/controller.py"
cp macos/controller_messages.py "$resources/controller_messages.py"
for language in en zh-Hant; do
  ditto "macos/$language.lproj" "$resources/$language.lproj"
done
ditto target/frozen/XpanderController "$resources/controller"
cp kiosk/run_kiosk.py "$resources/kiosk/"
xcrun clang -fobjc-arc -fblocks -O2 -framework AppKit -framework CoreGraphics \
  -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
  macos/DesktopBridge.m -o "$helper/Contents/MacOS/MSIXpanderDesktop"
cp macos/Info.plist "$helper/Contents/Info.plist"
codesign --force --sign "$identity" --timestamp=none --identifier com.digiter.msixpander.desktop "$helper"
codesign --force --sign "$identity" --timestamp=none --identifier com.digiter.xpander.driver "$resources/bin/msi-xpander"
codesign --force --sign "$identity" --timestamp=none --identifier com.digiter.xpander.jpeg "$resources/bin/VTImageEncoder"
codesign --force --sign "$identity" --timestamp=none --identifier com.digiter.xpander.menu "$app"
codesign --verify --deep --strict "$app"
echo "Built: $app"

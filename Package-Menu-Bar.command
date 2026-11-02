#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
bash Build-Menu-Bar.command
staging="$PWD/target/dmg-staging"
mkdir -p "$staging"
ditto "dist/MSI Xpander.app" "$staging/MSI Xpander.app"
if [ ! -L "$staging/Applications" ]; then
  ln -s /Applications "$staging/Applications"
fi
cat > "$staging/使用說明.txt" <<'EOF'
將 MSI Xpander 拖到 Applications，然後開啟。

右上角螢幕圖示可切換 Kiosk、延伸桌面、停止輸出。
Kiosk 不需要螢幕錄製權限；延伸桌面第一次使用時，
請從選單的「螢幕錄製權限…」開啟設定並允許 MSI Xpander。

可自行設定 Kiosk 的 PNG 來源指令；延伸桌面不需要來源指令。
測試視窗預設關閉，可在「測試選項」啟用。
EOF
cat > "$staging/Read Me.txt" <<'EOF'
Drag MSI Xpander to Applications, then open it.

Display offers Kiosk, Extended Desktop, Screen Saver, and Screen Off.
Use Extended Desktop for apps or macOS desktop widgets as you prefer.
Settings contains the source, quality, update rate, language and login options.
Tools contains permission help, logs and test options.

Settings > Language: Follow System, Traditional Chinese, or English.
Extended Desktop requires Screen Recording permission for MSI Xpander.
Manual mode choices affect only the panel; it automatically follows Mac
screen saver and screen/system sleep and wake.
Screen Off sends black and stops updates; the panel remains USB powered.
EOF
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' 'dist/MSI Xpander.app/Contents/Info.plist')"
image="$PWD/dist/MSI-Xpander-${version}-arm64.dmg"
hdiutil create -volname 'MSI Xpander' -srcfolder "$staging" -ov -format UDZO "$image"
ditto -c -k --sequesterRsrc --keepParent 'dist/MSI Xpander.app' "dist/MSI-Xpander-${version}-arm64.zip"
echo "Package: $image"

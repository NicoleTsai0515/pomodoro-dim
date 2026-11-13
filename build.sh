#!/bin/bash
# 編譯成 番茄鐘護眼.app（新舊 Mac 都能跑，只出現在選單列，不佔 Dock）
# 在本機硬碟暫存區編譯與簽章，再複製回來，避免外接硬碟產生的 ._ 暫存檔破壞簽章。
set -e
cd "$(dirname "$0")"
NAME="番茄鐘護眼.app"
BUILD=$(mktemp -d)
APP="$BUILD/$NAME"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macos12.0 Pomodoro.swift -o "$BUILD/arm64"
swiftc -O -target x86_64-apple-macos12.0 Pomodoro.swift -o "$BUILD/x86_64"
lipo -create "$BUILD/arm64" "$BUILD/x86_64" -output "$APP/Contents/MacOS/Pomodoro"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>番茄鐘護眼</string>
<key>CFBundleIdentifier</key><string>local.nicole.pomodoro-dim</string>
<key>CFBundleExecutable</key><string>Pomodoro</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.nicole.pomodoro-dim "$APP"
codesign --verify --verbose=1 "$APP"
ditto --norsrc --noextattr --noqtn "$APP" "$NAME"
echo "完成：$(pwd)/$NAME"

#!/bin/bash
# 一键打包成 DockSide.app（需要 Xcode 或 Command Line Tools：xcode-select --install）
set -euo pipefail
cd "$(dirname "$0")"

# UNIVERSAL=1 ./build.sh 可同时编译 Apple 芯片 + Intel（需要完整 Xcode）
FLAGS=(-c release)
if [[ "${UNIVERSAL:-}" == "1" ]]; then FLAGS+=(--arch arm64 --arch x86_64); fi
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/DockSide"

APP="build/DockSide.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DockSide"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 由 1024px PNG 生成 .icns 图标
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
    sips -z $sz $sz Resources/AppIcon.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) Resources/AppIcon.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 固定签名要求：只认 Bundle ID，不认每次编译都会变的哈希，
# 这样覆盖安装新版后「辅助功能」授权不会失效
codesign --force --deep --sign - \
    --identifier com.keovi.DockSide \
    -r='designated => identifier "com.keovi.DockSide"' \
    "$APP"

echo "✅ 已生成 $APP"
if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/DockSide.app
    cp -R "$APP" /Applications/
    echo "✅ 已安装到 /Applications，正在启动…"
    open /Applications/DockSide.app
fi

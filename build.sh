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
codesign --force --deep --sign - "$APP"

echo "✅ 已生成 $APP"
if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/DockSide.app
    cp -R "$APP" /Applications/
    echo "✅ 已安装到 /Applications，正在启动…"
    open /Applications/DockSide.app
fi

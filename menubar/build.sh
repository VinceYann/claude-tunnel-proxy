#!/usr/bin/env bash
# ============================================================
#  编译并打包 TunnelBar.app（菜单栏应用）
#  --------------------------------------------
#  产物输出到项目根目录: ../TunnelBar.app
#  依赖: swiftc（Xcode Command Line Tools 自带）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TunnelBar"
PROJECT_DIR="$(cd .. && pwd)"   # 仅用于确定产物输出位置
BUILD_DIR=".build"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "编译 ${APP_NAME} (Swift)..."
swiftc -O -framework AppKit TunnelBar.swift -o "$BUILD_DIR/$APP_NAME"

echo "打包 ${APP_BUNDLE} ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.yanjingshu.tunnelbar</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo ""
echo "[OK] 构建完成: ${APP_BUNDLE}"
echo "      启动: open \"${APP_BUNDLE}\""
echo "      或 Finder 双击 TunnelBar.app"

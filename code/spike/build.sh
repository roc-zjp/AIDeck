#!/bin/bash
# 组装成 .app —— WKWebView 需要 bundle identifier，裸可执行文件跑不起来
set -euo pipefail
cd "$(dirname "$0")"
APP="build/LiveDesktopSpike.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LiveDesktopSpike "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp -R Resources/web "$APP/Contents/Resources/"
codesign --force --deep -s - "$APP" 2>/dev/null || true   # ad-hoc 签名，自用足够
echo "✅ $APP"

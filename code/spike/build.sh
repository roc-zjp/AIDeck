#!/bin/bash
# 组装成 .app —— WKWebView 需要 bundle identifier，裸可执行文件跑不起来
set -euo pipefail
cd "$(dirname "$0")"
APP="build/LiveDesktopSpike.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LiveDesktopSpike "$APP/Contents/MacOS/"
cp .build/release/LdStatusline "$APP/Contents/MacOS/ld-statusline"   # statusline 透传 wrapper，随包分发
cp .build/release/LdHook "$APP/Contents/MacOS/ld-hook"                 # Notification hook 监听器，随包分发
cp Info.plist "$APP/Contents/"
cp -R Resources/web "$APP/Contents/Resources/"
# 签名：默认 ad-hoc（自用足够）；有 Developer ID 后 export LD_SIGN_IDENTITY="Developer ID Application: …" 即走正式签名
IDENTITY="${LD_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  codesign --force -s - "$APP/Contents/MacOS/ld-statusline" 2>/dev/null || true
  codesign --force -s - "$APP/Contents/MacOS/ld-hook" 2>/dev/null || true
  codesign --force --deep -s - "$APP" 2>/dev/null || true
else
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/MacOS/ld-statusline"
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/MacOS/ld-hook"
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
  echo "已用「$IDENTITY」签名（分发还需 notarize：xcrun notarytool submit + stapler）"
fi
echo "✅ $APP"

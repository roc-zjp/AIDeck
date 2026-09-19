#!/bin/bash
# 组装成 .app —— WKWebView 需要 bundle identifier，裸可执行文件跑不起来。
# 产品名、SPM target、.app 与可执行名统一为 AIDeck。
# 分发：LD_UNIVERSAL=1 出双架构；LD_SIGN_IDENTITY="Developer ID Application: …" 走正式签名（再 notarize）。
set -euo pipefail
cd "$(dirname "$0")"
APP="build/AIDeck.app"

# 默认单架构（本机开发迭代快）；LD_UNIVERSAL=1 出 arm64+x86_64（分发用，产物路径也不同）
if [ "${LD_UNIVERSAL:-}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BINDIR=".build/apple/Products/Release"
else
  swift build -c release
  BINDIR=".build/release"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/AIDeck" "$APP/Contents/MacOS/AIDeck"           # 主程序，更名为 AIDeck
cp "$BINDIR/LdStatusline" "$APP/Contents/MacOS/ld-statusline"        # statusline 透传 wrapper，随包分发
cp "$BINDIR/LdHook" "$APP/Contents/MacOS/ld-hook"                    # Notification hook 监听器，随包分发
cp Info.plist "$APP/Contents/"
cp -R Resources/web "$APP/Contents/Resources/"
[ -f AIDeck.icns ] && cp AIDeck.icns "$APP/Contents/Resources/"      # 应用图标（通知横幅 / Dock / 登录项）

# 签名：默认 ad-hoc（自用足够）；有 Developer ID 后 export LD_SIGN_IDENTITY 即走正式签名
IDENTITY="${LD_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  codesign --force -s - "$APP/Contents/MacOS/ld-statusline" 2>/dev/null || true
  codesign --force -s - "$APP/Contents/MacOS/ld-hook" 2>/dev/null || true
  codesign --force --deep -s - "$APP" 2>/dev/null || true
else
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/MacOS/ld-statusline"
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/MacOS/ld-hook"
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/MacOS/AIDeck"
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
  echo "已用「$IDENTITY」签名（分发还需 notarize：xcrun notarytool submit + stapler）"
fi
echo "✅ $APP"

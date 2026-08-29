#!/bin/bash
# 打 DMG：先 LD_UNIVERSAL=1 ./build.sh 出双架构 .app，再装进带 Applications 快捷方式的 DMG。
# 用法：./package.sh            → ad-hoc 内测包（收件人需右键→打开绕过 Gatekeeper）
#       LD_SIGN_IDENTITY="Developer ID Application: …" ./package.sh → 正式签名包（之后还需 notarytool 公证 + stapler）
set -euo pipefail
cd "$(dirname "$0")"
APP="build/AIDeck.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)
ARCH_TAG="universal"
SIGN_TAG="adhoc"; [ -n "${LD_SIGN_IDENTITY:-}" ] && SIGN_TAG="signed"
OUT="build/AIDeck-${VERSION}-${BUILD}-${ARCH_TAG}-${SIGN_TAG}.dmg"

LD_UNIVERSAL=1 ./build.sh
echo "架构：$(lipo -archs "$APP/Contents/MacOS/AIDeck")"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [ "$SIGN_TAG" = "adhoc" ]; then
  # 内测说明：ad-hoc 签名没过公证，收件人第一次打开必须绕 Gatekeeper
  cat > "$STAGE/内测说明.txt" <<'TXT'
AIDeck 内测包（ad-hoc 签名，未公证）

安装：把 AIDeck 拖到 Applications。

第一次打开会被 macOS 拦（"无法打开，因为无法验证开发者"）——这是签名类型导致的，不是坏了：
  · 方法一：在 Applications 里右键 AIDeck → 打开 → 再点「打开」
  · 方法二：双击被拦后，去 系统设置 → 隐私与安全性 → 底部点「仍要打开」
只需一次，以后正常双击。

它是菜单栏 App，没有 Dock 图标：首次启动会弹一个欢迎面板介绍入口；关掉后看菜单栏彩色圆盘，
或右键桌面上的状态卡打开设置。刘海屏菜单栏图标可能被挤掉——右键状态卡是永远可用的入口。

需要 Claude Code 在跑才有数据。额度 / 精细态两项接入会改 ~/.claude/settings.json（改前整份备份、可一键恢复），
都在设置页里点，没点就不会碰。
TXT
fi

rm -f "$OUT"
hdiutil create -volname "AIDeck" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT"
rm -rf "$STAGE"
[ -n "${LD_SIGN_IDENTITY:-}" ] && codesign --force --timestamp -s "$LD_SIGN_IDENTITY" "$OUT"
echo "✅ $OUT  ($(du -h "$OUT" | cut -f1))"
[ "$SIGN_TAG" = "adhoc" ] && echo "   ad-hoc 内测包：收件人首次需右键→打开；公开分发请用 Developer ID 签名并公证"

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
AIDeck 内测版

安装
  将 AIDeck 拖入 Applications 文件夹。

首次打开
  本版本为内测签名，未经 Apple 公证，首次打开时 macOS 会提示"无法验证开发者"。
  请在 Applications 中右键点击 AIDeck，选择「打开」，再次确认即可；此后可正常双击启动。
  或：系统设置 → 隐私与安全性 → 点击「仍要打开」。

使用
  AIDeck 是菜单栏应用，不在 Dock 中显示。首次启动将显示引导面板。
  · 状态卡：桌面上的会话状态面板，右键可打开设置
  · 菜单栏图标：颜色随会话状态变化，点击查看详情与设置
  在刘海屏上菜单栏图标可能被系统隐藏，状态卡入口始终可用。

数据来源
  AIDeck 读取本机 Claude Code 的会话记录，Claude Code 运行中才有数据。
  额度显示与权限确认状态为可选接入，需修改 Claude Code 配置（~/.claude/settings.json）；
  接入前自动备份完整配置，可在设置中一键恢复。未接入时不会修改任何配置。
TXT
fi

rm -f "$OUT"
hdiutil create -volname "AIDeck" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT"
rm -rf "$STAGE"
[ -n "${LD_SIGN_IDENTITY:-}" ] && codesign --force --timestamp -s "$LD_SIGN_IDENTITY" "$OUT"
echo "✅ $OUT  ($(du -h "$OUT" | cut -f1))"
[ "$SIGN_TAG" = "adhoc" ] && echo "   ad-hoc 内测包：收件人首次需右键→打开；公开分发请用 Developer ID 签名并公证"

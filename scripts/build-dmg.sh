#!/bin/bash
# ============================================================
# Dreamanual NAS 助手 打包 DMG
# 用法:
#   ./scripts/build-dmg.sh            # 编译 → 组装 → 签名 → 打 DMG → 装进 /Applications
#
# 🔴 .app 不留开发目录（会被注册成第二个应用）：组装产物在 /tmp/nas-build/，
#    DMG 落 dist/，装完 /tmp 里的 .app 直接随构建目录留给下次覆盖。
#    （与 invest/video 同一条规矩；本脚本用原生 hdiutil —— 没有 appdmg 的
#    背景图素材，窗口用默认布局。）
# ============================================================

set -e
cd "$(dirname "$0")/.."

VOL_NAME="Dreamanual NAS 助手"
DMG_DIR="dist"
DMG_OUT="$DMG_DIR/$VOL_NAME.dmg"
APP_NAME="/tmp/nas-build/Dreamanual NAS 助手.app"

echo "========== 1/2 组装 app（复用 build-app.sh） =========="
./scripts/build-app.sh

echo "========== 2/2 打包 DMG =========="
mkdir -p "$DMG_DIR"
rm -f "$DMG_OUT"

work="$(mktemp -d)"
stage="$work/stage"
mkdir -p "$stage"
cp -R "$APP_NAME" "$stage/"
ln -s /Applications "$stage/Applications"
cat > "$stage/安装说明.txt" <<'TXT'
Dreamanual NAS 助手

1. 把「Dreamanual NAS 助手.app」拖进右边Applications（应用程序）文件夹
2. 首次打开若提示「无法验证开发者」：右键点 app 选「打开」，或在
   系统设置 → 隐私与安全性 里点「仍要打开」
3. 打开后填 QuickConnect ID（或直连地址）与 NAS 账号密码

系统要求：macOS 14+，Apple Silicon，群晖 DSM 7
主页：https://dreamanual.com/works/nas.html
TXT
tmp="$work/tmp.dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$stage" -ov -format UDRW -fs HFS+ "$tmp" >/dev/null
mnt="$(hdiutil attach "$tmp" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*' | head -1)"
hdiutil detach "$mnt" >/dev/null 2>&1 || hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
hdiutil convert "$tmp" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null
rm -rf "$work"

echo "DMG 打包完成: $DMG_OUT"
ls -lh "$DMG_OUT"

echo ""
echo "========== 安装到 /Applications =========="
APP_BASE="$(basename "$APP_NAME")"
stamp="$(date +%Y%m%d-%H%M%S)"
if [ -e "/Applications/$APP_BASE" ]; then
  mv "/Applications/$APP_BASE" "$HOME/.Trash/$APP_BASE.replaced-$stamp"
  echo "  旧包已移入废纸篓"
fi
ditto "$APP_NAME" "/Applications/$APP_BASE"
echo "  已安装：/Applications/$APP_BASE"
echo "运行: pkill -f DreamanualNAS; sleep 1; open '/Applications/$APP_BASE'"

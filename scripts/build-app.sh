#!/bin/bash
# ============================================================
# Dreamanual NAS 助手 构建脚本（骨架阶段：编译 → 组装 → 签名）
# 用法:
#   ./scripts/build-app.sh              # 出 dist/Dreamanual NAS 助手.app
#   ./scripts/build-app.sh --install    # 额外装进 /Applications
#
# 与产品线其它 app 同一套链路：actool（有资产目录才跑）→ swiftc → 组 .app → codesign。
# DMG 打包等发版批再接（投资监控 / 视频下载用的是 appdmg 方案）。
# ============================================================

set -e
cd "$(dirname "$0")/.."

APP_NAME="dist/Dreamanual NAS 助手.app"
BUILD_DIR="/tmp/nas-build"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
  esac
done

echo "========== 1/3 编译 =========="
# -disable-sandbox：沙箱隔离会杀掉 swift-plugin-server（信号 137），宏全部报
# malformed response。终端里本就不受限，加上对正常流程无影响。
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

if [ -d "DreamanualNAS/Assets.xcassets" ]; then
  xcrun actool --compile "$BUILD_DIR" --platform macosx --minimum-deployment-target 14.0 \
    DreamanualNAS/Assets.xcassets \
    --output-partial-info-plist "$BUILD_DIR/actool.plist" >/dev/null 2>&1 || true
  [ -f "$BUILD_DIR/Assets.car" ] || echo "  提示：actool 没产出 Assets.car（资产目录里还没有可编译的条目？）"
else
  echo "  暂无 Assets.xcassets（图标资产后补），跳过 actool"
fi

xcrun swiftc -disable-sandbox -O -parse-as-library -target arm64-apple-macos14.0 \
  $(find DreamanualNAS -name "*.swift") \
  -o "$BUILD_DIR/DreamanualNAS"
echo "编译成功"

echo "========== 2/3 组装 app =========="
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS" "$APP_NAME/Contents/Resources"
cp "$BUILD_DIR/DreamanualNAS" "$APP_NAME/Contents/MacOS/DreamanualNAS"
cp DreamanualNAS/Info.plist "$APP_NAME/Contents/Info.plist"
if [ -f "$BUILD_DIR/Assets.car" ]; then
  cp "$BUILD_DIR/Assets.car" "$APP_NAME/Contents/Resources/Assets.car"
fi
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP_NAME/Contents/Resources/AppIcon.icns"
cp DreamanualNAS/Resources/brand.svg "$APP_NAME/Contents/Resources/brand.svg"
echo "app 组装完成：$APP_NAME"

echo "========== 3/3 签名 =========="
codesign --force --deep --sign - "$APP_NAME"
echo "签名完成"

if [ "$INSTALL" -eq 1 ]; then
  APP_BASE="$(basename "$APP_NAME")"
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [ -e "/Applications/$APP_BASE" ]; then
    mv "/Applications/$APP_BASE" "$HOME/.Trash/$APP_BASE.replaced-$stamp"
    echo "  旧包已移入废纸篓"
  fi
  ditto "$APP_NAME" "/Applications/$APP_BASE"
  echo "  已安装：/Applications/$APP_BASE"
  echo "运行: pkill -f DreamanualNAS; sleep 1; open '/Applications/$APP_BASE'"
else
  echo "运行: open '$APP_NAME'"
fi

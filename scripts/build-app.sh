#!/bin/bash
# ============================================================
# Dreamanual NAS 助手 构建脚本（骨架阶段：编译 → 组装 → 签名）
# 用法:
#   ./scripts/build-app.sh              # 出 /tmp/nas-build/Dreamanual NAS 助手.app
#   ./scripts/build-app.sh --install    # 额外装进 /Applications
#
# 🔴 .app 不落开发目录（会被注册成第二个应用）：组装产物一律在 /tmp/nas-build/，
# dist/ 只收发版物料（DMG，发版批再接）。
# 与产品线其它 app 同一套链路：actool（有资产目录才跑）→ swiftc → 组 .app → codesign。
# ============================================================

set -e
cd "$(dirname "$0")/.."

APP_NAME="/tmp/nas-build/Dreamanual NAS 助手.app"
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

# 状态栏面板复用小组件的中组件视图（NASStatusContent），这份共享源主 app
# 也要编进来（它只依赖 SwiftUI + 主题令牌，无 WidgetKit 依赖）。
xcrun swiftc -disable-sandbox -O -parse-as-library -target arm64-apple-macos14.0 \
  $(find DreamanualNAS -name "*.swift") \
  DreamanualWidget/WidgetContent.swift \
  -o "$BUILD_DIR/DreamanualNAS"
echo "编译成功"

echo "========== 1b/3 小组件 extension =========="
# 小组件是独立 target：精选共享源（连接层 / 状态解码 / 共享快照 / 主题）
# + widget 本体，@main 在 widget bundle 里，主 app 的入口不进来。
# extension 必须沙箱（macOS 不注册非沙箱的 app extension，图库不出现），
# 所以凭据层（CredentialStore / KeychainStore）不进 widget —— 沙箱里
# 读不了主 app 的 credential.json，口令随快照带（见 Core/WidgetBridge.swift
# 头注）；主 app 直写 widget 的沙箱容器。
WIDGET_SOURCES=(
  DreamanualWidget/WidgetContent.swift
  DreamanualWidget/NASStatusWidget.swift
  DreamanualNAS/Core/SynologyClient.swift
  DreamanualNAS/Core/QuickConnect.swift
  DreamanualNAS/Core/SessionManager.swift
  DreamanualNAS/Core/StreamEndpoint.swift
  DreamanualNAS/Core/SystemStatus.swift
  DreamanualNAS/Core/WidgetBridge.swift
  DreamanualNAS/DesignSystem/DreamanualTheme.nas.swift
)
xcrun swiftc -disable-sandbox -O -parse-as-library -target arm64-apple-macos14.0 \
  "${WIDGET_SOURCES[@]}" \
  -o "$BUILD_DIR/NASStatusWidget"
# 🔴 SDK 版本压回 26.5（vtool 改写 LC_BUILD_VERSION）：Xcode 27 的 SDK 比本机系统
# 26.6.2 还新，ExtensionKit 在「Extension Type」判定后拒答——表现为 chronod 发
# getAllDescriptors 后 17ms 连接失效、扩展进程 voluntary 退出、图库搜不到（2026-10-16
# 实测定位）。-swiftc 的 -sdk 旗子只改搜索路径不改这个版本号，只能事后 vtool。
# CLT 自带的 26.5 swiftc 不支持 macos14 部署目标，故仍用 Xcode 工具链编译。
vtool -arch arm64 -set-build-version macos 14.0 26.5 -replace \
  -output "$BUILD_DIR/NASStatusWidget.sdkfix" "$BUILD_DIR/NASStatusWidget" &&
  mv "$BUILD_DIR/NASStatusWidget.sdkfix" "$BUILD_DIR/NASStatusWidget"
echo "widget 编译成功（SDK 版本已压到 26.5）"

echo "========== 2/3 组装 app =========="
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS" "$APP_NAME/Contents/Resources"
cp "$BUILD_DIR/DreamanualNAS" "$APP_NAME/Contents/MacOS/DreamanualNAS"
cp DreamanualNAS/Info.plist "$APP_NAME/Contents/Info.plist"
# PkgInfo：Xcode 产物自带（APPL????），LaunchServices 识别用
printf 'APPL????' > "$APP_NAME/Contents/PkgInfo"
if [ -f "$BUILD_DIR/Assets.car" ]; then
  cp "$BUILD_DIR/Assets.car" "$APP_NAME/Contents/Resources/Assets.car"
fi
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP_NAME/Contents/Resources/AppIcon.icns"
cp DreamanualNAS/Resources/brand.svg "$APP_NAME/Contents/Resources/brand.svg"
# 空 .lproj 目录 = 向 AppKit 申报可用本地化，系统存盘/打开面板才出中文
#（配合 Info.plist 的 CFBundleDevelopmentRegion/CFBundleLocalizations）。
mkdir -p "$APP_NAME/Contents/Resources/zh-Hans.lproj" \
         "$APP_NAME/Contents/Resources/en.lproj"

# 小组件 extension 塞进 PlugIns（先于签名；主 app 单层签，见下方签名段）。
WIDGET_PLUG="$APP_NAME/Contents/PlugIns/NAS Status Widget.appex"
mkdir -p "$WIDGET_PLUG/Contents/MacOS"
cp DreamanualWidget/Info.plist "$WIDGET_PLUG/Contents/Info.plist"
cp "$BUILD_DIR/NASStatusWidget" "$WIDGET_PLUG/Contents/MacOS/NASStatusWidget"
# Resources/Info.plist 副本：Xcode 产物 appex 里有这一份（sealed resources 计数一致）
mkdir -p "$WIDGET_PLUG/Contents/Resources"
cp DreamanualWidget/Info.plist "$WIDGET_PLUG/Contents/Resources/Info.plist"
echo "widget 已嵌入：Contents/PlugIns/NAS Status Widget.appex"
echo "app 组装完成：$APP_NAME"

echo "========== 3/3 签名 =========="
# 顺序有讲究：先带 entitlements 签 appex，再单层签主 app（嵌套 code 的
# CDHash 会 seal 进外层签名）。不能用 --deep —— 它重签嵌套 bundle 时不带
# entitlements，会把 appex 的沙箱签名抹掉，图库立刻搜不到小组件。
codesign --force --sign - --entitlements DreamanualWidget/Widget.entitlements \
  "$APP_NAME/Contents/PlugIns/NAS Status Widget.appex"
codesign --force --sign - "$APP_NAME"
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

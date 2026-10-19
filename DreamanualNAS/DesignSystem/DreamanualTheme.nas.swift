// 由 dreamanual-design/build.mjs 生成，请勿手改。
// 应用：NAS 助手（强调色取自 Tailwind sky）
// 改色 → 改 tokens.json → 重跑 node build.mjs。

import SwiftUI

extension Color {
    static let dmBg = Color(red: 0.0392, green: 0.0392, blue: 0.0392)  // #0a0a0a
    static let dmPanel = Color(red: 0.0902, green: 0.0902, blue: 0.0902)  // #171717
    static let dmPanel2 = Color(red: 0.149, green: 0.149, blue: 0.149)  // #262626
    static let dmPanel3 = Color(red: 0.251, green: 0.251, blue: 0.251)  // #404040
    static let dmLine = Color(red: 0.149, green: 0.149, blue: 0.149)  // #262626
    static let dmLine2 = Color(red: 0.251, green: 0.251, blue: 0.251)  // #404040
    static let dmInk = Color(red: 0.9608, green: 0.9608, blue: 0.9608)  // #f5f5f5
    static let dmInk2 = Color(red: 0.8314, green: 0.8314, blue: 0.8314)  // #d4d4d4
    static let dmInk3 = Color(red: 0.6314, green: 0.6314, blue: 0.6314)  // #a1a1a1
    static let dmDanger = Color(red: 0.9843, green: 0.1725, blue: 0.2118)  // #fb2c36
    static let dmDangerSoft = Color(red: 0.2745, green: 0.0314, blue: 0.0353)  // #460809
    static let dmDangerLine = Color(red: 0.6235, green: 0.0275, blue: 0.0706)  // #9f0712
    static let dmDangerInk = Color(red: 1.0, green: 0.6353, blue: 0.6353)  // #ffa2a2
    static let dmDangerInkStrong = Color(red: 1.0, green: 0.3922, blue: 0.4039)  // #ff6467
    static let dmDangerHover = Color(red: 0.5098, green: 0.0941, blue: 0.102)  // #82181a
    static let dmOk = Color(red: 0.0, green: 0.7373, blue: 0.4902)  // #00bc7d
    static let dmOkSoft = Color(red: 0.0, green: 0.1725, blue: 0.1333)  // #002c22
    static let dmOkLine = Color(red: 0.0, green: 0.3765, blue: 0.2706)  // #006045
    static let dmOkInk = Color(red: 0.3686, green: 0.9137, blue: 0.7098)  // #5ee9b5
    static let dmOkInkStrong = Color(red: 0.0, green: 0.8314, blue: 0.5725)  // #00d492
    static let dmOkHover = Color(red: 0.0, green: 0.3098, blue: 0.2314)  // #004f3b
    static let dmWarn = Color(red: 0.9961, green: 0.6039, blue: 0.0)  // #fe9a00
    static let dmWarnSoft = Color(red: 0.2745, green: 0.098, blue: 0.0039)  // #461901
    static let dmWarnLine = Color(red: 0.5922, green: 0.2353, blue: 0.0)  // #973c00
    static let dmWarnInk = Color(red: 1.0, green: 0.8235, blue: 0.1882)  // #ffd230
    static let dmWarnInkStrong = Color(red: 1.0, green: 0.7255, blue: 0.0)  // #ffb900
    static let dmWarnHover = Color(red: 0.4824, green: 0.2, blue: 0.0235)  // #7b3306
    static let dmMarkSoft = Color(red: 0.4824, green: 0.2, blue: 0.0235)  // #7b3306
    static let dmMarkLine = Color(red: 0.7333, green: 0.302, blue: 0.0)  // #bb4d00
    static let dmMarkInk = Color(red: 0.9961, green: 0.902, blue: 0.5216)  // #fee685
    static let dmToastBg = Color(red: 0.898, green: 0.898, blue: 0.898)  // #e5e5e5
    static let dmToastInk = Color(red: 0.0392, green: 0.0392, blue: 0.0392)  // #0a0a0a
    static let dmScroll = Color(red: 0.3216, green: 0.3216, blue: 0.3216)  // #525252
    static let dmScrollHover = Color(red: 0.451, green: 0.451, blue: 0.451)  // #737373
    static let dmAccent = Color(red: 0.0, green: 0.651, blue: 0.9569)  // #00a6f4
    static let dmAccent2 = Color(red: 0.0, green: 0.7373, blue: 1.0)  // #00bcff
    static let dmAccentSoft = Color(red: 0.0196, green: 0.1843, blue: 0.2902)  // #052f4a
    static let dmAccentLine = Color(red: 0.0, green: 0.349, blue: 0.5412)  // #00598a
    static let dmAccentFill = Color(red: 0.0, green: 0.651, blue: 0.9569)  // #00a6f4
    static let dmAccentFill2 = Color(red: 0.0, green: 0.7373, blue: 1.0)  // #00bcff
    static let dmOnAccent = Color(red: 0.0392, green: 0.0392, blue: 0.0392)  // #0a0a0a
    static let dmAccentRow = Color(red: 0.0, green: 0.4118, blue: 0.6588)  // #0069a8
    static let dmAccentInk = Color(red: 0.4549, green: 0.8314, blue: 1.0)  // #74d4ff
    static let dmOnAccentRow = Color(red: 1.0, green: 1.0, blue: 1.0)  // #ffffff
}

// ---------- 尺度 ----------

/// 圆角。用法：RoundedRectangle(cornerRadius: DmRadius.r8)
enum DmRadius {
    static let r4: CGFloat = 4
    static let r6: CGFloat = 6
    static let r8: CGFloat = 8
    static let r10: CGFloat = 10
    static let r12: CGFloat = 12
    static let r16: CGFloat = 16
}

/// 间距。用法：.padding(DmSpace.s12) / VStack(spacing: DmSpace.s8)
enum DmSpace {
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s6: CGFloat = 6
    static let s8: CGFloat = 8
    static let s10: CGFloat = 10
    static let s12: CGFloat = 12
    static let s14: CGFloat = 14
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
}

/// 字号。用法：.font(.system(size: DmText.t13))
enum DmText {
    static let t10: CGFloat = 10
    static let t11: CGFloat = 11
    static let t12: CGFloat = 12
    static let t13: CGFloat = 13
    static let t14: CGFloat = 14
    static let t15: CGFloat = 15
    static let t17: CGFloat = 17
    static let t20: CGFloat = 20
    static let t28: CGFloat = 28
    static let t34: CGFloat = 34
}

/// 图标尺寸。用法：LucideIcon("play", size: DmIcon.i16)
enum DmIcon {
    static let i10: CGFloat = 10
    static let i12: CGFloat = 12
    static let i14: CGFloat = 14
    static let i16: CGFloat = 16
    static let i18: CGFloat = 18
    static let i20: CGFloat = 20
    static let i24: CGFloat = 24
    static let i32: CGFloat = 32
    static let i44: CGFloat = 44
    static let i64: CGFloat = 64
}

/// 控件高度（按钮 / 输入框 / 搜索框 / 图标钮）。用法：.frame(height: DmControl.h38)
enum DmControl {
    static let h28: CGFloat = 28
    static let h32: CGFloat = 32
    static let h38: CGFloat = 38
}

/// 描边线宽。用法：.stroke(Color.dmLine2, lineWidth: DmLine.base)
enum DmLine {
    static let hairline: CGFloat = 0.5
    static let base: CGFloat = 1
    static let bold: CGFloat = 3
}

/// 动效时长（秒）。用法：.easeOut(duration: DmMotion.fast)
enum DmMotion {
    static let fast: Double = 0.14
    static let base: Double = 0.22
    static let slow: Double = 0.28
}

/// 窗口级布局常量（非尺度档）。用法：.padding(.top, DmLayout.titlebar)
enum DmLayout {
    static let titlebar: CGFloat = 30
}
// ---------- 阴影 ----------

/// 一条阴影的四个参数。与 CSS 的 box-shadow 不同构（那边可叠多层、blur 与 SwiftUI 的
/// radius 语义也不同），所以这一组是 Swift 侧独立定值，不是 css 值的换算。
struct DmShadowSpec {
    let ink: Double
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

/// 阴影四档：card 列表内卡片 / toast 会话提示 / modal 弹窗与浮层 / knob 开关滑块。
enum DmShadow {
    static let card = DmShadowSpec(ink: 0.04, radius: 4, x: 0, y: 2)
    static let toast = DmShadowSpec(ink: 0.3, radius: 8, x: 0, y: 2)
    static let modal = DmShadowSpec(ink: 0.4, radius: 24, x: 0, y: 8)
    static let knob = DmShadowSpec(ink: 0.2, radius: 1, x: 0, y: 1)
}

extension View {
    /// 按 DmShadow 的一档上阴影。要自己传数值时走这里，别直接写 .shadow(...)。
    func dmShadow(_ spec: DmShadowSpec) -> some View {
        shadow(color: .black.opacity(spec.ink), radius: spec.radius, x: spec.x, y: spec.y)
    }

    func dmShadowCard() -> some View { dmShadow(DmShadow.card) }
    func dmShadowToast() -> some View { dmShadow(DmShadow.toast) }
    func dmShadowModal() -> some View { dmShadow(DmShadow.modal) }
    func dmShadowKnob() -> some View { dmShadow(DmShadow.knob) }
}

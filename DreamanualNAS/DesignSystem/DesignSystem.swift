import SwiftUI
import AppKit

// ============ 设计系统：组件层 ============
//
// 色值不在这里 —— 全部来自同目录的 `DreamanualTheme.nas.swift`
// （由 dreamanual-app/design/build.mjs 生成，勿手改）。
// 本文件只放「同一件事在多个视图里各写一遍」的那些部分。
//
// 改色：改 design/tokens.json → 重跑 build.mjs → 拷生成物到本目录 → `node scripts/check-tokens.mjs`

/// 全 app 固定深色。
///
/// 设计系统令牌只有深色一套，跟随系统会让浅色系统下的界面落到没有令牌覆盖的分支上
/// （窗口底色、卡片、文字全部退回系统色，与设计系统脱节）。密码管理是 Web 端、
/// 同样固定深色，两边保持一致。
enum DreamanualAppearance {
    static func apply() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

/// 选中 / 悬停的三件套配色。NAS 是全产品线里唯一走**浅底形态**的 app。
///
/// 四个老 app 的选中是实心强调色底 + 白/深字（`accent-fill-2` 一整条），
/// 用户 2026-10-12 拍板 NAS 单独走浅底（`accent-soft` 底 + `accent-2` 字，6.37:1）：
/// 选中与「正在播放」共用同一底色，靠均衡器图标区分，实心底会把那一列压得太重。
///
/// 产品线没有「选中 + 悬停」这一态 —— 选中直接盖过悬停，与四个老 app 的
/// `SelectState.of(isSelected:hovered:)` 同一条规矩，所以这里也不看 hovered。
enum SelectState {
    case normal
    case hovered
    case selected
    /// 选中但窗口失焦：底保持 `accent-soft`，字从 `accent-2`（400 档）掉到
    /// `accent`（500 档）—— 亮度降一截、轮廓还在。别降成中性底：它与面板底
    /// 亮度几乎相同，选中行会直接隐身（老四端在实心方案下踩过这个坑）。
    case selectedInactive

    static func of(isSelected: Bool, hovered: Bool, windowActive: Bool = true) -> SelectState {
        if isSelected { return windowActive ? .selected : .selectedInactive }
        return hovered ? .hovered : .normal
    }

    var background: Color {
        switch self {
        case .normal: return .clear
        case .hovered: return .dmPanel2
        case .selected, .selectedInactive: return .dmAccentSoft
        }
    }

    var foreground: Color {
        switch self {
        case .normal: return .dmInk2
        case .hovered: return .dmInk
        case .selected: return .dmAccent2
        case .selectedInactive: return .dmAccent
        }
    }
}

// ============ 图标 ============

/// Lucide 图标（全产品线统一）。SVG 由 `design/spike/icons.mjs` 栅格化后放进
/// Assets，命名 `lucide-<name>`。
///
/// 骨架阶段还没有资产目录，所以落到 SF Symbols 兜底 —— 名字对不上时**不崩、
/// 不空白**，界面上少一个图形而已。图标资产在后一批补齐，届时这张兜底表
/// 只服务「某枚图标漏收」这一种情况。
struct LucideIcon: View {
    let name: String
    let size: CGFloat

    init(_ name: String, size: CGFloat) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Group {
            if let image = NSImage(named: "lucide-\(name)") {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: Self.symbolFallback[name] ?? "questionmark")
                    .font(.system(size: size * 0.9, weight: .regular))
                    .frame(width: size, height: size)
            }
        }
    }

    private static let symbolFallback: [String: String] = [
        "headphones": "headphones",
        "folder": "folder",
        "folder-open": "folder",
        "gauge": "gauge.medium",
        "settings": "gearshape",
        "music": "music.note",
        "server": "externaldrive.connected.to.line.below",
        "power": "power",
        "search": "magnifyingglass",
        "star": "star",
        "play": "play.fill",
        "pause": "pause.fill",
        "skip-back": "backward.fill",
        "skip-forward": "forward.fill",
        "shuffle": "shuffle",
        "repeat": "repeat",
        "volume-2": "speaker.wave.2",
        "list-music": "list.bullet",
        "loader": "arrow.triangle.2.circlepath",
        "circle-check": "checkmark.circle.fill",
        "circle-x": "xmark.circle.fill",
        "triangle-alert": "exclamationmark.triangle",
        "wifi": "wifi",
        "key-round": "key",
        "link": "link",
        "refresh-cw": "arrow.clockwise",
    ]
}

// ============ 共用视图 ============

/// 侧栏 / 列表行的悬停跟踪。手写行才需要，原生 `List` 自己会管。
struct HoverState: ViewModifier {
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        content.onHover { isHovered = $0 }
    }
}

extension View {
    func trackingHover(_ isHovered: Binding<Bool>) -> some View {
        modifier(HoverState(isHovered: isHovered))
    }
}

/// 窗口是否处于活跃（key）状态。手写选中行要自己接这个 —— 原生 `List`
/// 失焦会自动把选中行降级，换成手写行之后得靠 `SelectState.selectedInactive`。
struct WindowActiveReader<Content: View>: View {
    let content: (Bool) -> Content

    @State private var isActive = true

    var body: some View {
        content(isActive)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                isActive = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                isActive = false
            }
    }
}

// ============ 控件 ============

/// 主按钮：实心强调色档（表单规格：高 38 / 横向内边距 16 / 圆角 8 / 字号 13）。
///
/// 深字方案（NAS 与投资监控同构）：底取 `accent-fill`（sky-500），悬停提到
/// 更亮的 `accent-fill-2`（sky-400）—— 白字方案才是 hover 加深。
/// 禁用态原样整体压暗到 0.5（与四端同一口径）。
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DmText.t13, weight: .medium))
            .lineLimit(1)
            .foregroundColor(Color.dmOnAccent)
            .padding(.horizontal, DmSpace.s16)
            .frame(height: DmControl.h38)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .fill(fillColor)
            )
            .opacity(opacity(configuration))
            .onHover { isHovered = $0 }
    }

    private var fillColor: Color {
        if isEnabled && isHovered { return .dmAccentFill2 }
        return .dmAccentFill
    }

    private func opacity(_ configuration: Configuration) -> Double {
        if !isEnabled { return 0.5 }
        return configuration.isPressed ? 0.85 : 1
    }
}

/// 次按钮：紧凑规格（高 28 / 横向内边距 10 / 圆角 6 / 字号 12）。
/// 面板内的小动作与弹窗页脚用它。
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DmText.t12))
            .lineLimit(1)
            .foregroundColor(isEnabled && isHovered ? Color.dmInk : Color.dmInk2)
            .padding(.horizontal, DmSpace.s10)
            .frame(height: DmControl.h28)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r6)
                    .fill(isEnabled && isHovered ? Color.dmPanel3 : Color.dmPanel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r6)
                    .strokeBorder(Color.dmLine, lineWidth: DmLine.base)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .onHover { isHovered = $0 }
    }
}

/// 输入框外壳：表单规格（高 38 / 圆角 8 / 字号 13），横向内边距 12。
/// 聚焦时描边转 `accent-2`（浅档）。名字不带 `dm` 前缀 —— 那是生成令牌的
/// 命名空间，门禁按它对账。
private struct FormFieldModifier: ViewModifier {
    @Environment(\.isFocused) private var envFocused

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: DmText.t13))
            .foregroundStyle(Color.dmInk)
            .padding(.horizontal, DmSpace.s12)
            .frame(height: DmControl.h38)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r8).fill(Color.dmPanel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .strokeBorder(envFocused ? Color.dmAccent2 : Color.dmLine2, lineWidth: DmLine.base)
            )
    }
}

extension View {
    func formField() -> some View {
        modifier(FormFieldModifier())
    }
}

/// 表单标签：字号 12 / 字重 500 / `ink-2`（第八节「文字档位」）。
struct FormLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: DmText.t12, weight: .medium))
            .foregroundColor(Color.dmInk2)
    }
}

/// 分段控件：互斥切换（连接页的 QuickConnect / 直连地址、曲库的浏览维度）。
///
/// 形态基准 = 投资监控的 `SegmentedTabs` —— 跨端落点表里这个组件唯一的实装，
/// 逐项对齐：容器与段同高（控件默认档 28）、容器与段都取 `r-6`（第七节
/// 「分段 Tab 底」那一档），`panel-2` 底 + `line-2` 1px 描边，**段间不留缝、
/// 容器不留内边距**，选中段的圆角与容器圆角同心。
///
/// 选中态取 `accent-fill` 实心底 + `on-accent` 字：这是**深字方案两端**
/// （本 app 与投资监控）的口径。第八节四态表那条「选中取下一档
/// `accent-fill-2`」是给白字方案写的 —— 对白字是「取更深一档」，本方案里
/// `fill2` 比 `fill` 更亮，方向反了，不套用。
struct DmSegmented<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item
    @State private var hovered: Item?

    init(_ items: [Item], selection: Binding<Item>, label: @escaping (Item) -> String) {
        self.items = items
        self._selection = selection
        self.label = label
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selection
                Button {
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.system(size: DmText.t12, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .foregroundColor(
                            isSelected ? Color.dmOnAccent
                                       : (hovered == item ? Color.dmInk : Color.dmInk2)
                        )
                        .padding(.horizontal, DmSpace.s16)
                        .frame(maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: DmRadius.r6)
                                .fill(Color.dmAccentFill)
                                .opacity(isSelected ? 1 : 0)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isInside in
                    if isInside {
                        hovered = item
                    } else if hovered == item {
                        hovered = nil
                    }
                }
            }
        }
        .frame(height: DmControl.h28)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r6).fill(Color.dmPanel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r6)
                .stroke(Color.dmLine2, lineWidth: DmLine.base)
        )
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r6))
    }
}

/// 通用开关：形态基准 42×24（三端统一）。关态轨道 `line-2`、开态 `accent-fill`；
/// 滑块直径 20 白色、行程 18。NAS 是深字方案，开态滑块仍取白色 —— 白滑块压
/// sky-500 是 2.71:1，只作图形看，非文本门槛 3:1 略有不及；下一批按像素实测
/// 核定（若不够，滑块改 `neutral.950`）。
struct DmToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            Capsule(style: .continuous)
                .fill(configuration.isOn ? Color.dmAccentFill : Color.dmLine2)
                .frame(width: 42, height: 24)
                .overlay(
                    GeometryReader { geo in
                        Circle()
                            .fill(Color.dmPanel)
                            .frame(width: 20, height: 20)
                            .offset(
                                x: configuration.isOn ? geo.size.width - 22 : 2,
                                y: (geo.size.height - 20) / 2
                            )
                    }
                )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.easeInOut(duration: DmMotion.fast), value: configuration.isOn)
    }
}

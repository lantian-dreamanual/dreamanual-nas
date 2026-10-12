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

/// 选中 / 悬停的四态配色。
///
/// **侧栏行（大面积轨道）走实心主色底 + 白字** —— 全产品线统一形态。
/// 白字端两端取各自的 `accent-fill-2`（视频下载 red-700、密码管理 blue-700），
/// 本端是深字方案、小块控件用亮档 sky-500，所以大面积行另立一个角色
/// `accent-row` = 本族里能压住白字的最浅档（sky-700，5.86:1），字取
/// `on-accent-row`（白）。与视频下载 `SelectState.selected` 逐项同构。
///
/// 窗口失焦时底掉 `accent-soft`，**字不动** —— 与白字端同一条。深字端才需要连字一起换
/// （近黑压 soft 只有 1.36:1）；本端的行字本来就是白，掉到 soft 上是 13.89:1。
///
/// 本文件只落侧栏行这一条轨道。另外两条见 design-system.md 第八节「选中与悬停」：
/// 小块控件（分段段、主按钮、开关）走 `accent-fill` sky-500 + `on-accent` 近黑
/// （白字压 sky-500 只有 2.71:1，够不到 AA）；列表行（表行 / 树行 / 弹窗结果行）
/// 走浅底 `accent-soft` + `accent-2`，不做失焦降级，落码时另写，别拿这个 enum 套。
///
/// 产品线没有「选中 + 悬停」这一态 —— 选中直接盖过悬停，与四个老 app 的
/// `SelectState.of(isSelected:hovered:)` 同一条规矩，所以这里也不看 hovered。
enum SelectState {
    case normal
    case hovered
    case selected
    /// 选中但窗口失焦：底从实心 `accent-row` 掉回 `accent-soft`（暗强调底，亮度降一截、
    /// 轮廓还在），字保持白。别降成中性底：它与侧栏底亮度太近，选中行会直接隐身。
    case selectedInactive

    static func of(isSelected: Bool, hovered: Bool, windowActive: Bool = true) -> SelectState {
        if isSelected { return windowActive ? .selected : .selectedInactive }
        return hovered ? .hovered : .normal
    }

    var background: Color {
        switch self {
        case .normal: return .clear
        // 悬停取 `panel-3`（第八节四态表）。侧栏底是 `panel-2`，悬停再用
        // `panel-2` 会与底同色、画出隐身 —— 亮一档的那一格是 `panel-3`。
        case .hovered: return .dmPanel3
        case .selected: return .dmAccentRow
        case .selectedInactive: return .dmAccentSoft
        }
    }

    var foreground: Color {
        switch self {
        case .normal: return .dmInk2
        case .hovered: return .dmInk
        case .selected, .selectedInactive: return .dmOnAccentRow
        }
    }
}

/// 列表行的选中档 —— **浅底轨**（design-system.md 第八节「选中与悬停」的取档表）。
///
/// 数据表行、目录树行、弹窗结果行走这一档：选中 `accent-soft` 底 + `accent-2` 字，
/// 次要格 `accent`。与侧栏行的实心主色底 + 白字（`SelectState`）**分轨** ——
/// 侧栏总共三四行、选中行表达「你在哪个模块」；列表行一屏几十上百行，
/// 多选时还会成片连成色带。落点先例是密码管理 `.item.on`。
///
/// 这一类行**不做失焦降级**：`accent-soft` 本身就是深字端的失焦目标档，
/// 选中与失焦是同一个样（取档的已知项，不当漂移处理）。
enum ListRowState {
    /// 底：选中 `accent-soft`；悬停 `panel-2` —— 列表挂在 `panel` 上，
    /// 悬停抬一档，与侧栏行悬停取 `panel-3` 是同一条「所在面相邻一档」。
    static func background(isSelected: Bool = false, hovered: Bool = false) -> Color {
        if isSelected { return Color.dmAccentSoft }
        return hovered ? Color.dmPanel2 : Color.clear
    }

    /// 正文格（艺术家、专辑）。
    static func foreground(isSelected: Bool = false, hovered: Bool = false) -> Color {
        if isSelected { return Color.dmAccent2 }
        return hovered ? Color.dmInk : Color.dmInk2
    }

    /// 标题格：常态就压 `ink` —— 它是这一行的主键，比别的格重一档。
    static func primaryForeground(isSelected: Bool = false) -> Color {
        isSelected ? Color.dmAccent2 : Color.dmInk
    }

    /// 次要格（流派、年份、时长、曲序）：常态 `ink-3`；选中时也压在主色底上，
    /// 取比正文低一档的 `accent`，与 `accent-2` 拉开层次。
    static func secondaryForeground(isSelected: Bool = false, hovered: Bool = false) -> Color {
        if isSelected { return Color.dmAccent }
        return hovered ? Color.dmInk : Color.dmInk3
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

/// 内容卡片（第八节「卡片」）：底 `panel-2`、圆角 `r-12`、`line-2` 0.5px 描边。
/// 内边距不在这里 —— 内容卡片 `s14`、列表卡片 `0`（内容按行排，行自带内边距），
/// 由调用点按角色给。
private struct ContentCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r12).fill(Color.dmPanel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r12)
                    .strokeBorder(Color.dmLine2, lineWidth: DmLine.hairline)
            )
    }
}

extension View {
    func dmCard() -> some View {
        modifier(ContentCardModifier())
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

/// 控件所在的面 ——「所在面相邻一档」取色的入参（第八节「输入框」与「卡片」）。
/// 主区（`panel`）/ 侧栏（`panel-2`）上的控件取 `panel-2`；卡片（`panel-2`）内的
/// 控件抬到 `panel-3` —— 不抬的话控件底与卡面同色，只剩描边可辨
/// （密码管理 `.modal .inp` / `.lock-card .inp` 同一条规矩）。
enum DmSurface {
    case panel
    case card

    var controlFill: Color {
        switch self {
        case .panel: return .dmPanel2
        case .card: return .dmPanel3
        }
    }
}

/// 品牌标记：应用图标位的占位件。两档 —— 侧栏品牌区 26（圆角 `r-8`、图形 14）、
/// 连接页 48（圆角 `r-12`、图形 24），几何与密码管理 `.lock-mark` 同。
///
/// 底走强调色渐变、图形取 `on-accent`（深字方案）。§十 的 App 图标定稿后，
/// 这里换成图标原图 —— 视频下载与密码管理的品牌位都是直接放图标原图，
/// 换图标时窗口跟着换，不再描一份。
struct DmBrandMark: View {
    let size: CGFloat

    private var radius: CGFloat { size >= 48 ? DmRadius.r12 : DmRadius.r8 }
    private var glyph: CGFloat { size >= 48 ? DmIcon.i24 : DmIcon.i14 }

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(
                LinearGradient(
                    colors: [Color.dmAccentFill2, Color.dmAccentFill],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                LucideIcon("server", size: glyph)
                    .foregroundColor(Color.dmOnAccent)
            )
    }
}

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
/// 聚焦时描边转 `accent-2`（浅档）；底色按所在面取（`formField(on:)`）。
/// 名字不带 `dm` 前缀 —— 那是生成令牌的命名空间，门禁按它对账。
private struct FormFieldModifier: ViewModifier {
    let surface: DmSurface

    @Environment(\.isFocused) private var envFocused

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: DmText.t13))
            .foregroundStyle(Color.dmInk)
            .padding(.horizontal, DmSpace.s12)
            .frame(height: DmControl.h38)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r8).fill(surface.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .strokeBorder(envFocused ? Color.dmAccent2 : Color.dmLine2, lineWidth: DmLine.base)
            )
    }
}

extension View {
    func formField(on surface: DmSurface = .panel) -> some View {
        modifier(FormFieldModifier(surface: surface))
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
/// 形态基准 = **内边距形态**（2026-10-12 用户拍板转正，见 design-system.md
/// 第八节「分段控件」）：容器 `panel-2` 底 + `line-2` 发丝描边 + `r-8`（控件档）
/// + 内边距 2；段高钉控件档 28、圆角 `r-6`、段间距 2，选中段实心 `accent-fill`
/// + `on-accent` 字。实心块四周透气、圆角读得更清楚，取代投资监控 2026-10-09
/// 的无缝形态（那版是为了治「纵向 padding 撑高随字体漂」，把段高钉档保留了，
/// 钉的对象从容器改成段）。
///
/// 选中态取 `accent-fill` 实心底 + `on-accent` 字：这是**小块控件轨道**（本 app 与
/// 投资监控）的口径。第八节取档表里那条「大面积选中行取 700 档 + 白字」是给侧栏行 /
/// 列表行写的 —— 分段是小块，取本端 fill 档；白字压 sky-500 只有 2.71:1，所以这里
/// 压近黑。
///
/// **失焦降级**：窗口不是 key 时，选中段从「亮实心 + 近黑字」切到「暗强调底 + 亮字」
/// （`accent-soft` + `accent-2`，6.37:1），与投资监控 `SegmentedTabs` 同款。深字方案
/// 不能照搬白字端那条「字保持」——近黑压 `accent-soft` 只有 1.36:1，字会看不见，
/// 必须连字一起换（第八节「两条轨道」）。本 app 只有主窗口一个，不过滤通知来源。
struct DmSegmented<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item
    /// 段是否等宽撑满容器。表单里的互斥切换（连接方式）取 true —— 与投资监控
    /// 主 Tab 同形态；跟随内容宽度时留默认 false（如工具条上的小切换）。
    let fillsWidth: Bool
    /// 容器底色按所在面取（同输入框的「相邻一档」口径）。
    let surface: DmSurface
    @State private var hovered: Item?
    @State private var windowActive = true

    init(
        _ items: [Item],
        selection: Binding<Item>,
        fillsWidth: Bool = false,
        on surface: DmSurface = .panel,
        label: @escaping (Item) -> String
    ) {
        self.items = items
        self._selection = selection
        self.fillsWidth = fillsWidth
        self.surface = surface
        self.label = label
    }

    var body: some View {
        HStack(spacing: DmSpace.s2) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selection
                Button {
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.system(size: DmText.t12, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .foregroundColor(
                            isSelected ? (windowActive ? Color.dmOnAccent : Color.dmAccent2)
                                       : (hovered == item ? Color.dmInk : Color.dmInk2)
                        )
                        .padding(.horizontal, DmSpace.s12)
                        .frame(height: DmControl.h28)
                        .frame(maxWidth: fillsWidth ? .infinity : nil)
                        .background(
                            RoundedRectangle(cornerRadius: DmRadius.r6)
                                .fill(windowActive ? Color.dmAccentFill : Color.dmAccentSoft)
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
        .padding(DmSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r8).fill(surface.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r8)
                .strokeBorder(Color.dmLine2, lineWidth: DmLine.hairline)
        )
        // 窗口 key 状态（第八节「两条轨道」的失焦降级）。与投资监控 `SegmentedTabs`
        // 同款：只订本进程的通知，不过滤 object —— NAS 只有主窗口一个。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            windowActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            windowActive = false
        }
    }
}

/// 通用开关：形态基准 42×24（四端统一，第八节「开关」）。关态轨道 `line-2`、
/// 开态 `accent-fill`；滑块直径 20、行程 18、**两态都白**。
///
/// 滑块取色跟轨道分道会让同一控件在两端出现两种滑块色，四条端并列时太显眼，
/// 所以四端一律白。白滑块压本端开态轨道 sky-500 是 2.71:1，低于非文本门槛 3:1
/// —— 四端里唯一不到门的一格，2026-10-12 拍板取白，读数在规范里留档。
/// 与投资监控 `DmToggleStyle` 逐字同构。
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
                            .fill(Color.white)
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

/// 图标按钮：28×28 方形 / 圆角 `r-6` / 图形 12 / 悬停 `panel-3` 底 + `ink` 字，
/// 禁用原样整体压暗 0.5。**逐字复刻投资监控 `IconButton`** —— 那不是它的私有件，
/// 是产品线里这个组件的落点，页头动作、面板角落都该用它，别的端不必另立形态。
struct IconButton: View {
    let iconName: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            LucideIcon(iconName, size: DmIcon.i12)
                .foregroundColor(isHovered && isEnabled ? Color.dmInk : Color.dmInk2)
                .frame(width: DmControl.h28, height: DmControl.h28)
                .background(
                    RoundedRectangle(cornerRadius: DmRadius.r6)
                        .fill(isHovered && isEnabled ? Color.dmPanel3 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
    }
}

/// 搜索框：高钉控件档 32、圆角 `r-8`、底按所在面取相邻一档、`line-2` 1px 描边；
/// 左侧放大镜 14（`ink-3`），横向内边距 12、图标与输入之间 8；聚焦只转描边
/// （`accent-2`）、底色不动；有内容时右侧出清除钮。宽度由调用点给
/// （曲库 280、文件管理 200）。
///
/// 形态照原型 `.searchbox`。产品线里这是第一个搜索框 —— 另四端都没有这个场景，
/// 没有可复刻的落点，规格先落在本端。
struct DmSearchField: View {
    @Binding private var text: String
    private let placeholder: String
    private let surface: DmSurface
    private let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    init(
        text: Binding<String>,
        placeholder: String,
        surface: DmSurface = .panel,
        onSubmit: @escaping () -> Void = {}
    ) {
        self._text = text
        self.placeholder = placeholder
        self.surface = surface
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon("search", size: DmIcon.i14)
                .foregroundColor(Color.dmInk3)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: DmText.t13))
                .foregroundColor(Color.dmInk)
                .focused($isFocused)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit()
                } label: {
                    LucideIcon("circle-x", size: DmIcon.i14)
                        .foregroundColor(Color.dmInk3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DmSpace.s12)
        .frame(height: DmControl.h32)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r8).fill(surface.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r8)
                .strokeBorder(isFocused ? Color.dmAccent2 : Color.dmLine2, lineWidth: DmLine.base)
        )
    }
}

/// 页头：标题 17/semibold/字距 -0.01em，副行 12/`ink-3`（题头与副行间距 4），
/// 右侧动作区右对齐（两块之间 16）；内边距 20/24/12。
///
/// 规格抄原型 `.page-head` / `.page-title` / `.page-sub`。四个模块都用它 ——
/// 页头是页面模板的一部分，不是各页各画一条。
struct DmPageHead<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: DmSpace.s16) {
            VStack(alignment: .leading, spacing: DmSpace.s4) {
                Text(title)
                    .font(.system(size: DmText.t17, weight: .semibold))
                    .kerning(-0.17)
                    .foregroundColor(Color.dmInk)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: DmText.t12))
                        .foregroundColor(Color.dmInk3)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: DmSpace.s6) {
                trailing
            }
        }
        .padding(.top, DmSpace.s20)
        .padding(.horizontal, DmSpace.s24)
        .padding(.bottom, DmSpace.s12)
    }
}

extension DmPageHead where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

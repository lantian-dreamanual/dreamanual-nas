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
    /// 实心态（原型 `data-fill="1"`）：评分星用得到，空星描边、实心星充满。
    var filled: Bool = false

    init(_ name: String, size: CGFloat, filled: Bool = false) {
        self.name = name
        self.size = size
        self.filled = filled
    }

    var body: some View {
        Group {
            if let image = NSImage(named: filled ? "lucide-\(name)-fill" : "lucide-\(name)") {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: Self.symbol(for: name, filled: filled))
                    .font(.system(size: size * 0.9, weight: .regular))
                    .frame(width: size, height: size)
                    // 竖排三点：SF 没有竖省略号，横排转 90° —— 形态照原型
                    // lucide `more-vertical`。ⓘ 这条曾经写的是 `ellipsis.vertical`，
                    // 那个名字在 SF Symbols 里不存在，真机上画的是空气（2026-10-13
                    // 抓到：表头最右一格看着是空的，点不了）。
                    .rotationEffect(.degrees(name == "more-vertical" ? 90 : 0))
            }
        }
    }

    /// 兜底符号：实心态在原名后接 `.fill`（已是 `.fill` 的不再叠）。
    private static func symbol(for name: String, filled: Bool) -> String {
        let base = symbolFallback[name] ?? "questionmark"
        guard filled, !base.hasSuffix(".fill") else { return base }
        return "\(base).fill"
    }

    private static let symbolFallback: [String: String] = [
        "headphones": "headphones",
        "folder": "folder",
        "folder-open": "folder",
        "gauge": "gauge.medium",
        "settings": "gearshape",
        "music": "music.note",
        "sparkles": "sparkles",
        "server": "externaldrive.connected.to.line.below",
        // 状态栏离线态（2026-10-16）。`server-off` 的斜杠 SF 没有同构画法，
        // 取语义同族的外接盘 + × 徽章（名字逐个问过 NSImage，存在）。
        "server-off": "externaldrive.badge.xmark",
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
        "info": "info.circle",
        "x": "xmark",
        // 表头排序与字段配置这几枚（2026-10-13 补）。⚠️ `chevron-down` 是**补漏**：
        // 分页那一行早就用了它、表里却一直没有，真机上画的是问号 —— 门禁不管
        // 图标名，只有截图能抓到，所以加图标时顺手扫一遍「用过 vs 表里有」。
        "check": "checkmark",
        "chevron-up": "chevron.up",
        "chevron-down": "chevron.down",
        // ⚠️ `more-vertical` 兜底取 `ellipsis` 再转 90°（见 body）—— SF 没有
        // `ellipsis.vertical`，写那个名字真机上就是空气。
        "more-vertical": "ellipsis",
        "rotate-ccw": "arrow.counterclockwise",
        "triangle-alert": "exclamationmark.triangle",
        "wifi": "wifi",
        "key-round": "key",
        "link": "link",
        "refresh-cw": "arrow.clockwise",
        // 歌曲右键菜单那几枚（2026-10-13）。`play` / `star` 播放条与评分星早就在用。
        "list-start": "text.insert",
        "download": "arrow.down.circle",
        "trash": "trash",
        // 表头拖动手柄（2026-10-14）。⚠️ SF 里**没有** `grip` 与 2×3 的点阵
        // （`grip` / `circle.grid.2x3` / `dot.grid.2x3` 三个名字逐个核过，都不存在）。
        // 取语义同族的 `line.3.horizontal`（macOS 列表重排手柄的画法）。
        "grip-vertical": "line.3.horizontal",
        // 文件管理（2026-10-14）。十枚逐个问过 `NSImage(systemSymbolName:)`，
        // 全部存在（`folder.open` 才是那个不存在的名字，`folder-open` 早年已兜到
        // `folder`）。类型图标按 `additional.type` 分派，文件类型不止「文档」一种，
        // 全压同一个图形等于没分。
        "file": "doc",
        "file-text": "doc.text",
        "file-audio": "waveform",
        "file-image": "photo",
        "file-video": "film",
        "file-archive": "doc.zipper",
        "chevron-right": "chevron.right",
        "house": "house",
        // 写操作那一批（2026-10-14）。`minus` 是勾选框半选态的图形；另三枚给
        // 工具条与弹窗（新建文件夹 / 重命名）。上传与复制/移动到在下一批，图标名
        // 先备在这里 —— 名字逐个问过 `NSImage(systemSymbolName:)`，省得届时漏兜底画空气。
        "minus": "minus",
        "folder-plus": "folder.badge.plus",
        "pencil": "pencil",
        "upload": "square.and.arrow.up",
        "copy": "doc.on.doc",
        "folder-input": "arrow.right.square",
        // 目录大小那一批（2026-10-14）。「量一下这个文件夹多大」——`ruler` 是量尺寸的
        // 意象，逐个问过 `NSImage(systemSymbolName:)` 确实存在（`sum` 也在，
        // 但它是求和的符号，用在单条上不准）。取消计算复用 `circle-x`。
        "ruler": "ruler",
        // 系统状态页那一批（2026-10-14）。五枚逐个问过 `NSImage(systemSymbolName:)`：
        // `thermometer` / `cpu` / `memorychip` / `clock` / `internaldrive` 都在
        // （`cpu` 与 `memorychip` 是 SF 的原生名，别再试 `chip` / `ram`）。
        // `hard-drive` 走 `internaldrive`：机器里那两块是内置盘，不是外置盒。
        "thermometer": "thermometer",
        "cpu": "cpu",
        "memory-stick": "memorychip",
        "clock": "clock",
        "hard-drive": "internaldrive",
        // 开关机计划那一批（2026-10-17）。`calendar.badge.clock` 问过
        // `NSImage(systemSymbolName:)` 确实存在（`calendar.day.timeline.left` 也在，
        // 但它画的是时间轴，取的是另一件事的意象）。
        "calendar-clock": "calendar.badge.clock",
        // 赞赏入口（2026-10-17）。`cup.and.saucer` 问过 `NSImage(systemSymbolName:)`
        // 存在（`mug` / `cup` 都不存在，别试）。
        "coffee": "cup.and.saucer",
        // 歌单写入这一批（2026-10-17）。两个名字逐个问过 `NSImage(systemSymbolName:)`：
        // `plus` 是 SF 原生名；`list-plus` SF 没有，取「插进列表」的意象
        // `text.badge.plus`，与 `list-start` 取 `text.insert` 同族。
        "plus": "plus",
        "list-plus": "text.badge.plus",
    ]
}

// ============ 评分 ============

/// 星级条的节距：星 10px + 视觉间距 2px。点到的最小宽度靠它。
private let ratingPitch: CGFloat = 12

/// 评分（0–5）：5 颗 10px 星，实心主色 `accent-2`、空星中性 `ink-3`。
///
/// **未评分整格留空**（没悬停时整体隐身）—— 不铺一列空星：曲库一屏上百行、
/// 绝大多数是 0 分，满屏空星只是噪声。`revealsEmpty` 就是原型 `.rate.ghost`
/// 那条「悬停该行才浮出空星」—— 浮出来即「这一格能点」。
///
/// 给了 `onRate` 就变可点：点第 n 颗 = n 星；已是 n 星再点第 n 颗 = 清零。
/// 悬停到第 n 颗时左侧同亮做预览。
struct RatingStars: View {
    let rating: Int
    /// 选中行：空星跟着正文走 `accent`，实心星仍取 `accent-2`。
    var isSelected: Bool = false
    /// 未评分时是否铺出空星（列表行悬停该行才亮）。
    var revealsEmpty: Bool = false
    /// 给了就是可点态，参数是点中的那一档。
    var onRate: ((Int) -> Void)?

    @State private var hoverIndex = 0

    /// 亮到第几颗：悬停时按悬停位（预览），否则按真实评分。
    private var litCount: Int { hoverIndex > 0 ? hoverIndex : rating }
    private var isVisible: Bool { rating > 0 || revealsEmpty || hoverIndex > 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { index in
                star(index)
            }
        }
        .contentShape(Rectangle())
        .modifier(RatingHover(isInteractive: onRate != nil, hoverIndex: $hoverIndex))
        .opacity(isVisible ? 1 : 0)
        .accessibilityLabel(rating > 0 ? "评分 \(rating) 星" : "未评分")
    }

    @ViewBuilder
    private func star(_ index: Int) -> some View {
        let icon = LucideIcon("star", size: DmIcon.i10, filled: index <= litCount)
            .foregroundColor(color(filled: index <= litCount))
            .frame(width: ratingPitch, height: DmIcon.i14)

        if let onRate {
            Button {
                onRate(rating == index ? 0 : index)
            } label: {
                icon
            }
            .buttonStyle(.plain)
        } else {
            icon
        }
    }

    private func color(filled: Bool) -> Color {
        if filled { return Color.dmAccent2 }
        return isSelected ? Color.dmAccent : Color.dmInk3
    }
}

/// 星级条的悬停预览。整条只留**一个**悬停源、按横坐标换算档位 —— 每颗星各自
/// 挂 `onHover` 时，相邻两星的进入 / 离开回调次序不定，预览会闪。
private struct RatingHover: ViewModifier {
    let isInteractive: Bool
    @Binding var hoverIndex: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if isInteractive {
            content.onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let index = Int(point.x / ratingPitch) + 1
                    hoverIndex = max(1, min(5, index))
                case .ended:
                    hoverIndex = 0
                }
            }
        } else {
            content
        }
    }
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

/// 品牌标记：直接放图标原图（brand.svg 进 bundle，AppKit 原生读 SVG）。
/// 两档 —— 侧栏品牌区 26（圆角 `r-8`）、连接页 48（圆角 `r-12`），
/// 几何与密码管理 `.lock-mark` 同。换图标只动 Resources/brand.svg + AppIcon.icns。
struct DmBrandMark: View {
    let size: CGFloat

    private var radius: CGFloat { size >= 48 ? DmRadius.r12 : DmRadius.r8 }

    private var artwork: NSImage? {
        guard let url = Bundle.main.url(forResource: "brand", withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        Group {
            if let image = artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                // bundle 里缺资源时退回强调色实底，不至于白块。
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.dmAccentFill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
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
///
/// `on:` 按落点分两档。面板档（`panel` 底）是实底；卡面档改**纯描边**：
/// 卡面（`dmCard()` / 设置分组卡）是 `panel-2`，同卡里的输入框 `formFieldRow()`
/// 已经是 `panel-3` 实底 —— 按钮若也做实底 `panel-3`，两个壳同色同描边，只差
/// 4px 高与 1 号字，读起来像同一控件的两种尺寸（2026-10-17 用户追问「是否造成
/// 认知负担」）。描边把语言分开：**实底＝可输入、描边＝可点**，悬停才填底。
/// 描边取 `line-2`（`#404040`）—— 面板档的 `line` 与卡面同色，画在卡上等于没画
/// （2026-10-17 用户反馈「按钮看着不明显，不像是按钮」就是这一条）。
struct SecondaryButtonStyle: ButtonStyle {
    /// 落点：`.panel` 主区 / 弹窗（底色 `panel`），`.card` 卡面（`panel-2`）。
    var on: DmSurface = .panel

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
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r6)
                    .strokeBorder(stroke, lineWidth: DmLine.base)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .onHover { isHovered = $0 }
    }

    /// 卡面档常态透明、悬停才填 `panel-3`：`panel-3` 是面板梯度最亮一档，
    /// 没有更亮的底可换，换更暗会读成「已按下」。
    private var fill: Color {
        switch on {
        case .panel: return isEnabled && isHovered ? Color.dmPanel3 : Color.dmPanel2
        case .card: return isEnabled && isHovered ? Color.dmPanel3 : Color.clear
        }
    }

    private var stroke: Color {
        on == .panel ? Color.dmLine : Color.dmLine2
    }
}

/// 输入框外壳：表单规格（高 38 / 圆角 8 / 字号 13），横向内边距 12。
/// 聚焦时描边转 `accent-2`（浅档）；底色按所在面取（`formField(on:)`）。
/// 名字不带 `dm` 前缀 —— 那是生成令牌的命名空间，门禁按它对账。
private struct FormFieldModifier: ViewModifier {
    let surface: DmSurface
    /// 设置行内嵌档（2026-10-17）：高 32、底色恒 `panel-3`。
    ///
    /// 设置分组卡本身就是 `panel-2`，嵌进去的控件不能再跟卡同底 —— 第八节
    /// 「设置行内嵌控件」那条统一定档：32 / 字 13 / `panel-3` / `line-2` 描边 / `r-8`。
    /// 与四端的 `DmTextField`（video）/ `FormTextField(rowInline:)`（invest）同一档。
    let rowInline: Bool

    @Environment(\.isFocused) private var envFocused

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: DmText.t13))
            .foregroundStyle(Color.dmInk)
            .padding(.horizontal, DmSpace.s12)
            .frame(height: rowInline ? DmControl.h32 : DmControl.h38)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .fill(rowInline ? Color.dmPanel3 : surface.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .strokeBorder(envFocused ? Color.dmAccent2 : Color.dmLine2, lineWidth: DmLine.base)
            )
    }
}

extension View {
    func formField(on surface: DmSurface = .panel) -> some View {
        modifier(FormFieldModifier(surface: surface, rowInline: false))
    }

    /// 设置页行内嵌的输入框：32 档、`panel-3` 底。
    func formFieldRow() -> some View {
        modifier(FormFieldModifier(surface: .card, rowInline: true))
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

// ============ 设置页 ============

/// 设置分组：组标题在**卡片外**（11 / 700 / `ink-3` / 0.08em 字距），卡面
/// `panel-2` 底、`r-8`、**无描边**（`line` 与 `panel-2` 同色，只靠底色与主区
/// `panel` 分层）—— 第八节「设置分组卡」第三个变体，与 video `SettingsGroupCard`、
/// vault `.srow` 一组（2026-10-09 定）。主区里那些 `line-2` 描边的列表卡是另一族。
///
/// 内容收进 `alignment: .leading` 的零间距 VStack：不给 leading 的话，说明文字
/// 这类贴内容宽的块会被卡片居中（video 端出图实抓过）。
struct DmSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DmSpace.s8) {
            Text(title)
                .font(.system(size: DmText.t11, weight: .bold))
                .kerning(0.8)
                .foregroundColor(Color.dmInk3)
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DmRadius.r8).fill(Color.dmPanel2)
                )
        }
    }
}

/// 设置行：标签左、控件右，内边距 12/14（与密码管理 `.srow` 同档）。
struct DmSettingsRow<Content: View>: View {
    let label: String
    /// 附注：解释这一行，跟着行走、不被当成独立段落（2026-10-17 用户定）。
    let note: String?
    /// 附注是警告时取 `danger-ink` —— 只换颜色，位置与字号不动，避免跳版。
    let noteIsWarning: Bool
    @ViewBuilder let control: () -> Content

    init(_ label: String,
         note: String? = nil,
         noteIsWarning: Bool = false,
         @ViewBuilder control: @escaping () -> Content) {
        self.label = label
        self.note = note
        self.noteIsWarning = noteIsWarning
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DmSpace.s2) {
            HStack(spacing: DmSpace.s16) {
                Text(label)
                    .font(.system(size: DmText.t13))
                    .foregroundColor(Color.dmInk)
                Spacer(minLength: 0)
                control()
            }
            if let note {
                Text(note)
                    .font(.system(size: DmText.t12))
                    .foregroundColor(noteIsWarning ? Color.dmDangerInk : Color.dmInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s12)
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
                            // 贴地投影（`DmShadow.knob`）：白滑块压在亮色轨道上靠它托出轮廓。
                            .dmShadowKnob()
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
///
/// `compact` 是**密集行小档**（22×22）：只给行高 ≤ 30 的密集行用 —— 表头最右的
/// 字段配置、侧栏小节头的「+」（原型 `.tbl th.th-cfg .icon-btn` 与
/// `.mside-head .icon-btn` 两处都是 22）。常规位置一律 28：这个档存在的理由是
/// 「表头行高只有 29，28 的按钮在里面显得顶」，不是「图标按钮有两种尺寸」。
/// 图形仍取 12，不随框缩 —— 22 的框配 12 的图形，与 28 档是同一个比例。
struct IconButton: View {
    let iconName: String
    var compact: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            LucideIcon(iconName, size: DmIcon.i12)
                .foregroundColor(isHovered && isEnabled ? Color.dmInk : Color.dmInk2)
                .frame(width: side, height: side)
                .background(
                    RoundedRectangle(cornerRadius: DmRadius.r6)
                        .fill(isHovered && isEnabled ? Color.dmPanel3 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
    }

    private var side: CGFloat { compact ? 22 : DmControl.h28 }
}

/// 勾选框（原型 `.cb`）：14×14 / 圆角 `r-4` / `line-2` 1px 描边 / 底 `panel-2`；
/// 勾选 = `accent-fill` 实底 + `on-accent` 勾；未勾悬停描边转 `ink-2`。
///
/// **半选态**（`isIndeterminate`，原型 `.cb.ind`）：底与勾选态同款，图形换 `minus`
/// —— 用在表头全选位（一部分选中）。半选与勾选**互斥**，同时给只认半选。
///
/// **禁用勾选态**（`isDisabled && isOn`）：底 `line-2` + 勾取 `ink-3` —— 用在
/// 「选了但不能改」的地方，表头字段配置里的标题列（主键列，不可隐藏）就是这一态。
/// 禁用未勾是 `panel` 底 + `line` 描边，比常态更沉一档。
struct DmCheckbox: View {
    let isOn: Bool
    var isDisabled: Bool = false
    /// 半选（表头全选位）。与 `isOn` 互斥，同时给时只认半选。
    var isIndeterminate: Bool = false

    @State private var isHovered = false

    /// 实底（勾选或半选）。
    private var isFilled: Bool { isOn || isIndeterminate }

    var body: some View {
        RoundedRectangle(cornerRadius: DmRadius.r4)
            .fill(fill)
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: DmRadius.r4)
                        .strokeBorder(border, lineWidth: DmLine.base)
                }
            }
            .overlay {
                if isFilled {
                    LucideIcon(isIndeterminate ? "minus" : "check", size: DmIcon.i10)
                        .foregroundColor(isDisabled ? Color.dmInk3 : Color.dmOnAccent)
                }
            }
            .frame(width: 14, height: 14)
            .onHover { isHovered = $0 && !isDisabled }
    }

    private var fill: Color {
        if isFilled { return isDisabled ? Color.dmLine2 : Color.dmAccentFill }
        return isDisabled ? Color.dmPanel : Color.dmPanel2
    }

    /// 实底就不画描边（自己成形）。未勾时：禁用 `line`、悬停 `ink-2`、常态 `line-2`。
    private var border: Color? {
        guard !isFilled else { return nil }
        if isDisabled { return Color.dmLine }
        return isHovered ? Color.dmInk2 : Color.dmLine2
    }
}

// ============ 弹窗与写操作 ============

/// 弹窗遮罩层：半透明黑铺满 + 居中卡片，点遮罩关。
///
/// 用法：`.dmModal(isPresented:onDismiss:) { 卡片 }`，**挂在铺满窗口的视图上**
/// （NAS 挂 `RootView` 根）—— 挂在某个区块里，遮罩就只盖住那块。
/// 与投资监控 `DmModal` 同构（那边宿主是菜单栏小面板，只有居中那一圈）。
struct DmModal<Modal: View>: ViewModifier {
    let isPresented: Bool
    let onDismiss: () -> Void
    @ViewBuilder let modal: () -> Modal

    func body(content: Content) -> some View {
        ZStack {
            content
            if isPresented {
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                modal()
                    .padding(DmSpace.s24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: DmMotion.fast), value: isPresented)
    }
}

extension View {
    func dmModal<Modal: View>(
        isPresented: Bool,
        onDismiss: @escaping () -> Void,
        @ViewBuilder modal: @escaping () -> Modal
    ) -> some View {
        modifier(DmModal(isPresented: isPresented, onDismiss: onDismiss, modal: modal))
    }
}

/// 三段卡片：head（标题 + 关闭钮）/ body（可滚动）/ foot（动作右对齐）。
/// 底 `panel`、描边 `line` 1px、圆角 `r16`、阴影 `shadow-modal`、宽 **470**。
///
/// 470 是第八节弹窗口径给**标准窗口**的尺寸，NAS 按满值取；投资监控那份收到 368
/// 是菜单栏小面板的宿主差异（规范十三节记着），别拿那一版覆盖这里。
struct DmModalCard<Content: View, Foot: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let foot: () -> Foot
    /// 脚部最左侧那一块（原型 `.foot-cb`）—— 冲突弹窗的「应用于全部 N 项」用它。
    ///
    /// 它是**作用域开关**，与右边那几个按钮不是一类东西，所以贴左边、隔着一段空白；
    /// 传 `AnyView` 是为了不把泛型再摊一层（这一个槽位不值得改所有调用点）。
    var lead: AnyView?

    @State private var bodyHeight: CGFloat = 0

    /// body 内容高超过这个数就内部滚（卡片总高约 560，比多数窗口扣掉 s24 遮罩边距后仍有余量）。
    private var bodyCap: CGFloat { 420 }

    /// 弹窗卡宽（第八节：自绘卡片 470）。
    static var width: CGFloat { 470 }

    var body: some View {
        VStack(spacing: 0) {
            head
            body_
            foot_
        }
        .frame(width: Self.width)
        .background(Color.dmPanel)
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r16)
                .strokeBorder(Color.dmLine, lineWidth: DmLine.base)
        )
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r16))
        .dmShadowModal()
    }

    /// head：纵向 `s16` / 横向 `s20`，标题 15 semibold，右上角关闭钮（图形 12）。
    private var head: some View {
        HStack(spacing: DmSpace.s8) {
            Text(title)
                .font(.system(size: DmText.t15, weight: .semibold))
                .foregroundColor(Color.dmInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            IconButton(iconName: "x", action: onClose)
        }
        .padding(.vertical, DmSpace.s16)
        .padding(.horizontal, DmSpace.s20)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.base)
        }
    }

    /// body：`s20`（下方 `s6`），**高度贴内容**（量出来多少给多少），超过 `bodyCap` 内部滚。
    /// ScrollView 会吞掉全部提议高度，不量着钉住就会把弹窗撑满整窗。
    private var body_: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DmSpace.s12) {
                content()
            }
            .padding(.top, DmSpace.s20)
            .padding(.bottom, DmSpace.s6)
            .padding(.horizontal, DmSpace.s20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ModalBodyHeightKey.self, value: geo.size.height)
                }
            )
        }
        .frame(height: bodyHeight > 0 ? min(bodyHeight, bodyCap) : nil)
        .onPreferenceChange(ModalBodyHeightKey.self) { bodyHeight = $0 }
    }

    /// foot：上 `s14` / 横向 `s20` / 下 `s16`，`lead` 贴左、动作右对齐、间距 `s8`。
    private var foot_: some View {
        HStack(spacing: DmSpace.s8) {
            if let lead {
                lead
            }
            Spacer(minLength: 0)
            foot()
        }
        .padding(.top, DmSpace.s14)
        .padding(.horizontal, DmSpace.s20)
        .padding(.bottom, DmSpace.s16)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.base)
        }
    }
}

/// body 内容高的测量键（DmModalCard 内部用）。
private struct ModalBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 危险按钮：框与主按钮同规格（高 38 / 内边距 16 / `r-8` / 字 13 / 500），
/// 配色走 danger 族 —— `danger-soft` 底 + `danger-ink` 字 + `danger-line` 1px 描边，
/// 悬停底转 `danger-hover`（原型 `.btn-danger`）。删除确认的确认钮用它。
///
/// 不用系统的 `role: .destructive`：那套走系统配色，与第八节的按钮规格对不上。
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DmText.t13, weight: .medium))
            .lineLimit(1)
            .foregroundColor(Color.dmDangerInk)
            .padding(.horizontal, DmSpace.s16)
            .frame(height: DmControl.h38)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .fill(isEnabled && isHovered ? Color.dmDangerHover : Color.dmDangerSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .strokeBorder(Color.dmDangerLine, lineWidth: DmLine.base)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .onHover { isHovered = $0 }
    }
}

/// 弹窗里的危险提示块（原型 `.banner-d`）：`danger-soft` 底 + `danger-ink` 字 + `r-10`，
/// 内边距 10/12，字 12、行高 1.6。
///
/// 删除确认里那条「不进回收站、无法恢复」用它 —— 那是硬约束，不是普通说明文字。
struct DmDangerNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DmSpace.s8) {
            LucideIcon("triangle-alert", size: DmIcon.i14)
                .foregroundColor(Color.dmDangerInk)
                // 图标 14、正文行高约 17：顶对齐后图标中心偏上，压 s2 补齐。
                .padding(.top, DmSpace.s2)
            Text(text)
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmDangerInk)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DmSpace.s12)
        .padding(.vertical, DmSpace.s10)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r10).fill(Color.dmDangerSoft)
        )
    }
}

/// 页内提醒条（原型 `.banner`）：`warn-soft` 底 + `warn-ink` 字、字 13、内边距 8/14、
/// **不带圆角**（通栏一条，压在内容区上沿）。用在「当前目录不可写」。
struct DmBanner: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon(icon, size: DmIcon.i16)
                .foregroundColor(Color.dmWarnInk)
            Text(text)
                .font(.system(size: DmText.t13))
                .foregroundColor(Color.dmWarnInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dmWarnSoft)
    }
}

/// 状态徽章（第八节「状态徽章与分类标签」）：底**统一 `panel-2` + `line-2` 发丝**、
/// 圆角 `r-6`、内边距纵向 `s2` 横向 `s6`、字 11/500。
///
/// 族色**只进文字与图标**，不铺自己的 `soft` 实色底 —— 族 500 压 soft 够不到 3:1，
/// 所以字的档取 `-ink-strong`（族 400）；中性态取 `ink-2`、强调态取 `accent-2`
/// （2026-10-09 用户定版）。高度不写死：`s2` 内边距 + 11 号字自然长出 18。
///
/// 落点先例：投资监控 `MarketStatusBadge` ↔ 音频转换 `FileStatusBadge` ↔
/// 密码管理 `.pill`。**NAS 这一端到系统状态页才第一次落**（此前一屏都没有徽章）。
struct DmBadge: View {
    /// 语气档：中性 / 正常（ok）/ 注意（warn）/ 异常（danger）/ 强调（accent）。
    enum Tone {
        case neutral, ok, warn, danger, accent

        var ink: Color {
            switch self {
            case .neutral: return Color.dmInk2
            case .ok: return Color.dmOkInkStrong
            case .warn: return Color.dmWarnInkStrong
            case .danger: return Color.dmDangerInkStrong
            case .accent: return Color.dmAccent2
            }
        }
    }

    private let text: String
    private let icon: String?
    private let tone: Tone

    init(_ text: String, icon: String? = nil, tone: Tone = .neutral) {
        self.text = text
        self.icon = icon
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: DmSpace.s4) {
            if let icon {
                LucideIcon(icon, size: DmIcon.i12)
                    .foregroundColor(tone.ink)
            }
            Text(text)
                .font(.system(size: DmText.t11, weight: .medium))
                .foregroundColor(tone.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, DmSpace.s6)
        .padding(.vertical, DmSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r6).fill(Color.dmPanel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r6)
                .stroke(Color.dmLine2, lineWidth: DmLine.hairline)
        )
    }
}

/// 清单（原型 `.pick-list`）：一层发丝描边的方框、内边距 4、行距 2，最高 180 自己滚。
/// 删除确认列被删的项，每行右侧给大小或「文件夹 · 含 N 项」。
struct DmPickList<Row: View>: View {
    @ViewBuilder let content: () -> Row

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: DmSpace.s2) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DmSpace.s4)
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r8)
                .strokeBorder(Color.dmLine, lineWidth: DmLine.hairline)
        )
        .frame(maxHeight: 180, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r8))
    }
}

/// 清单里的一行：图形 + 名字 + 右侧补充（原型 `.pick-list .row`）。
struct DmPickRow: View {
    let icon: String
    let title: String
    let note: String

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon(icon, size: DmIcon.i14)
                .foregroundColor(Color.dmInk3)
            Text(title)
                .font(.system(size: DmText.t13))
                .foregroundColor(Color.dmInk2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DmSpace.s8)
            Text(note)
                .font(.system(size: DmText.t11))
                .foregroundColor(Color.dmInk3)
                .lineLimit(1)
        }
        .padding(.horizontal, DmSpace.s8)
        .padding(.vertical, DmSpace.s6)
    }
}

// ============ 上传 ============

/// 进度条（原型 `.prog`）：轨道 `panel-3`、高 6、两头圆，已传部分实心 `accent`。
///
/// 圆角用 `Capsule` 而不是 `r-4`：6px 高的条要的是「两头全圆」的形态，
/// 档位表里最接近的 4 反而会露出四只直角。
struct DmProgressBar: View {
    /// 0…1，越界自己夹住（服务端给的总字节偶尔是 0，除法那一步在调用点挡掉了）。
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dmPanel3)
                Capsule()
                    .fill(Color.dmAccent)
                    .frame(width: geo.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: DmSpace.s6)
    }
}

/// 上传行的两档语气。**独立成一个类型**而不是 `DmUploadRow.Tone` —— 后者会把行视图
/// 按动作视图参数化，取语气的地方（视图里那个小函数）就得写明泛型参数。
enum DmUploadTone {
    case normal
    case danger
}

/// 上传行（原型 `.up-row`）：图标 + 标题 + 明细（速率 / 已传 / 剩余）+ 进度条 + 右侧动作。
///
/// **常驻在列表上方，不藏进弹窗** —— 上行 0.31 MB/s，传 50 MB 要两分半，
/// 进度和「取消」都得一直看得见。建目录那一步没有字节数，`progress` 给 nil 就只出文字。
struct DmUploadRow<Action: View>: View {
    let icon: String
    let title: String
    let detail: String
    var progress: Double?
    /// 失败那一档：标题转 `danger-ink-strong`（压 `panel-2` 够 3:1）。
    var tone: DmUploadTone = .normal
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: DmSpace.s12) {
            LucideIcon(icon, size: DmIcon.i16)
                .foregroundColor(tone == .danger ? Color.dmDangerInkStrong : Color.dmInk2)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: DmText.t13, weight: .medium))
                    .foregroundColor(tone == .danger ? Color.dmDangerInkStrong : Color.dmInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: DmText.t11))
                    .monospacedDigit()
                    .foregroundColor(Color.dmInk3)
                    .lineLimit(1)
                    .padding(.top, DmSpace.s2)
                if let progress {
                    DmProgressBar(value: progress)
                        .padding(.top, DmSpace.s8)
                }
            }
            action()
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s10)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r10).fill(Color.dmPanel2)
        )
    }
}

/// 冲突三选里的一行（原型 `.opt`）：单选圆点 + 标题 + 一句代价说明。
///
/// 选中态是 `accent-soft` 底 + `accent-line` 描边 —— 与「列表行选中」同一条轨道；
/// 圆点里那颗实心点取 `accent-2`（压在 `accent-soft` 上要够亮）。
struct DmOptionRow: View {
    let title: String
    let note: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DmSpace.s10) {
                DmRadio(isOn: isOn)
                VStack(alignment: .leading, spacing: DmSpace.s2) {
                    Text(title)
                        .font(.system(size: DmText.t13))
                        .foregroundColor(Color.dmInk)
                    Text(note)
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DmSpace.s12)
            .padding(.vertical, DmSpace.s10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .fill(isOn ? Color.dmAccentSoft : Color.dmPanel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .strokeBorder(
                        isOn ? Color.dmAccentLine : (isHovered ? Color.dmLine2 : Color.dmLine),
                        lineWidth: DmLine.hairline
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// 单选圆点（原型 `.radio`）：常态 14 空心描边，选中描边转 `accent-2` 并嵌一颗实心点。
struct DmRadio: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isOn ? Color.dmAccent2 : Color.dmLine2, lineWidth: DmLine.base)
            if isOn {
                Circle().fill(Color.dmAccent2).frame(width: DmSpace.s6, height: DmSpace.s6)
            }
        }
        .frame(width: 14, height: 14)
        // 与 13 字的第一行视觉对齐：圆点中心压在文字中线上，不是顶对齐。
        .padding(.top, DmSpace.s2)
    }
}

/// 「来源 / 目标已有」对照（原型 `.cmp`）：两块并排，各是「小标题 + 若干行值」。
struct DmCompare: View {
    let left: DmCompareColumn
    let right: DmCompareColumn

    var body: some View {
        HStack(alignment: .top, spacing: DmSpace.s16) {
            column(left)
            column(right)
        }
        .padding(.horizontal, DmSpace.s12)
        .padding(.vertical, DmSpace.s10)
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r8)
                .strokeBorder(Color.dmLine, lineWidth: DmLine.hairline)
        )
    }

    private func column(_ column: DmCompareColumn) -> some View {
        VStack(alignment: .leading, spacing: DmSpace.s4) {
            Text(column.title)
                .font(.system(size: DmText.t12, weight: .medium))
                .foregroundColor(Color.dmInk2)
            ForEach(column.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 对照块的一列。`lines` 第一行通常是名字，后面是大小与时间。
struct DmCompareColumn {
    let title: String
    let lines: [String]
}

// ============ 菜单 ============

/// 下拉菜单卡片（原型 `.menu`）：`panel-2` + `line-2` 发丝 + `r-10` + `shadow-modal`，
/// 内边距 4。右键菜单与表头字段配置共用这一套（第八节「菜单」，形态源自 video
/// `menuCard` / vault `.ctxmenu`）。宽度由调用点给（字段配置 196，min 160）。
struct DmMenuCard<Content: View>: View {
    var width: CGFloat?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(width: width, alignment: .leading)
        .padding(DmSpace.s4)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r10).fill(Color.dmPanel2)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DmRadius.r10)
                .strokeBorder(Color.dmLine2, lineWidth: DmLine.hairline)
        }
        .dmShadowModal()
    }
}

/// 菜单里的小节标题（原型 `.fg-title`）：11 / bold / 字距 .06em / `ink-3`，
/// 内边距上 4 下 6 左右 8。不给悬停、不可点。
struct DmMenuTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: DmText.t11, weight: .bold))
            .kerning(0.66)
            .foregroundColor(Color.dmInk3)
            .padding(.horizontal, DmSpace.s8)
            .padding(.top, DmSpace.s4)
            .padding(.bottom, DmSpace.s6)
    }
}

/// 菜单项（原型 `.mi`）：高按内容（上下 6）、圆角 `r-6`、字 13 / `ink-2`，
/// 悬停 `panel-3` 底 + 字转 `ink`；可选前置图标（`ink-3`，悬停转 `ink-2`）。
///
/// `trailing` 贴右（原型 `.mi .cb{margin-left:auto}`）—— 字段配置的勾选框走这里。
struct DmMenuRow<Trailing: View>: View {
    let title: String
    var icon: String?
    let action: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DmSpace.s8) {
                if let icon {
                    LucideIcon(icon, size: DmIcon.i12)
                        .foregroundColor(isHovered ? Color.dmInk2 : Color.dmInk3)
                }
                Text(title)
                    .font(.system(size: DmText.t13))
                    .foregroundColor(isHovered ? Color.dmInk : Color.dmInk2)
                Spacer(minLength: DmSpace.s8)
                trailing()
            }
            .padding(.horizontal, DmSpace.s8)
            .padding(.vertical, DmSpace.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r6)
                    .fill(isHovered ? Color.dmPanel3 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

extension DmMenuRow where Trailing == EmptyView {
    init(title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, icon: icon, action: action, trailing: { EmptyView() })
    }
}

/// 菜单里的分隔线（原型 `.msep`）：发丝 + `line-2`，左右 6、上下 4。
struct DmMenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.dmLine2)
            .frame(height: DmLine.hairline)
            .padding(.horizontal, DmSpace.s6)
            .padding(.vertical, DmSpace.s4)
    }
}

// ============ 右键 ============

/// 右键捕获层：压在列表行上，只接右键。
///
/// `hitTest` 是这套的关键：除了右键那三个事件，一律返回 nil 把事件穿透给下层，
/// 行上的单击选中、双击播放、悬停反馈才照常工作。接下来的一步把指针位置换算到
/// **根视图坐标**（左上原点）—— 菜单要浮在整个窗口之上，而画在行里会被后面的行
/// 盖住、也会被滚动区裁掉（原型的 `.menu` 是绝对定位在页面上的，同一条道理）。
///
/// SwiftUI 自己没有右键手势，`.contextMenu` 出的是**系统菜单**（NSMenu）—— 与第八节
/// 的菜单卡不是一套形态，所以这里自己接。
struct RightClickCatcher: NSViewRepresentable {
    /// 参数已在根视图坐标系里（左上原点）。
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint) -> Void)?

        /// 只管右键：其余事件一律不接（返回 nil 即穿透）。
        /// 事件类型看 `window.currentEvent`（`window.sendEvent` 也设它），
        /// `NSApp.currentEvent` 拿不到时兜底 —— 宁可右键没反应，也别把左键吞掉。
        override func hitTest(_ point: NSPoint) -> NSView? {
            let type = window?.currentEvent?.type ?? NSApp.currentEvent?.type
            switch type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return self
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let content = window?.contentView else { return }
            let inContent = content.convert(event.locationInWindow, from: nil)
            // AppKit 原生坐标左下原点、SwiftUI 左上原点 —— 但宿主视图
            // （NSHostingView）本身是 flipped 视图，`convert` 出来**已经是**
            // 左上原点。再手工翻一次就镜像了：点窗口下半段，菜单飞到上半段
            // 对称位置（2026-10-15 晚用户实锤：点 Mechanical Spring 一带，
            // 菜单出现在第 3-4 行韩文歌旁；日志里「报点==locInWindow」就是
            // 双重翻转的指纹）。按 flippedness 走，宿主不 flipped 时才手翻。
            let point = content.isFlipped
                ? inContent
                : CGPoint(x: inContent.x, y: content.bounds.height - inContent.y)
            onRightClick?(point)
        }
    }
}

/// 拖入捕获层：把从 Finder 拖过来的文件 / 文件夹接住（上传落点）。
///
/// `hitTest` 与 `RightClickCatcher` 同一套逻辑，但**只在拖动中返回自己**：
///   · 普通鼠标事件一律穿透 —— 它盖在整张表上，不穿透的话行的点击、双击、
///     悬停全被它吃掉；
///   · AppKit 找投放目标时也是在 `hitTest` 里问的，所以不能无脑返回 nil。
///     拖动期间的 `currentEvent` 是 `.leftMouseDragged`，只有这一档返回自己。
///
/// 应用内部的拖动不会被它抢走：那种拖动的后续事件发给**拿下 mouseDown 的那个视图**，
/// 不再过 `hitTest`；而且它注册的粘贴板类型只有 `.fileURL`，内部拖动根本不是候选。
struct FileDropCatcher: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.onDrop = onDrop
        view.onTargetedChange = { isTargeted = $0 }
        return view
    }

    func updateNSView(_ view: DropView, context: Context) {
        view.onDrop = onDrop
        view.onTargetedChange = { isTargeted = $0 }
    }

    final class DropView: NSView {
        var onDrop: (([URL]) -> Void)?
        var onTargetedChange: ((Bool) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("不从 nib 建") }

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .leftMouseDragged ? self : nil
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard canAccept(sender) else { return [] }
            onTargetedChange?(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            canAccept(sender) ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargetedChange?(false)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            canAccept(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTargetedChange?(false)
            let urls = Self.fileURLs(from: sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            onDrop?(urls)
            return true
        }

        /// 只吃本机文件 —— 拖一段文字或一张网页里的图进来不算。
        private func canAccept(_ sender: NSDraggingInfo) -> Bool {
            !Self.fileURLs(from: sender.draggingPasteboard).isEmpty
        }

        private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
            (pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]) ?? []
        }
    }
}

/// 表头一格上的鼠标接管层：点击、拖动、松手都从 **AppKit 层**拿。
///
/// 为什么不用 SwiftUI 的 `onTapGesture` / `DragGesture`：合成鼠标事件
/// （`NSEvent.mouseEvent` + `NSApp.postEvent`，与 `DM_KEYS` 同一套做法）
/// **进不了 SwiftUI 的手势系统** —— 2026-10-14 实测：同一位置 AppKit 探针收得到
/// `mouseDown`，递到 SwiftUI 却是零回调；而 `cliclick` / `osascript` 这类真发事件的
/// 工具在本机没有辅助功能权限、点击被静默丢弃。走 AppKit 层（与 `RightClickCatcher`
/// 同一套），冒烟通路就能自己合成事件核对「点表头 → 排序」「拖表头 → 换列序」。
///
/// 位置与回调统一给**窗口坐标**（`event.locationInWindow` 与 `convert(bounds, to: nil)`
/// 本来就是同一套，左下原点）—— 中间不做任何翻转与换算。
///
/// 为什么不换算成 SwiftUI 那套「左上原点内容坐标」：2026-10-14 实测，`.global` 报上来的
/// 位置与内容坐标**是不是同一个原点没验过**，翻一次 y 就多一次猜；猜错的表现是
/// 合成事件落在表头下方一行、点了等于没点。两套坐标干脆都别用，只留 AppKit 自己那一套。
///
/// `acceptsFirstMouse` 给真：窗口没激活时第一次点击也直接生效，不会先被「激活窗口」吃掉。
struct HeaderGrabber: NSViewRepresentable {
    /// 没拖动的按下抬起 = 点击。
    let onClick: () -> Void
    /// 拖动中（位移已超过阈值）。
    let onDrag: (CGPoint) -> Void
    /// 松手（拖过才回调；没拖走的点击归 `onClick`）。
    let onDrop: (CGPoint) -> Void
    /// 能拖的格子才起拖动；不能拖的（主键列）只报点击。
    let isDraggable: Bool
    /// 本格在窗口坐标里的位置。改列序的落点判定靠它，冒烟通路找格子也靠它。
    let onFrame: (CGRect) -> Void

    func makeNSView(context: Context) -> GrabberView {
        let view = GrabberView()
        view.apply(self)
        return view
    }

    func updateNSView(_ view: GrabberView, context: Context) {
        view.apply(self)
    }

    final class GrabberView: NSView {
        /// 拖动判定阈值：位移小于它算点击（一格上既是按钮又是拖柄）。
        private static let threshold: CGFloat = 6

        private var onClick: (() -> Void)?
        private var onDrag: ((CGPoint) -> Void)?
        private var onDrop: ((CGPoint) -> Void)?
        private var onFrame: ((CGRect) -> Void)?
        private var isDraggable = true

        private var start: CGPoint?
        private var moved = false
        /// 上次报出去的位置。位置没变就不重复回调 —— 免得每次布局都写一遍模型。
        private var reported: CGRect?

        func apply(_ owner: HeaderGrabber) {
            onClick = owner.onClick
            onDrag = owner.onDrag
            onDrop = owner.onDrop
            onFrame = owner.onFrame
            isDraggable = owner.isDraggable
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrame()
        }

        override func layout() {
            super.layout()
            reportFrame()
        }

        /// 把本格的位置报给调用点。窗口坐标 = `convert(bounds, to: nil)`。
        private func reportFrame() {
            guard window != nil else { return }
            let frame = convert(bounds, to: nil)
            guard frame != reported else { return }
            reported = frame
            onFrame?(frame)
        }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard isDraggable, let start else { return }
            let now = event.locationInWindow
            if !moved, hypot(now.x - start.x, now.y - start.y) >= Self.threshold {
                moved = true
            }
            if moved { onDrag?(now) }
        }

        override func mouseUp(with event: NSEvent) {
            if moved { onDrop?(event.locationInWindow) } else { onClick?() }
            start = nil
            moved = false
        }
    }
}

/// 表头列边界上的**调宽把手**：贴在格子 trailing 边缘的窄热区，按下拖动改列宽。
///
/// 为什么是 SwiftUI 手势而不是像 `HeaderGrabber` 那样走 AppKit 接管层：调宽是
/// **拖**、冒烟通路验不了 SwiftUI 手势（合成事件进不来），但用户真机拖拽走得通
/// （队列行的拖动改序同一条路）；而表头格子上的**点击排序**必须走接管层 ——
/// 所以两层共存：把手只占边缘 7px 热区（overlay 压在接管层之上，先命中），
/// 格子中间仍归 `HeaderGrabber`。
///
/// 形态：悬停 / 拖动中显示 3px 主色竖线（与改列序的落点竖线同一语言），光标换
/// 左右调宽。拖动回调**绝对宽度**（起始宽 + 位移），clamp 由调用方做。
struct ColumnResizer: View {
    /// 当前列宽 —— 拖动的起点宽（手势开始那一刻捕获一次）。
    let width: CGFloat
    let onResize: (CGFloat) -> Void

    @State private var isHovered = false
    @State private var isDragging = false
    @State private var startWidth: CGFloat = 0

    /// 热区宽。比可见线（3px）宽出一截，别让人对着边界线瞄半天。
    private static let hitWidth: CGFloat = 7

    var body: some View {
        ZStack {
            if isHovered || isDragging {
                Rectangle()
                    .fill(Color.dmAccent2)
                    .frame(width: DmLine.bold)
            }
        }
        .frame(width: Self.hitWidth)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            if inside {
                NSCursor.resizeLeftRight.set()
            } else if !isDragging {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        startWidth = width
                    }
                    onResize(startWidth + value.translation.width)
                }
                .onEnded { _ in
                    isDragging = false
                    if !isHovered { NSCursor.arrow.set() }
                }
        )
    }
}

/// 搜索框：高钉控件档 32、圆角 `r-8`、底按所在面取相邻一档、`line-2` 1px 描边；
/// 左侧放大镜 14（`ink-3`），横向内边距 12、图标与输入之间 8；聚焦只转描边
/// （`accent-2`）、底色不动；有内容时右侧出清除钮。宽度由调用点给
/// （曲库 280、文件管理 200）。
///
/// 形态照原型 `.searchbox`。产品线里这是第一个搜索框 —— 另四端都没有这个场景，
/// 没有可复刻的落点，规格先落在本端。
///
/// `focusTicket`：外部的「把光标放进来」请求，每加一就聚焦一次。冒烟通路要用它
/// —— AI 点不了 UI，而 AppKit 那边硬塞第一响应者会被 SwiftUI 的焦点机制顶回来
/// （2026-10-13 实测：`makeFirstResponder` 收下了，第一响应者却不是字段编辑器）。
struct DmSearchField: View {
    @Binding private var text: String
    private let placeholder: String
    private let surface: DmSurface
    private let focusTicket: Int
    private let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    init(
        text: Binding<String>,
        placeholder: String,
        surface: DmSurface = .panel,
        focusTicket: Int = 0,
        onSubmit: @escaping () -> Void = {}
    ) {
        self._text = text
        self.placeholder = placeholder
        self.surface = surface
        self.focusTicket = focusTicket
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
        // 外部的聚焦请求落到 SwiftUI 自己的焦点状态上 —— 由它去装字段编辑器，
        // 不走 AppKit 硬塞。
        .onChange(of: focusTicket) { isFocused = true }
    }
}

/// 面包屑的一段。`action` 为 `nil` 表示这一段就是当前所在（压 `ink`、不可点）。
///
/// 面包屑占的是页头**第二行**那一格（原型的 `.crumb` 在 `.page-head` 里，
/// 与副行同一个 `s4` 间距）—— 所以它做成 `DmPageHead` 的一个入参，而不是各页
/// 在页头下面再拼一行。
struct DmCrumb {
    let title: String
    let action: (() -> Void)?

    init(_ title: String, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
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
    private let crumbs: [DmCrumb]
    private let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        crumbs: [DmCrumb] = [],
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.crumbs = crumbs
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: DmSpace.s16) {
            VStack(alignment: .leading, spacing: DmSpace.s4) {
                Text(title)
                    .font(.system(size: DmText.t17, weight: .semibold))
                    .kerning(-0.17)
                    .foregroundColor(Color.dmInk)
                // 有面包屑时它占第二行（两者不会同时出现）。
                if !crumbs.isEmpty {
                    crumbRow
                } else if let subtitle, !subtitle.isEmpty {
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

    /// 面包屑一行：段与段之间 `s4`，分隔符 `chevron-right` 取 `ic-12` / `ink-3`；
    /// 可点的段悬停转 `ink`，当前段常态就压 `ink` + 500（原型 `.crumb b`）。
    private var crumbRow: some View {
        HStack(spacing: DmSpace.s4) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    LucideIcon("chevron-right", size: DmIcon.i12)
                        .foregroundColor(Color.dmInk3)
                }
                if let action = crumb.action {
                    CrumbSegment(title: crumb.title, action: action)
                } else {
                    Text(crumb.title)
                        .font(.system(size: DmText.t13, weight: .medium))
                        .foregroundColor(Color.dmInk)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// 面包屑里可点的一段。做成一个独立视图是因为它要挂悬停态（`@State` 不能写在
/// `ForEach` 的闭包里）。
private struct CrumbSegment: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.system(size: DmText.t13))
            .foregroundColor(isHovered ? Color.dmInk : Color.dmInk3)
            .lineLimit(1)
            .contentShape(Rectangle())
            .trackingHover($isHovered)
            .onTapGesture(perform: action)
    }
}

extension DmPageHead where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

// ============ 封面缩略图 ============

/// 封面缩略图。尺寸由所在位置定（曲库表行内 28、播放条 44），
/// 圆角一律 `r-8`、图形跟尺寸走（12 / 20）。
///
/// **没有图时退回占位**：`panel-2` 底 + `music` 图形取 `ink-3` —— 专辑没有封面图、
/// 或还没取回来，都是这一格。原型的渐变底是占位美术，不落进实现。
///
/// 取图异步、按「歌所在的目录 + 档位」缓存（`CoverStore`），同一张专辑只问服务端
/// 一次。**必须传 `folder`**（`song.folder`）：库里同名但不同源的专辑会缺
/// `album_artist` 标签、被 DSM 并成一张，按专辑名取图会串台（2026-10-13 实测，
/// 见 `AudioLibrary.folderCover`）。曲库表里每行一个实例，靠列表的惰性渲染兜住量
/// —— 滚出来的行才发请求。
struct DmCover: View {
    @Environment(AppState.self) private var state

    let album: String
    let artist: String
    /// 歌所在目录。取图的首选依据 —— **不给默认值**，逼调用点传 `song.folder`：
    /// 省掉它就等于退回「按专辑名取图」，正是串台那条老路。
    let folder: String
    let size: CGFloat

    @State private var image: NSImage?

    private var iconSize: CGFloat { size >= 44 ? DmIcon.i20 : DmIcon.i12 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DmRadius.r8)
                .fill(Color.dmPanel2)
            LucideIcon("music", size: iconSize)
                .foregroundColor(Color.dmInk3)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: DmRadius.r8))
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: DmMotion.fast), value: image == nil)
        // 换歌 / 换专辑重取一次；同一张专辑在缓存里，不会重复发请求。
        .task(id: "\(folder)\u{1}\(album)\u{1}\(artist)") { await load() }
    }

    private func load() async {
        guard !(album.isEmpty && folder.isEmpty), let manager = state.sessionManager else {
            image = nil
            return
        }
        let data = await CoverStore.shared.cover(
            manager: manager,
            album: album,
            artist: artist,
            folder: folder,
            // 行内 28 / 播放条 44 都走缩略图；再大（沉浸屏那类）才要原图。
            // 这个组件目前的落点最大 44，留着档位判断免得以后加了尺寸忘了改。
            highRes: size >= 200
        )
        image = data.flatMap(NSImage.init(data:))
    }
}

// ============ 均衡器标记 ============

/// 「正在播放」的行标 —— 三根静态小条（原型 `.eq`：3 宽、高 6/12/9、accent-2）。
/// 正在播放与选中共用底色，靠它区分（第八节「选中与悬停」浅底轨）。
///
/// 条子用 `Capsule` 而不是 `RoundedRectangle(cornerRadius:)`：3px 宽的条子圆角 1px
/// 落在尺度档之外（最小档 4），胶囊形在这里等价，也不留裸值。
struct EqualizerBars: View {
    var color: Color = Color.dmAccent2

    var body: some View {
        HStack(alignment: .bottom, spacing: DmSpace.s2) {
            bar(height: 6)
            bar(height: 12)
            bar(height: 9)
        }
    }

    private func bar(height: CGFloat) -> some View {
        Capsule()
            .fill(color)
            .frame(width: 3, height: height)
    }
}

// ============ Toast ============

/// 一条短提示的内容。`id` 换一次就是一条新提示（重开计时、重播入场）。
struct ToastMessage: Identifiable {
    let id = UUID()
    let kind: DmToast.Kind
    let text: String

    init(_ text: String, _ kind: DmToast.Kind) {
        self.text = text
        self.kind = kind
    }
}

/// Toast（第八节「Toast」表）：底 `toast-bg` / 字 `toast-ink` 实色、`t12` / 500、
/// 内边距纵向 `s8` 横向 `s16`、圆角 `r-10`、提示条档阴影、图标 `ic-16`。
///
/// **位置不在这里** —— 「窗口底部居中、距底 `s24`」由调用点的 overlay 对齐给
/// （`.dmToast(_:)` 就是那个调用点）。写在组件自己身上，改坏对齐不会有东西红。
///
/// `kind` **必传、不给默认值**：这一处算成功、失败还是说明，只有调用点知道；
/// 给了默认值就没人再想它，三种语义会退化成一种。图标与文字同取 `toast-ink`、
/// **不取族色** —— 族基础档是为固定深色底选的，压在这块浅实色底上只有
/// 2.01 / 2.99 / 2.92:1，够不到承载图形那条 3:1；语义由形状承载。
struct DmToast: View {
    enum Kind {
        case ok
        case err
        case info

        var icon: String {
            switch self {
            case .ok: return "circle-check"
            case .err: return "circle-x"
            case .info: return "info"
            }
        }
    }

    let kind: Kind
    let message: String

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon(kind.icon, size: DmIcon.i16)
                .foregroundColor(Color.dmToastInk)
            Text(message)
                .font(.system(size: DmText.t12, weight: .medium))
                .foregroundColor(Color.dmToastInk)
        }
        .padding(.horizontal, DmSpace.s16)
        .padding(.vertical, DmSpace.s8)
        .background(Color.dmToastBg, in: RoundedRectangle(cornerRadius: DmRadius.r10))
        .dmShadowToast()
    }
}

extension View {
    /// 挂一条 Toast：置值即显示，2 秒后自己清空。位置落在这个调用点上 ——
    /// 窗口底部居中、距底 `s24`（第八节）。
    func dmToast(_ toast: Binding<ToastMessage?>) -> some View {
        overlay(alignment: .bottom) {
            if let message = toast.wrappedValue {
                DmToast(kind: message.kind, message: message.text)
                    .padding(.bottom, DmSpace.s24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message.id) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation(.easeOut(duration: DmMotion.base)) {
                            toast.wrappedValue = nil
                        }
                    }
            }
        }
        .animation(.easeOut(duration: DmMotion.base), value: toast.wrappedValue?.id)
    }
}

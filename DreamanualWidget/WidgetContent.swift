import SwiftUI

// ============ 桌面小组件的视图层 ============
//
// 形态照 `design/小组件原型.html` 第 10 稿逐字落：
//   · 颜色字号全走 design 令牌（panel / ink 族 / ok / accent-fill，见主题文件）；
//   · 分隔线全退场，分区靠留白；组内贴紧（大值行高 1.25 的效果由 SwiftUI
//     单行文本天然成立，kerning -0.4 对应 demo 的 letter-spacing -.02em）；
//   · 中组件三块 space-between 均分（列宽收缩包内容）；
//   · 离线态：server-off 图标 + 文案整组在状态行下方居中（顶行占视觉重量，
//     padding-top 顶开 22px，demo 实测组中心比可用区中心低 3.9px）。
//
// 这份文件只依赖 SwiftUI —— WidgetKit 的东西在 NASStatusWidget.swift 里，
// 这样渲染核对可以直接拿它开窗截图，不用真装小组件。

/// 视图层吃的数据：全部是**摆好样子的字符串**，映射在 widget 那侧做
/// （渲染核对就能直接捏假数据，不用构造整份快照）。
struct NASWidgetDisplay {
    enum Tone { case ok, off, bad }
    struct Disk {
        var name: String
        var temperatureText: String
    }

    var tone: Tone = .ok
    var statusText: String = "在线"
    /// 右上角抓取时间。离线态留空（demo 离线卡顶行没有时间）。
    var uptText: String = ""
    var offline: Bool = false
    var offlineTitle: String = "连不上"
    var lastOnlineText: String?
    var usedText: String = "0.00"
    var totalText: String = "/ 0 TB"
    var usedPercent: Double = 0
    var freeText: String?
    var cpuText: String = "0%"
    var temperatureText: String = "0°C"
    var disks: [Disk] = []
}

extension NASWidgetDisplay {
    /// 共享快照 → 显示数据。数字格式照 demo：两位小数的 TB、一位小数的
    /// 百分比、右上角 HH:mm（中组件带「更新」），离线行 MM-dd HH:mm。
    static func make(from data: WidgetSnapshotData, date: Date,
                     family: NASStatusContent.Family) -> NASWidgetDisplay {
        let tb: Double = 1_099_511_627_776
        let used = Double(data.volumeUsed) / tb
        let total = Double(data.volumeTotal) / tb
        let percent = total > 0 ? Double(data.volumeUsed) / Double(data.volumeTotal) : 0
        let free = max(0, total - used)
        // 顶行转红的唯一判据：服务端报上次关机不正常（is_system_crashed）。
        let tone: NASWidgetDisplay.Tone = data.crashed ? .bad : .ok
        let status = data.crashed ? "异常" : "在线"
        let upt = uptStamp.string(from: data.takenAt) + (family != .small ? " 更新" : "")
        return NASWidgetDisplay(
            tone: tone,
            statusText: status,
            uptText: upt,
            usedText: String(format: "%.2f", used),
            totalText: String(format: "/ %.2f TB", total),
            usedPercent: percent,
            freeText: String(format: "%.2f TB", free),
            cpuText: "\(data.cpuUsage)%",
            temperatureText: "\(data.temperature)°C",
            disks: data.disks.enumerated().map { index, disk in
                .init(name: disk.name.isEmpty ? "硬盘 \(index + 1)" : disk.name,
                      temperatureText: "\(disk.temperature)°C")
            }
        )
    }

    static func offline(title: String, lastOnline takenAt: Date?) -> NASWidgetDisplay {
        let last = takenAt.map { "上次在线 \(lastStamp.string(from: $0))" }
        return NASWidgetDisplay(tone: .off, statusText: "离线", uptText: "",
                                offline: true, offlineTitle: title, lastOnlineText: last)
    }

    static let uptStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let lastStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

struct NASStatusContent: View {
    /// `small` / `medium` 是桌面小组件两档；`panel` 是状态栏面板 —— 同一份
    /// 数据，三处差异：在线列内 kv 不做两端对齐（不抢块间空隙、列宽稳定）；
    /// 离线不摆状态行、内容组居中；内边距为 0（外层面板自己有一圈 12，
    /// 再叠一层就是 24，按钮才贴 12 —— 2026-10-17 用户抓图）。
    enum Family { case small, medium, panel }

    let display: NASWidgetDisplay
    let family: Family

    var body: some View {
        Group {
            if display.offline {
                offline
            } else if family == .small {
                smallOnline
            } else {
                mediumOnline(kvTrailing: family != .panel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(family == .panel ? 0 : DmSpace.s12)
    }

    // MARK: 在线 · 小组件

    private var smallOnline: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow.padding(.bottom, DmSpace.s8)
            Text("存储空间").font(.wLab).foregroundColor(.dmInk3)
            storageValue.padding(.top, DmSpace.s2)
            progressBar.padding(.top, DmSpace.s4)
            Spacer(minLength: 14)
            duo
        }
    }

    // MARK: 在线 · 中组件（三块 space-between，列宽收缩包内容）

    /// `kvTrailing`：列内 kv 行要不要两端对齐（`Spacer` 撑满列宽）。
    /// 小组件里要 —— 温度列得贴着卡片右缘；面板里**不要** —— Spacer 会把
    /// 所在列变成弹性列，抢走块间空隙：温度列被撑宽、「硬盘 1」与温度分开
    /// 老远像两个内容，列宽还随数值位数跳（2026-10-17 用户抓图）。面板档
    /// 块间空隙全给列间的 `Spacer`，三块间距大而均匀、列宽收缩稳定。
    private func mediumOnline(kvTrailing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("存储空间").font(.wLab).foregroundColor(.dmInk3)
                    storageValue.padding(.top, DmSpace.s2)
                    progressBar.padding(.top, DmSpace.s4)
                    if let free = display.freeText {
                        kvRow(k: "可用", v: free, trailing: kvTrailing).padding(.top, DmSpace.s2)
                    }
                }
                Spacer(minLength: DmSpace.s16)
                VStack(alignment: .leading, spacing: 0) {
                    Text("CPU").font(.wLab).foregroundColor(.dmInk3)
                    Text(display.cpuText)
                        .font(.wVal).kerning(-0.4).monospacedDigit()
                        .foregroundColor(.dmInk)
                        .padding(.top, DmSpace.s2)
                }
                Spacer(minLength: DmSpace.s16)
                VStack(alignment: .leading, spacing: 0) {
                    Text("温度").font(.wLab).foregroundColor(.dmInk3)
                    Text(display.temperatureText)
                        .font(.wVal).kerning(-0.4).monospacedDigit()
                        .foregroundColor(.dmInk)
                        .padding(.top, DmSpace.s2)
                    ForEach(display.disks, id: \.name) { disk in
                        kvRow(k: disk.name, v: disk.temperatureText, trailing: kvTrailing)
                            .padding(.top, DmSpace.s2)
                    }
                }
            }
            .padding(.top, DmSpace.s10)
        }
    }

    // MARK: 离线（两档同一套，标题与上次在线文案由映射层给）

    private var offline: some View {
        if family == .panel {
            // 面板档：不摆「● 离线」状态行 —— 读取中/离线时它没有信息量，
            // 还把居中的内容组顶得偏上（2026-10-17 用户抓图）。内容组在
            // 可用区里垂直水平居中。
            return AnyView(
                offlineBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                topRow
                Spacer(minLength: 0)
                offlineBadge.frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
            // 顶行占视觉重量：内容区从状态行下方起算居中（demo 第 5 稿，+22px）。
            .padding(.top, 34)
        )
    }

    /// 离线内容组。两档共用，只是外面套的排布不同。
    private var offlineBadge: some View {
        VStack(spacing: DmSpace.s6) {
            ServerOffIcon()
                .frame(width: 30, height: 30)
                .foregroundColor(.dmInk3)
            Text(display.offlineTitle)
                .font(.wBig)
                .foregroundColor(.dmInk2)
            if let last = display.lastOnlineText {
                Text(last).font(.wKv).foregroundColor(.dmInk3).monospacedDigit()
            }
        }
    }

    // MARK: 零件

    private var topRow: some View {
        HStack(spacing: DmSpace.s6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .shadow(color: dotGlow, radius: DmSpace.s2)
            Text(display.statusText)
                .font(.wStatus)
                .foregroundColor(textColor)
            Spacer(minLength: 0)
            if !display.uptText.isEmpty {
                Text(display.uptText)
                    .font(.wUpt)
                    .monospacedDigit()
                    .foregroundColor(.dmInk3)
            }
        }
    }

    private var dotColor: Color {
        switch display.tone {
        case .ok: return .dmOkInkStrong
        case .off: return .dmInk3
        case .bad: return .dmDangerInkStrong
        }
    }

    private var dotGlow: Color {
        switch display.tone {
        case .ok: return Color.dmOkInkStrong.opacity(0.55)
        case .off: return .clear
        case .bad: return Color.dmDangerInkStrong.opacity(0.55)
        }
    }

    private var textColor: Color {
        switch display.tone {
        case .ok: return .dmOkInkStrong
        case .off: return .dmInk3
        case .bad: return .dmDangerInkStrong
        }
    }

    private var storageValue: some View {
        HStack(alignment: .firstTextBaseline, spacing: DmSpace.s2) {
            Text(display.usedText)
                .font(.wVal).kerning(-0.4).monospacedDigit()
                .foregroundColor(.dmInk)
            Text(display.totalText)
                .font(.wValSmall)
                .foregroundColor(.dmInk3)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dmPanel3)
                Capsule()
                    .fill(Color.dmAccentFill)
                    .frame(width: max(6, geo.size.width * min(1, max(0, display.usedPercent))))
            }
        }
        .frame(height: 6)
    }

    private var duo: some View {
        HStack(alignment: .top, spacing: DmSpace.s16) {
            VStack(alignment: .leading, spacing: DmSpace.s2) {
                Text("CPU").font(.wKv).foregroundColor(.dmInk3)
                Text(display.cpuText)
                    .font(.wBig)
                    .monospacedDigit()
                    .foregroundColor(.dmInk)
            }
            VStack(alignment: .leading, spacing: DmSpace.s2) {
                Text("温度").font(.wKv).foregroundColor(.dmInk3)
                Text(display.temperatureText)
                    .font(.wBig)
                    .monospacedDigit()
                    .foregroundColor(.dmInk)
            }
        }
        // 分隔线已退场（demo 第 7 稿），组间靠留白 + 上方 14px。
        .padding(.top, DmSpace.s14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `trailing = true`：kv 两端对齐（`Spacer` 撑满列宽，小组件温度列贴右缘
    /// 用）。`false`：kv 紧挨（间距 s8）—— 列不参与弹性，宽度收缩包内容。
    private func kvRow(k: String, v: String, trailing: Bool) -> some View {
        HStack(spacing: DmSpace.s8) {
            Text(k).font(.wKv).foregroundColor(.dmInk3)
            if trailing {
                Spacer(minLength: 0)
            }
            Text(v).font(.wKv).monospacedDigit().foregroundColor(.dmInk2)
        }
    }
}

private extension Font {
    /// 主值 20/600，小尾巴 11/400，标签与 kv 11，顶行状态 11/500，时间 10。
    static let wVal = Font.system(size: DmText.t20, weight: .semibold)
    static let wValSmall = Font.system(size: DmText.t11, weight: .regular)
    static let wLab = Font.system(size: DmText.t11, weight: .regular)
    static let wKv = Font.system(size: DmText.t11, weight: .regular)
    static let wStatus = Font.system(size: DmText.t11, weight: .medium)
    static let wUpt = Font.system(size: DmText.t10, weight: .regular)
    static let wBig = Font.system(size: DmText.t13, weight: .semibold)
}

/// Lucide `server-off` 的自绘近似（SF Symbols 没有这枚）：两只圆角盒 +
/// 一道从左上到右下的斜杠 —— 斜杠先用面板底色开槽再描线，盒线在斜杠处
/// 断开，30px 下与 demo 的观感一致。viewBox 24×24，坐标照 lucide 摆。
struct ServerOffIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 24
            let ink = Color.dmInk3
            let stroke = DmLine.base + DmLine.hairline  // 1.5，demo SVG 的 stroke-width
            ZStack {
                Path { path in
                    path.addRoundedRect(
                        in: CGRect(x: 2 * s, y: 2 * s, width: 20 * s, height: 8 * s),
                        cornerSize: CGSize(width: 2 * s, height: 2 * s))
                }
                .stroke(ink, lineWidth: stroke * s)
                Path { path in
                    path.addRoundedRect(
                        in: CGRect(x: 2 * s, y: 14 * s, width: 20 * s, height: 8 * s),
                        cornerSize: CGSize(width: 2 * s, height: 2 * s))
                }
                .stroke(ink, lineWidth: stroke * s)
                Circle()
                    .frame(width: 2 * s, height: 2 * s)
                    .foregroundColor(ink)
                    .position(x: 6 * s, y: 18 * s)
                // 斜杠（demo 摘的 lucide 路径 m2 2 20 20）：底色开槽 → 描线。
                SlashLine()
                    .stroke(Color.dmPanel, style: StrokeStyle(lineWidth: stroke * 3 * s, lineCap: .round))
                SlashLine()
                    .stroke(ink, style: StrokeStyle(lineWidth: stroke * s, lineCap: .round))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct SlashLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 2 / 24,
                              y: rect.minY + rect.height * 2 / 24))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 22 / 24,
                                 y: rect.minY + rect.height * 22 / 24))
        return path
    }
}

import AppKit
import SwiftUI

/// 系统状态页的状态（快照 / 取数阶段）。
///
/// 与 `LibraryModel` 同一归属：挂在 `AppState` 上而不是视图的 `@State` ——
/// 切去听歌再切回来，温度与容量不该重新转一次圈；冒烟通路也要能在视图之外
/// 把它摆到各个状态。
@MainActor
@Observable
final class SystemStatusModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)

        var isBusy: Bool { self == .loading }
    }

    private(set) var phase: Phase = .idle
    /// 四块各自可能缺（中继链路上几条接口的成功率本来就参差）。
    private(set) var snapshot: SystemSnapshot?
    /// 拉到完整快照后叫一声 —— AppState 拿它喂小组件的共享容器。
    var onFreshSnapshot: ((SystemSnapshot) -> Void)?

    /// 取一次。`force` 为假且已有快照时不动 —— 换模块回来不该白发一轮请求。
    func load(on manager: SessionManager?, force: Bool = false) async {
        guard let manager else { return }
        if !force, snapshot != nil || phase == .loading { return }
        phase = .loading
        let result = await SystemStatusAPI.fetch(manager)
        if result.isEmpty {
            // 四块全空才算失败。一句一条地把原因串起来，比「读取失败」有用。
            phase = .failed(result.failures.joined(separator: "；"))
            return
        }
        snapshot = result
        phase = .ready
        onFreshSnapshot?(result)
    }

    /// 没取回来的那几块，拼成一句给提示条。
    var failureNote: String? {
        guard let snapshot, !snapshot.failures.isEmpty else { return nil }
        return "这次没读到 —— " + snapshot.failures.joined(separator: "；")
    }

    /// 断开时清掉 —— 换了机器或换了一条链路，旧快照里的温度与容量都不作数了。
    func clear() {
        snapshot = nil
        phase = .idle
    }

    /// 冒烟专用：把某一块抹掉，看「缺一块」那张卡与那条提示条。
    ///
    /// 真机上造不出一次干净的部分失败（要把某条接口单独打断），而这条路径正是
    /// 「四条接口互相独立」这个设计的落点，得看一眼。`block` 认
    /// `device` / `load` / `storage` / `health`。
    func smokeDrop(_ block: String) {
        guard var snapshot else { return }
        switch block {
        case "device": snapshot.device = nil; snapshot.failures.append("机器信息：冒烟抹掉")
        case "load": snapshot.load = nil; snapshot.failures.append("负载：冒烟抹掉")
        case "storage": snapshot.storage = nil; snapshot.failures.append("容量：冒烟抹掉")
        case "health": snapshot.health = nil; snapshot.failures.append("系统状态：冒烟抹掉")
        default: NSLog("[status] 抹不掉「%@」", block); return
        }
        self.snapshot = snapshot
    }
}

/// 系统状态。
///
/// 形态照原型 `design/界面原型.html` 的系统状态屏：页头（副行写固件与开机时长、
/// 右端链路徽章 + 刷新）→ 四张状态卡 → 存储与硬盘。
///
/// **读写半**：温度 / CPU / 内存 / 运行时长 / 容量 / 硬盘（只读），加开关机计划的
/// 读取与增删改（写，操作即写回），加电源卡（立刻关机 / 重启，都要二次确认；
/// `SystemPowerAPI` 没有回读这一步 —— 发出即成功，后续真假交给链路监控与
/// 重启等待重连，见 `Core/SystemPower.swift` 头注释）。**关机没真机执行过**
/// —— 真执行就把这台机器拔了、软件唤醒做不到（`docs/接口结论.md` 第二节）；
/// 重启已真机往返验证。
///
/// 与原型的三处偏离，都是接口决定的，不是设计取舍：
///   ① 原型每块盘一条进度条 —— 服务端**不给单盘已用量**（SHR 之下盘也不是各自
///      独立的卷），进度条只能给存储空间，硬盘卡改成一行一块盘（温度 / 状态 / 读写）；
///   ② 原型的 CPU 卡写「4 核 · 负载 0.42」——本机 `cpu_cores` 是 2（R1600 是 2 核 4 线程，
///      服务端只报物理核），负载照 `1min_load / 100` 显示；
///   ③ 原型的页头没有告警位 —— 这里在页头下挂提示条，只在服务端报了
///      「上次崩溃」或「扩展网卡不兼容」时出现。
struct StatusView: View {
    @Environment(AppState.self) private var state

    private var model: SystemStatusModel { state.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DmPageHead("系统状态", subtitle: subtitle) {
                if let link = state.linkMode {
                    DmBadge(link.label, icon: "wifi", tone: .accent)
                }
                IconButton(iconName: "refresh-cw") {
                    Task { await model.load(on: state.sessionManager, force: true) }
                }
            }

            // 系统自己报了事才出提示条（原型没有这一条，接口有就摆上）。
            if let health = model.snapshot?.health, !health.isNormal {
                ForEach(health.warnings, id: \.self) { warning in
                    DmBanner(icon: "triangle-alert", text: warning)
                }
            }

            // 部分失败：四块里缺了一两块。整屏不空白，缺的那块在，这张条在。
            if let note = model.failureNote {
                DmBanner(icon: "triangle-alert", text: note)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 主内容区取 `panel`（第一节落位口径）。
        .background(Color.dmPanel)
        // 计划表与系统状态那四条各走各的接口、各有各的失败，并着拉。
        // 页头的刷新钮只管上面那份快照 —— 计划表是「设置」不是「读数」，写回是
        // 卡片自己那两颗按钮的事，顺手把它也刷一遍会把改到一半的开关冲掉。
        .task {
            async let statusLoad: Void = model.load(on: state.sessionManager)
            async let scheduleLoad: Void = state.powerSchedule.load(on: state.sessionManager)
            _ = await (statusLoad, scheduleLoad)
            // 页面停留期间 30s 一拍续刷（与状态栏面板同节奏），离开即停
            //（`.task` 随视图摘除取消）。温度与 CPU/内存是慢变量，这个节奏
            // 足够「活着」；读写速度已删 —— 瞬时量配快照页只会误导。
            // 计划表不在续刷里：它是设置，刷它会把改到一半的开关冲掉。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                await model.load(on: state.sessionManager, force: true)
            }
        }
    }

    /// 副行：固件 + 开机时长（原型「DSM 7.4.1 · 开机 27 天 4 小时」那一行）。
    private var subtitle: String? {
        guard let device = model.snapshot?.device else { return nil }
        return "\(device.firmware) · \(device.uptimePhrase)"
    }

    @ViewBuilder
    private var content: some View {
        // 有快照就一直画它 —— 刷新时不要把已经看到的数换成转圈。
        if let snapshot = model.snapshot, !snapshot.isEmpty {
            cards(snapshot)
        } else if case .failed(let reason) = model.phase {
            StatusNotice(icon: "circle-x", title: "没能读到系统状态", note: reason,
                         actionTitle: "重试") {
                Task { await model.load(on: state.sessionManager, force: true) }
            }
        } else {
            StatusNotice(icon: "loader", title: "正在读取系统状态…",
                         note: "四条接口并发发出：机器信息、负载、容量、系统状态。")
        }
    }

    /// 四张状态卡 + 存储与硬盘两卡。并排的卡**由最高的那张定高**（原型
    /// `.grid2` 那句「并排两张由 grid 拉到等高，向高的看齐」）。
    private func cards(_ snapshot: SystemSnapshot) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: DmSpace.s12) {
                HStack(alignment: .top, spacing: DmSpace.s12) {
                    ForEach(SystemStatusAPI.stats(snapshot), id: \.label) { stat in
                        StatusStatCard(stat: stat)
                    }
                }

                HStack(alignment: .top, spacing: DmSpace.s12) {
                    StorageCard(volume: snapshot.storage?.volumes.first)
                    DiskCard(disks: snapshot.storage?.disks ?? [])
                }

                // 原型下半屏的 grid2：电源 | 开关机计划 并排、由高的那张定高。
                HStack(alignment: .top, spacing: DmSpace.s12) {
                    PowerCard()
                    PowerScheduleCard()
                }
            }
            .padding(.horizontal, DmSpace.s24)
            .padding(.bottom, DmSpace.s20)
        }
    }
}

// ============ 卡片 ============

/// 电源卡（原型 `.card.list` 那张）：卡头「电源」+ 提示 → 两行（立刻关机 / 重新启动）。
///
/// 🔴 提示行**必须**写「关机后无法远程唤醒」—— 关机后唯一出路是 NAS 侧的
/// 开机计划，这条写在卡上、不放帮助文档（原型 data-note 原话）。两颗按钮
/// 都只开确认弹窗，指令在确认框里发（原型：关机与重启都要二次确认）。
private struct PowerCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DmSpace.s6) {
                Text("电源")
                    .font(.system(size: DmText.t13, weight: .semibold))
                    .foregroundColor(Color.dmInk)
                Text("关机后无法远程唤醒：要它自己开机，先设好右边的开机计划。")
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DmSpace.s14)
            .padding(.top, DmSpace.s14)
            .padding(.bottom, DmSpace.s10)

            PowerActionRow(icon: "power", title: "立刻关机", note: nil,
                           button: "关机…") {
                state.openPowerConfirm(.shutdown)
            }
            PowerActionRow(icon: "refresh-cw", title: "重新启动",
                           note: "约 2 分钟后恢复在线",
                           button: "重启…") {
                state.openPowerConfirm(.reboot)
            }
        }
        .dmCard()
    }
}

/// 电源卡的一行（原型 `.srow`：上沿发丝、内边距 10/14、右端按钮）。
private struct PowerActionRow: View {
    let icon: String
    let title: String
    let note: String?
    let button: String
    let action: () -> Void

    private var label: some View {
        HStack(spacing: DmSpace.s6) {
            LucideIcon(icon, size: DmIcon.i12)
            Text(button)
        }
    }

    var body: some View {
        HStack(spacing: DmSpace.s12) {
            VStack(alignment: .leading, spacing: DmSpace.s2) {
                Text(title)
                    .font(.system(size: DmText.t13))
                    .foregroundColor(Color.dmInk)
                if let note {
                    Text(note)
                        .font(.system(size: DmText.t11))
                        .monospacedDigit()
                        .foregroundColor(Color.dmInk3)
                }
            }
            Spacer(minLength: 0)
            // 两颗入口同构（次按钮描边）—— 危险语义全留给确认弹窗里的执行钮，
            // 卡面上红实心与描边并排是对撞不是层级。卡面档（`panel-3` 底）：
            // 电源卡是 `dmCard()`，面板档画在这里与卡面同色，看不出是按钮。
            Button(action: action) { label }
                .buttonStyle(SecondaryButtonStyle(on: .card))
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.dmLine)
                .frame(height: DmLine.hairline)
        }
    }
}

/// 关机 / 重启的确认弹窗（挂根视图 `.dmModal`，470 自绘卡）。
///
/// 影响清单按动作给：共通一条「传输会中断」，关机加「无法远程唤醒」
/// （硬约束走 `DmDangerNote`），重启加「约 2 分钟回来、会自动重连」。
/// 执行中两颗按钮都锁 —— 指令发出去 NAS 就下电了，重复点没有意义。
struct PowerConfirmCard: View {
    @Environment(AppState.self) private var state
    @State private var isExecuting = false

    private var kind: AppState.PowerConfirm? { state.powerConfirm }

    private var isShutdown: Bool { kind == .shutdown }

    var body: some View {
        DmModalCard(title: isShutdown ? "立刻关机" : "重新启动",
                    onClose: { state.closePowerConfirm() }) {
            VStack(alignment: .leading, spacing: DmSpace.s10) {
                if isShutdown {
                    DmDangerNote(text: dangerNote)
                }
                impact("arrow-down-up", "正在进行的播放与文件传输会中断。")
                if isShutdown {
                    impact("power", "关机后无法远程唤醒 —— 要它自己开机，先在计划卡里排好开机时间。")
                } else {
                    impact("clock", "NAS 约 2 分钟后恢复在线，客户端会自动重连。")
                }
            }
        } foot: {
            Button("取消") { state.closePowerConfirm() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isExecuting)
            Button(isShutdown ? "关机" : "重启", action: submit)
                .anyButton(danger: isShutdown)
                .disabled(isExecuting)
        }
    }

    /// 关机的硬约束（红色提示块）；重启不需要 —— 它自己会回来。
    private var dangerNote: String {
        "关机后无法远程唤醒，唯一出路是 NAS 侧的开机计划。"
    }

    private func impact(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DmSpace.s8) {
            LucideIcon(icon, size: DmIcon.i12)
                .foregroundColor(Color.dmInk3)
                .padding(.top, DmSpace.s2)
            Text(text)
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func submit() {
        guard let kind, !isExecuting else { return }
        isExecuting = true
        Task {
            await state.confirmPower(kind)
            isExecuting = false
        }
    }
}

/// 两颗确认按钮只差样式、不差布局 —— 用一个小包装挑，免得写两遍 Button。
private struct AnyButton: ViewModifier {
    let danger: Bool

    func body(content: Content) -> some View {
        if danger {
            content.buttonStyle(DangerButtonStyle())
        } else {
            content.buttonStyle(PrimaryButtonStyle())
        }
    }
}

extension View {
    fileprivate func anyButton(danger: Bool) -> some View { modifier(AnyButton(danger: danger)) }
}

/// 一张状态卡（原型 `.stat`）：11 的标签行（图标 + 字）、20 的主值（末尾小字是单位）、
/// 11 的脚注。底 `panel-2`、圆角 `r-12`、发丝描边、内边距 `s14`。
private struct StatusStatCard: View {
    let stat: SystemStat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DmSpace.s6) {
                LucideIcon(stat.icon, size: DmIcon.i12)
                    .foregroundColor(Color.dmInk3)
                Text(stat.label)
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
            }

            HStack(alignment: .firstTextBaseline, spacing: DmSpace.s2) {
                Text(stat.value)
                    .font(.system(size: DmText.t20, weight: .semibold))
                    .kerning(-0.4)
                    .monospacedDigit()
                    .foregroundColor(Color.dmInk)
                if !stat.unit.isEmpty {
                    Text(stat.unit)
                        .font(.system(size: DmText.t12))
                        .foregroundColor(Color.dmInk3)
                }
            }
            .padding(.top, DmSpace.s6)

            Text(stat.note)
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(stat.isWarning ? Color.dmWarnInkStrong : Color.dmInk3)
                .lineLimit(1)
                .padding(.top, DmSpace.s4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DmSpace.s14)
        .dmCard()
    }
}

/// 存储空间卡（原型硬盘卡的位置）：卡头（卷名）→ 进度条 → 脚注。
///
/// 进度条画的是**卷**的已用占比。原型这里是每块盘一条，接口不给单盘已用量，
/// 所以这一格只能落在存储空间上；单盘信息在右边那张卡。
/// 🔴 不画读写速度：那是瞬时量，页面是快照形态（进页取一次 + 手动刷），
/// 屏上的数字离取样可能已隔几分钟，显示出来只会误导（2026-10-18 用户拍板删除）。
private struct StorageCard: View {
    let volume: StorageVolume?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DmSpace.s8) {
                Text(volume?.name ?? "存储空间")
                    .font(.system(size: DmText.t13, weight: .semibold))
                    .foregroundColor(Color.dmInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.bottom, DmSpace.s10)

            DmProgressBar(value: volume?.usedPercent ?? 0)
                .padding(.top, DmSpace.s8)

            Text(footnote)
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(Color.dmInk3)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DmSpace.s8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DmSpace.s14)
        .dmCard()
    }

    private var footnote: String {
        guard let volume else { return "没读到容量" }
        let used = FileEntry.byteText(volume.usedBytes)
        let total = FileEntry.byteText(volume.totalBytes)
        let percent = String(format: "%.1f%%", volume.usedPercent * 100)
        return "已用 \(used) / \(total)（\(percent)）· 可用 \(FileEntry.byteText(volume.freeBytes))"
            + (volume.isHealthy ? "" : " · \(volume.status)")
    }
}

/// 硬盘卡（列表卡：卡头 + 一行一块盘）。每行给温度明细与状态徽章。
private struct DiskCard: View {
    let disks: [StorageDisk]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DmSpace.s8) {
                Text("硬盘")
                    .font(.system(size: DmText.t13, weight: .semibold))
                    .foregroundColor(Color.dmInk)
                Spacer(minLength: 0)
                if !disks.isEmpty {
                    Text("\(disks.count) 块")
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                }
            }
            .padding(.horizontal, DmSpace.s14)
            .padding(.top, DmSpace.s14)
            .padding(.bottom, DmSpace.s10)

            if disks.isEmpty {
                Text("没读到硬盘清单")
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
                    .padding(.horizontal, DmSpace.s14)
                    .padding(.bottom, DmSpace.s14)
            } else {
                ForEach(Array(disks.enumerated()), id: \.element.id) { index, disk in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.dmLine)
                            .frame(height: DmLine.hairline)
                    }
                    DiskRow(disk: disk)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 列表卡：内边距 0，行自带内边距（第八节「卡片」）。
        .dmCard()
    }
}

/// 一块盘的一行（原型 `.srow`：内边距 12/14，行间发丝）。
/// 🔴 不画瞬时读写 —— 快照页上的速率只会误导（与存储卡同一理由）。
private struct DiskRow: View {
    let disk: StorageDisk

    var body: some View {
        HStack(spacing: DmSpace.s12) {
            LucideIcon("hard-drive", size: DmIcon.i16)
                .foregroundColor(Color.dmInk2)

            VStack(alignment: .leading, spacing: DmSpace.s2) {
                Text(disk.name)
                    .font(.system(size: DmText.t13))
                    .foregroundColor(Color.dmInk)
                Text(detail)
                    .font(.system(size: DmText.t11))
                    .monospacedDigit()
                    .foregroundColor(Color.dmInk3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            DmBadge(statusText, tone: disk.isHealthy ? .ok : .danger)
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s10)
    }

    /// 型号 · 容量 · 温度。剩余寿命按 `trustable` 判 —— 机械盘回的是
    /// `{"trustable": true, "value": -1}`，`-1` 是「不适用」，直接显示就是「-1%」。
    private var detail: String {
        var parts: [String] = []
        if !disk.model.isEmpty { parts.append(disk.model) }
        parts.append(FileEntry.byteText(disk.sizeBytes))
        parts.append("\(disk.temperature) °C")
        if disk.remainLifeTrustable, disk.remainLifePercent >= 0 {
            parts.append("寿命 \(disk.remainLifePercent)%")
        }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        if disk.isHealthy { return "正常" }
        return disk.status.isEmpty ? "异常" : disk.status
    }
}

/// 空态 / 载入 / 错误三种静场（与文件页 `FilesNotice`、曲库页 `LibraryNotice` 同一形态）。
private struct StatusNotice: View {
    let icon: String
    let title: String
    let note: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: DmSpace.s12) {
            LucideIcon(icon, size: DmIcon.i24)
                .foregroundColor(Color.dmInk3)
            Text(title)
                .font(.system(size: DmText.t15, weight: .semibold))
                .foregroundColor(Color.dmInk2)
            Text(note)
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, DmSpace.s2)
            }
        }
        .padding(DmSpace.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

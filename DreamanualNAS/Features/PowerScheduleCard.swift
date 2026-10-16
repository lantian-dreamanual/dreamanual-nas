import SwiftUI

/// 开关机计划页的状态：**服务端那一份**与**界面上在编的那一份**。
///
/// 两份分开是这套界面的要害：拨开关只动 `draft`，「保存到 NAS」才写回，
/// 「放弃修改」就是把 `draft` 丢回 `server`（原型那句「改完一次性写回」说的就是它）。
/// 与系统状态快照同一归属（挂在 `AppState` 上）—— 换模块再回来，改到一半的开关还在。
@MainActor
@Observable
final class PowerScheduleModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// 一次保存的下场，给调用点决定提示什么。
    enum SaveOutcome: Equatable {
        case saved
        /// 服务端回读的那一份与提交的不同（这个接口会静默剥掉非法的 `weekdays`）。
        case drifted
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// 服务端那一份。保存后放的是**回读**的那一份，不是提交的那一份。
    private(set) var server: PowerSchedule?
    /// 界面上在编的那一份。
    private(set) var draft: PowerSchedule?
    private(set) var isSaving = false
    /// 上一次保存失败的原因（卡片页脚那一行）。改一次或存成功就清掉。
    private(set) var saveNote: String?

    /// 界面上画的就是这一份。
    var tasks: [PowerTask] { draft?.tasks ?? [] }

    var isDirty: Bool { draft != nil && draft != server }

    /// 拉一次。默认不刷新已有数据 —— 换模块回来不该白发一轮请求，
    /// 更不该把用户改到一半的草稿冲掉（`server != nil` 时直接返回）。
    func load(on manager: SessionManager?, force: Bool = false) async {
        guard let manager else { return }
        if !force, server != nil || phase == .loading { return }
        phase = .loading
        do {
            let schedule = try await PowerScheduleAPI.load(manager)
            server = schedule
            draft = schedule
            saveNote = nil
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 拨一条的开关。**只动草稿，不碰 NAS** —— 写回是页脚那颗按钮的事。
    func toggle(_ index: Int) {
        guard var draft, draft.tasks.indices.contains(index) else { return }
        draft.tasks[index].enabled.toggle()
        self.draft = draft
        saveNote = nil
    }

    func discard() {
        draft = server
        saveNote = nil
    }

    /// 写回 NAS 并**以回读为准**收工。
    ///
    /// 🔴 两次都比对：判据是服务端回读的那一份，不是 `save` 的返回值 ——
    /// 这个接口对非法 `weekdays` 是静默剥掉（照回 `success`，那条任务变空星期），
    /// 与评分接口对不存在的 id 照样回 `success` 同一族。
    @discardableResult
    func save(on manager: SessionManager?) async -> SaveOutcome {
        guard let manager, let draft, isDirty else { return .saved }
        isSaving = true
        defer { isSaving = false }
        do {
            let confirmed = try await PowerScheduleAPI.save(draft, on: manager)
            server = confirmed
            self.draft = confirmed
            saveNote = nil
            phase = .ready
            return confirmed == draft ? .saved : .drifted
        } catch {
            saveNote = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// 断开时清掉 —— 换了机器或换了一条链路，计划表不作数，改到一半的草稿也不该留下。
    func clear() {
        server = nil
        draft = nil
        phase = .idle
        saveNote = nil
        isSaving = false
    }

    /// 冒烟用：把两份状态各打一行 —— 屏幕上**看不出来**的那几件（服务端几份、
    /// 草稿脏没脏、`weekdays` 解成了什么、星期那列压成了什么字）靠它对。
    var dumpLines: [String] {
        var out: [String] = []
        out.append("阶段 \(phase) · 服务端 \(server.map { String($0.tasks.count) } ?? "—") 条"
                   + " · 草稿 \(draft.map { String($0.tasks.count) } ?? "—") 条"
                   + " · 未保存 \(isDirty ? "是" : "否")")
        for (index, task) in tasks.enumerated() {
            out.append("#\(index) \(task.kind.label) \(task.weekdayText) \(task.timeText)"
                       + " 开关\(task.enabled ? "开" : "关")"
                       + " · weekdays=\(task.weekdays.map(String.init).joined(separator: ","))")
        }
        if let saveNote { out.append("上次保存失败：\(saveNote)") }
        return out
    }
}

/// 开关机计划卡（原型系统状态屏下半右卡）。
///
/// 形态是**列表卡**（`dmCard()`，内边距 0，卡头与页脚自带 `s14`）：
/// 卡头（题头 + 未保存徽章）→ 一行一条计划（星期 · 时刻 · 开机/关机徽章 · 开关，
/// 行间发丝）→ 页脚（左端错误行、右端「放弃修改 / 保存到 NAS」）。
///
/// **本批只做开启与关闭**：读计划、逐条拨开关、一次性写回。条目的新增与删除、
/// 以及立刻关机 / 重启是后面两批 —— 关机真执行过就拔掉了这台机器，而它不在本机
/// 广播域里、软件唤醒做不到（`docs/接口结论.md` 第二节）。
struct PowerScheduleCard: View {
    @Environment(AppState.self) private var state

    private var model: PowerScheduleModel { state.powerSchedule }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            content
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dmCard()
    }

    /// 卡头：题头 + 右侧（改动未存时给徽章，否则给条数）。
    private var head: some View {
        HStack(spacing: DmSpace.s8) {
            Text("开关机计划")
                .font(.system(size: DmText.t13, weight: .semibold))
                .foregroundColor(Color.dmInk)
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.isDirty {
                DmBadge("未保存", tone: .warn)
            } else if !model.tasks.isEmpty {
                Text("\(model.tasks.count) 条")
                    .font(.system(size: DmText.t11))
                    .monospacedDigit()
                    .foregroundColor(Color.dmInk3)
            }
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.top, DmSpace.s14)
        .padding(.bottom, DmSpace.s10)
    }

    @ViewBuilder
    private var content: some View {
        if !model.tasks.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(model.tasks.enumerated()), id: \.offset) { index, task in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.dmLine)
                            .frame(height: DmLine.hairline)
                    }
                    PowerScheduleRow(task: task) { model.toggle(index) }
                }
            }
        } else if case let .failed(reason) = model.phase {
            note("没能读到开关机计划", detail: reason, actionTitle: "重试") {
                Task { await model.load(on: state.sessionManager, force: true) }
            }
        } else if model.phase == .loading {
            note("正在读取开关机计划…", detail: "读的是 NAS 侧保存的那一份。")
        } else {
            note("这台机器还没设开关机计划",
                 detail: "计划由 NAS 侧的「硬件和电源」保存，这里只能读与改。")
        }
    }

    /// 卡内静场（读取中 / 读不到 / 空表三种）。与卡片内边距一致，横竖都贴 `s14`。
    private func note(
        _ title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: DmSpace.s10) {
            LucideIcon("calendar-clock", size: DmIcon.i16)
                .foregroundColor(Color.dmInk3)
                .padding(.top, DmSpace.s2)
            VStack(alignment: .leading, spacing: DmSpace.s2) {
                Text(title)
                    .font(.system(size: DmText.t13))
                    .foregroundColor(Color.dmInk2)
                Text(detail)
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DmSpace.s12)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.bottom, DmSpace.s14)
    }

    /// 页脚：左端放上一次保存的失败原因，右端两颗按钮。
    ///
    /// 两颗按钮都按 `isDirty` 判禁用 —— 没改动时「保存到 NAS」没有可写的东西，
    /// 让它可点会写成一次无谓的请求（这个接口的写是整表覆盖）。
    private var footer: some View {
        HStack(spacing: DmSpace.s8) {
            if let saveNote = model.saveNote {
                LucideIcon("triangle-alert", size: DmIcon.i12)
                    .foregroundColor(Color.dmDangerInk)
                Text(saveNote)
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmDangerInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DmSpace.s12)
            Button("放弃修改") { model.discard() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!model.isDirty || model.isSaving)
            Button(model.isSaving ? "正在写入…" : "保存到 NAS") {
                Task {
                    let outcome = await model.save(on: state.sessionManager)
                    switch outcome {
                    case .saved:
                        state.showToast("开关机计划已保存到 NAS", .ok)
                    case .drifted:
                        // 服务端回读与提交的不同（它会静默剥掉非法星期这类东西）
                        // —— 不说明的话，用户只看见自己拨的开关弹回去了。
                        state.showToast("已写入，但服务端回读与提交的不同，界面已按服务端那一份显示", .info)
                    case let .failed(reason):
                        state.showToast(reason, .err)
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.isDirty || model.isSaving)
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
    }
}

/// 一条计划行（原型 `.sched-row`：内边距 10/14，行间发丝）。
///
/// 四格：星期（定宽一栏，题取 `ink-2`）· 时刻（等宽数字，13/500）·
/// 开机 / 关机徽章 · 右端开关。停用的那一条整行压一档（字转 `ink-3`、徽章转中性），
/// 这样「排了但没启用」一眼分得出来，不必去读开关的滑块在哪边。
private struct PowerScheduleRow: View {
    let task: PowerTask
    let onToggle: () -> Void

    /// 星期那一栏的定宽。原型 `.sched-row .d` 是 52，那是以「每天 / 单日」三种
    /// 形态画的；真实计划里最短的长组合是连排区间（`周二至周五`，5 个字），
    /// 52 装不下会把时刻列挤歪 —— 抬到 68 让它也落进栏宽。更长的组合（逐个
    /// 列出四天以上）自然长出去，不截断：栏对不齐总比字被裁掉强。
    private static let weekdayWidth: CGFloat = 68

    var body: some View {
        HStack(spacing: DmSpace.s10) {
            Text(task.weekdayText)
                .font(.system(size: DmText.t12))
                .foregroundColor(task.enabled ? Color.dmInk2 : Color.dmInk3)
                .lineLimit(1)
                .frame(minWidth: Self.weekdayWidth, alignment: .leading)

            Text(task.timeText)
                .font(.system(size: DmText.t13, weight: .medium))
                .monospacedDigit()
                .foregroundColor(task.enabled ? Color.dmInk : Color.dmInk3)

            DmBadge(task.kind.label, tone: badgeTone)

            Spacer(minLength: DmSpace.s12)

            Toggle("", isOn: Binding(get: { task.enabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(DmToggleStyle())
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s10)
    }

    /// 开关机两态各占一个语义色（原型 `.pill ok` / `.pill warn`）；停用的一律中性
    /// —— 一颗亮着语义色的徽章配一个关着的开关会自相矛盾。
    private var badgeTone: DmBadge.Tone {
        guard task.enabled else { return .neutral }
        return task.kind == .poweron ? .ok : .warn
    }
}

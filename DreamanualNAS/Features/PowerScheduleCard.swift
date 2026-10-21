import SwiftUI

/// 开关机计划页的状态：**一份列表，操作即写回**。
///
/// 每个操作（拨开关 / 删除）先改本地这份 —— 界面立即变 —— 再把「提交 → 回读核对」
/// 排到串行写回链上；失败就把这份恢复成操作前的样子，原因挂在 `failureNote`。
/// 没有单独的「保存」按钮，也没有「未保存」这个状态。写回期间操作全部锁住
/// （行开关禁用、右键不出菜单、新增钮禁用），不与在途写回打架；离线摆样
/// （manager 为空）时只改本地、不排队。
@MainActor
@Observable
final class PowerScheduleModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// 界面显示、也是「当前生效」的那一份。写回成功后放**回读**的那一份
    /// （这个接口会静默剥掉非法 `weekdays`，以回读为准，不是提交的那份）。
    private(set) var tasks: [PowerTask] = []
    /// 有写回在途：行开关禁用、右键菜单不出、新增钮禁用。
    private(set) var isWriting = false
    /// 上一次写回失败的原因（页脚那一行）。下一次操作或读成功就清掉。
    private(set) var failureNote: String?

    /// 冒烟用（`DM_STATUS=failtoggle`）：置上之后写回一律假失败（不发请求），
    /// 专门验「失败 → 本地回滚」这条腿；网络层的失败与它共用同一个 catch。
    var smokeFailWrites = false

    /// 写回串行链：把每次「提交 → 回读核对」排在上一把后面，连续操作不并发打架。
    private var writeChain: Task<Void, Never>?

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    /// 拉一次。默认不刷新已有数据 —— 换模块回来不该白发一轮请求。
    func load(on manager: SessionManager?, force: Bool = false) async {
        guard let manager else { return }
        if !force, phase == .ready || phase == .loading { return }
        phase = .loading
        do {
            let schedule = try await PowerScheduleAPI.load(manager)
            tasks = schedule.tasks
            failureNote = nil
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 拨一条的开关。乐观：界面立即变，写回在链上排队。
    func toggle(_ index: Int, on manager: SessionManager?) {
        mutate(on: manager) { tasks in
            guard tasks.indices.contains(index) else { return false }
            tasks[index].enabled.toggle()
            return true
        }
    }

    /// 删一条（右键菜单）。乐观：界面立即变，写回在链上排队。
    /// 写回是整表覆盖，失败整份恢复，所以不设确认弹层。
    func remove(_ index: Int, on manager: SessionManager?) {
        mutate(on: manager) { tasks in
            guard tasks.indices.contains(index) else { return false }
            tasks.remove(at: index)
            return true
        }
    }

    /// 弹窗提交：追加（`index` = nil）或整条替换，**当场等写回结果** ——
    /// 成功弹窗才关，失败留在弹窗里（填的字不丢）。与行操作共用 `isWriting`
    /// 这把锁：弹窗开着时行开关是禁用的，两边不会并发写。
    /// 星期只收 0–6（🔴 给 7 服务端会静默剥成空串，见 `PowerTask.weekdays`）。
    /// manager 为空（离线摆样）时只改本地、直接算成功。
    @discardableResult
    func commit(_ task: PowerTask, replacing index: Int?, on manager: SessionManager?) async -> Bool {
        guard isReady, !isWriting else { return false }
        var updated = tasks
        if let index {
            guard updated.indices.contains(index) else { return false }
            updated[index] = task
        } else {
            updated.append(task)
        }
        guard let manager else {
            tasks = updated
            return true
        }
        let before = tasks
        tasks = updated
        isWriting = true
        defer { isWriting = false }
        do {
            let confirmed = try await PowerScheduleAPI.save(
                PowerSchedule(tasks: updated), on: manager)
            tasks = confirmed.tasks
            return true
        } catch {
            tasks = before
            failureNote = error.localizedDescription
            return false
        }
    }

    /// 乐观写回的公共底座：先改本地，再把提交排在写回链尾；失败恢复 `before`。
    private func mutate(on manager: SessionManager?, _ change: (inout [PowerTask]) -> Bool) {
        var updated = tasks
        guard change(&updated) else { return }
        let before = tasks
        tasks = updated
        failureNote = nil
        guard let manager else { return }   // 离线摆样：只动本地
        let submitted = updated
        let previous = writeChain ?? Task {}
        writeChain = Task { [weak self] in
            await previous.value
            await self?.writeAndVerify(submitted, rollbackTo: before, on: manager)
        }
    }

    /// 提交 → 回读核对。🔴 判据是回读的那一份，不是 `save` 的返回值：
    /// 这个接口对非法 `weekdays` 是静默剥掉（照回 `success`，那条任务变空星期），
    /// 与评分接口对不存在的 id 照样回 `success` 同一族。
    private func writeAndVerify(
        _ submitted: [PowerTask], rollbackTo before: [PowerTask], on manager: SessionManager
    ) async {
        isWriting = true
        defer { isWriting = false }
        do {
            if smokeFailWrites {
                throw PowerScheduleError.badResponse("冒烟：写回假失败（没发请求）")
            }
            let confirmed = try await PowerScheduleAPI.save(
                PowerSchedule(tasks: submitted), on: manager)
            tasks = confirmed.tasks
            phase = .ready
        } catch {
            tasks = before
            failureNote = error.localizedDescription
        }
    }

    /// 断开时清掉 —— 换了机器或换了一条链路，计划表不作数。
    func clear() {
        tasks = []
        phase = .idle
        failureNote = nil
        isWriting = false
        smokeFailWrites = false
        writeChain = nil
    }

    /// 冒烟用（`DM_STATUS=schedmock`）：不碰网络灌一份与真机同形的计划，
    /// 供离线摆界面截图。
    func injectMock() {
        tasks = [
            PowerTask(kind: .poweroff, enabled: true, hour: 0, minute: 30, weekdays: [2, 3, 4, 5]),
            PowerTask(kind: .poweron, enabled: true, hour: 9, minute: 0, weekdays: [1, 2, 3, 4, 5]),
            PowerTask(kind: .poweron, enabled: true, hour: 10, minute: 30, weekdays: [0, 6]),
        ]
        failureNote = nil
        phase = .ready
    }

    /// 冒烟用：等在途写回落定（先让一拍再轮询，链上的下一把可能刚要起）。
    func waitWritesSettled() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0..<200 where isWriting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 冒烟用：把状态各打一行 —— 屏幕上**看不出来**的那几件（几条、在写没有、
    /// `weekdays` 解成了什么）靠它对。
    var dumpLines: [String] {
        var out: [String] = []
        out.append("阶段 \(phase) · \(tasks.isEmpty ? "—" : String(tasks.count)) 条"
                   + " · 在写 \(isWriting ? "是" : "否")")
        for (index, task) in tasks.enumerated() {
            out.append("#\(index) \(task.kind.label) \(task.weekdayText) \(task.timeText)"
                       + " 开关\(task.enabled ? "开" : "关")"
                       + " · weekdays=\(task.weekdays.map(String.init).joined(separator: ","))")
        }
        if let failureNote { out.append("上次写回失败：\(failureNote)") }
        return out
    }
}

/// 开关机计划卡（原型系统状态屏下半右卡）。
///
/// 形态是**列表卡**（`dmCard()`，内边距 0，卡头与页脚自带 `s14`）：
/// 卡头（题头 + 条数）→ 一行一条计划（星期 · 时刻 · 开机/关机徽章 · 开关，
/// 行间发丝）→ 页脚（左端失败行、右端「新增任务」）。
/// 行操作即写回：开关拨了就提交；编辑与删除走行右键菜单（悬浮整行提示可点），
/// 新增走 `PowerAddCard` 弹窗 —— 三个入口全部当场写 NAS，失败原样回退。
struct PowerScheduleCard: View {
    @Environment(AppState.self) private var state

    private var model: PowerScheduleModel { state.powerSchedule }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            content
            // 等高并排（Grid 行）：比电源卡高时行高随本卡；比它矮时卡面拉到行高，
            // 这颗 Spacer 把页脚按回卡底（未被拉伸时高度为 0）。
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dmCard()
    }

    /// 卡头：题头 + 右侧条数。
    private var head: some View {
        HStack(spacing: DmSpace.s8) {
            Text("开关机计划")
                .font(.system(size: DmText.t13, weight: .semibold))
                .foregroundColor(Color.dmInk)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !model.tasks.isEmpty {
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
                    PowerScheduleRow(
                        task: task,
                        isWriting: model.isWriting,
                        onToggle: { model.toggle(index, on: state.sessionManager) },
                        onContext: { point in
                            state.openPowerRowMenu(index, at: point)
                        }
                    )
                }
            }
        } else if case let .failed(reason) = model.phase {
            note("无法读取开关机计划", detail: reason, actionTitle: "重试") {
                Task { await model.load(on: state.sessionManager, force: true) }
            }
        } else if model.phase == .loading {
            note("正在读取开关机计划…", detail: "读的是 NAS 侧保存的那一份。")
        } else {
            note("这台机器还没设开关机计划",
                 detail: "计划保存在 NAS 上，这里可以查看与修改。",
                 actionTitle: "新增计划") {
                state.openPowerAdd()
            }
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
                    .buttonStyle(SecondaryButtonStyle(on: .card))
            }
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.bottom, DmSpace.s14)
    }

    /// 页脚：左端放上一次写回失败的原因（操作已回退），右端「新增任务」。
    private var footer: some View {
        HStack(spacing: DmSpace.s8) {
            if let failureNote = model.failureNote {
                LucideIcon("triangle-alert", size: DmIcon.i12)
                    .foregroundColor(Color.dmDangerInk)
                Text(failureNote)
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmDangerInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DmSpace.s12)
            Button("新增计划") { state.openPowerAdd() }
                .buttonStyle(SecondaryButtonStyle(on: .card))
                .disabled(model.isWriting)
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
/// 三格：星期（定宽一栏，题取 `ink-2`）· 时刻（等宽数字，13/500）· 开机/关机徽章，
/// 右端开关。停用的那一条整行压一档（字转 `ink-3`、徽章转中性），这样「排了但
/// 没启用」一眼分得出来，不必去读开关的滑块在哪边。
///
/// 编辑与删除在**行右键菜单**里（桌面应用惯例，入口不常驻行上）；悬浮给 `panel-3`
/// 一档背板示意整行可点。开关拨了当场写 NAS —— 写回期间禁用，写完自动回来。
private struct PowerScheduleRow: View {
    let task: PowerTask
    let isWriting: Bool
    let onToggle: () -> Void
    let onContext: (CGPoint) -> Void

    @State private var isHovered = false

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
                .disabled(isWriting)
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s10)
        // 悬浮背板与右键捕获层：编辑 / 删除的入口在菜单里，悬浮给 `panel-3` 一档
        // （主区悬停口径）示意整行可点；捕获层只接右键，左键与悬停照常穿透。
        .background(
            Rectangle().fill(isHovered ? Color.dmPanel3 : Color.clear)
        )
        .trackingHover($isHovered)
        .overlay { RightClickCatcher(onRightClick: onContext) }
    }

    /// 开关机两态各占一个语义色（原型 `.pill ok` / `.pill warn`）；停用的一律中性
    /// —— 一颗亮着语义色的徽章配一个关着的开关会自相矛盾。
    private var badgeTone: DmBadge.Tone {
        guard task.enabled else { return .neutral }
        return task.kind == .poweron ? .ok : .warn
    }
}

/// 新增 / 编辑计划任务的弹窗（挂根视图的 `.dmModal`，与写操作弹窗同层）。
///
/// 三个字段：类型（开机 / 关机，分段控件）· 时刻（时 / 分两个数字框）·
/// 星期（七颗可多选的片）。**提交当场写 NAS**：成功关弹窗、失败留在弹窗里
/// （填的字不丢，改完再试或取消）。编辑模式预填那一条的现状。
///
/// 校验都落在本地：时刻必须落在 0–23 时 / 0–59 分、星期至少选一天 —— 后一条
/// 还挡着接口的坑：`weekdays` 空串虽然服务端收，但那条任务等于白排（读回来
/// 显示「未设星期」）；界面上也不产出 6 以外的数字（给 7 会被静默剥掉）。
struct PowerAddCard: View {
    enum Mode {
        /// 追加一条到表尾。
        case add
        /// 编辑第 `index` 条（预填现状）。
        case edit(index: Int, task: PowerTask)
    }

    @Environment(AppState.self) private var state

    private var model: PowerScheduleModel { state.powerSchedule }

    let mode: Mode

    @State private var kind: PowerTask.Kind = .poweron
    @State private var hourText = "09"
    @State private var minuteText = "00"
    /// 缺省给工作日 —— 与这台机器现有开机计划最常见的形态同拍。
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var isSubmitting = false

    init(mode: Mode) {
        self.mode = mode
        if case let .edit(_, task) = mode {
            _kind = State(initialValue: task.kind)
            _hourText = State(initialValue: String(format: "%02d", task.hour))
            _minuteText = State(initialValue: String(format: "%02d", task.minute))
            _weekdays = State(initialValue: Set(task.weekdays))
        }
    }

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        DmModalCard(title: isEdit ? "编辑开关机计划" : "新增开关机计划",
                    onClose: { state.closePowerEditor() }) {
            VStack(alignment: .leading, spacing: DmSpace.s6) {
                FormLabel("类型")
                DmSegmented(
                    PowerTask.Kind.allCases, selection: $kind,
                    fillsWidth: true, on: .panel,
                    label: { $0.label }
                )
            }

            VStack(alignment: .leading, spacing: DmSpace.s6) {
                FormLabel("时刻")
                HStack(spacing: DmSpace.s6) {
                    TextField("", text: $hourText)
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .formField(on: .panel)
                        .frame(width: 56)
                    Text(":")
                        .font(.system(size: DmText.t13))
                        .foregroundColor(Color.dmInk3)
                    TextField("", text: $minuteText)
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .formField(on: .panel)
                        .frame(width: 56)
                    Text("24 小时制")
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                    Spacer(minLength: 0)
                }
                if case let .time(text) = problem {
                    hint(text, isBad: true)
                }
            }

            VStack(alignment: .leading, spacing: DmSpace.s6) {
                FormLabel("星期")
                HStack(spacing: DmSpace.s4) {
                    ForEach(PowerTask.weekOrder, id: \.self) { day in
                        weekdayChip(day)
                    }
                }
                if case let .weekdays(text) = problem {
                    hint(text, isBad: true)
                }
            }

            if problem == nil {
                hint(isEdit ? "保存后立即写回 NAS。" : "添加后立即写回 NAS。",
                     isBad: false)
            }
        } foot: {
            Button("取消") { state.closePowerEditor() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isSubmitting)
            Button(isEdit ? "保存" : "添加", action: submit)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(problem != nil || isSubmitting)
        }
    }

    /// 本地校验：时刻越界或星期一个没选。`nil` = 可以提交。
    private var problem: Problem? {
        if hour == nil || minute == nil {
            return .time("时刻要落在 0–23 时 / 0–59 分。")
        }
        if weekdays.isEmpty {
            return .weekdays("至少选一天。")
        }
        return nil
    }

    private enum Problem {
        case time(String)
        case weekdays(String)
    }

    private var hour: Int? {
        guard let value = Int(hourText.trimmingCharacters(in: .whitespaces)),
              (0...23).contains(value) else { return nil }
        return value
    }

    private var minute: Int? {
        guard let value = Int(minuteText.trimmingCharacters(in: .whitespaces)),
              (0...59).contains(value) else { return nil }
        return value
    }

    /// 一颗星期片：选中的走「小块」轨道（`accent-fill` 实底 + `on-accent` 深字），
    /// 未选中的抬进卡内一档（`panel-2` 底 + 发丝描边）—— 与输入框同一底色。
    private func weekdayChip(_ day: Int) -> some View {
        let isSelected = weekdays.contains(day)
        return Button {
            if isSelected { weekdays.remove(day) } else { weekdays.insert(day) }
        } label: {
            Text(PowerTask.dayName(day))
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(isSelected ? Color.dmOnAccent : Color.dmInk2)
                .padding(.horizontal, DmSpace.s6)
                .padding(.vertical, DmSpace.s4)
                .background(
                    RoundedRectangle(cornerRadius: DmRadius.r6)
                        .fill(isSelected ? Color.dmAccentFill : Color.dmPanel2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DmRadius.r6)
                        .strokeBorder(isSelected ? Color.clear : Color.dmLine2,
                                      lineWidth: DmLine.hairline)
                )
                .contentShape(RoundedRectangle(cornerRadius: DmRadius.r6))
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String, isBad: Bool) -> some View {
        HStack(spacing: DmSpace.s6) {
            LucideIcon(isBad ? "triangle-alert" : "info", size: DmIcon.i12)
                .foregroundColor(isBad ? Color.dmDangerInk : Color.dmInk3)
            Text(text)
                .font(.system(size: DmText.t11))
                .foregroundColor(isBad ? Color.dmDangerInk : Color.dmInk3)
            Spacer(minLength: 0)
        }
    }

    private func submit() {
        guard let hour, let minute, !weekdays.isEmpty else { return }
        // 编辑保留那一条的启用态（启用与否是行上的开关管的事，弹窗不改它）。
        let original: PowerTask?
        if case let .edit(_, task) = mode { original = task } else { original = nil }
        let task = PowerTask(
            kind: kind, enabled: original?.enabled ?? true,
            hour: hour, minute: minute,
            weekdays: weekdays.sorted()
        )
        let editIndex: Int?
        if case let .edit(index, _) = mode { editIndex = index } else { editIndex = nil }
        isSubmitting = true
        Task {
            let saved = await model.commit(task, replacing: editIndex,
                                           on: state.sessionManager)
            isSubmitting = false
            if saved {
                state.showToast(isEdit ? "开关机计划已更新" : "开关机计划已写入 NAS", .ok)
                state.closePowerEditor()
            }
            // 失败留在弹窗：填的字不丢，改完再试或取消。
        }
    }
}

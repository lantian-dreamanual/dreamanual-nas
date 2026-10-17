import SwiftUI

/// 连接页：QuickConnect ID 或直连地址 + 账号密码。
///
/// 形态对着密码管理的解锁页（`.lock-card`）落：整屏 `bg`、卡片居中、卡内一律左对齐
/// （标记 → 标题 → 分段 → 字段 → 主按钮 → 状态行）。卡片取 `panel-2` + `line` 1px
/// + `r-16` + `shadow-card`，与 `.lock-card` 同一套角色；宽度按本页内容收到 420。
/// 两种连接方式走分段切换，密码连上即存本机凭据文件（0600，见 CredentialStore）。
struct ConnectView: View {
    @Environment(AppState.self) private var state

    enum Mode: Hashable { case quickconnect, direct }

    /// 本页四个输入框。焦点用来切输入法：进任一框切 ASCII，全部离开再还原。
    private enum Field: Hashable { case qcID, directAddress, account, password }

    @State private var mode: Mode = .quickconnect
    @State private var password = ""
    /// 密码框挡下全角/中文字符时的即时说明（说清第几位，别让用户自己数）。
    @State private var passwordNote: String?
    @FocusState private var focused: Field?

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 0) {
            DmBrandMark(size: 48)
                .padding(.bottom, DmSpace.s16)

            Text("Dreamanual NAS 助手")
                .font(.system(size: DmText.t20, weight: .semibold))
                .kerning(-0.2)
                .foregroundColor(Color.dmInk)

            Text("仅支持管理群晖 NAS")
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
                .padding(.top, DmSpace.s4)
                .padding(.bottom, DmSpace.s24)

            DmSegmented([.quickconnect, .direct], selection: $mode, fillsWidth: true, on: .card) {
                $0 == .quickconnect ? "QuickConnect" : "直连地址"
            }
            .disabled(isLocked)
            .opacity(isLocked ? 0.5 : 1)
            .padding(.bottom, DmSpace.s16)

            switch mode {
            case .quickconnect:
                field("QuickConnect ID") {
                    TextField("例如 mynas", text: $state.qcID)
                        .formField(on: .card)
                        .focused($focused, equals: .qcID)
                        .onSubmit { submit() }
                }
            case .direct:
                field("直连地址") {
                    TextField("主机或主机:端口（局域网 / Tailscale）", text: $state.directAddress)
                        .formField(on: .card)
                        .focused($focused, equals: .directAddress)
                        .onSubmit { submit() }
                }
            }

            field("账号") {
                TextField("DSM 账号", text: $state.username)
                    .formField(on: .card)
                    .focused($focused, equals: .account)
                    .onSubmit { submit() }
            }

            field("密码") {
                VStack(alignment: .leading, spacing: DmSpace.s8) {
                    SecureField(
                        // 有存凭据时空着也行：连接时会取本机存的那条。
                        password.isEmpty && state.hasSavedPassword(for: selectedMethod)
                            ? "留空则用已保存的密码" : "DSM 密码",
                        text: passwordBinding)
                        .formField(on: .card)
                        .focused($focused, equals: .password)
                        .onSubmit { submit() }

                    if let passwordNote {
                        noteLine(passwordNote)
                    }
                }
            }

            Button {
                submit()
            } label: {
                Text("连接").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSubmitDisabled)
            .keyboardShortcut(.defaultAction)
            // 最后一个字段的 14 + 这里的 16 = 30，与 `.lock-actions` 的节奏一致。
            .padding(.top, DmSpace.s16)

            statusLine
                .padding(.top, DmSpace.s14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 卡片节奏对齐密码管理 `.lock-card`：内边距 34/32/26、标记下 16、
        // 标题块下 24、字段间 14、按钮前 14+16。这几个是容器级大留白
        // （vault 也按布局值保留裸值），不进尺度档。
        .padding(.top, 34)
        .padding(.horizontal, 32)
        .padding(.bottom, 26)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r16).fill(Color.dmPanel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r16)
                .strokeBorder(Color.dmLine, lineWidth: DmLine.base)
        )
        .dmShadowCard()
        // 卡片在窗口里居中；窗口高度不够时内容自己滚（与密码管理解锁页同款取舍）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dmBg)
        // 焦点进任一输入框就把输入法切到 ASCII，四个框都离开再还原 ——
        // 让用户自己去切输入法是把这个坑转嫁给他（中文输入法的 `!` 是全角）。
        .onChange(of: focused) { _, now in
            if now == nil { InputSource.restore() } else { InputSource.enterASCII() }
        }
        // 连接一起来就把焦点摘掉：控件锁上后光标留在里面，看着像还能打字，
        // 输入法也还挂在 ASCII 上。
        .onChange(of: isLocked) { _, locked in
            if locked { focused = nil }
        }
        .onDisappear { InputSource.restore() }
}

    /// 一个字段：标签在上、控件在下，间距 `s6`；字段之间 `s14`。
    ///
    /// 连接进行中（含自动连的退避等待）连控件一起锁住并压暗 —— 与产品线其它
    /// 禁用态同一语言（图标按钮、开关、主按钮都是整体 0.5）。标签不动：
    /// 变暗的是「现在不能改的那个框」，标签还是得读得清。
    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DmSpace.s6) {
            FormLabel(label)
            content()
                .disabled(isLocked)
                .opacity(isLocked ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DmSpace.s14)
    }

    /// 密码框的绑定：DSM 密码只可能是半角 ASCII。中文输入法下打 `!` 得到的是
    /// 全角「！」，长度不变、内容差一位，送出去只会换回 Auth 400 ——
    /// 真机上就是这么被卡住的（用户输 12 位、已存凭据也是 12 位）。挡在入口，
    /// 并说清第几位被挡，别让人对着圆点数数。
    private var passwordBinding: Binding<String> {
        Binding(
            get: { password },
            set: { raw in
                let (clean, dropped) = AsciiInput.filter(raw)
                password = clean
                passwordNote = dropped.isEmpty ? nil : AsciiInput.note(for: dropped)
            }
        )
    }

    /// 字段下方的即时说明：与 `.failed` 状态行同一套（图标 + 12 号 `danger-ink`）。
    private func noteLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DmSpace.s6) {
            LucideIcon("triangle-alert", size: DmIcon.i12)
                .foregroundColor(Color.dmDanger)
            Text(text)
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmDangerInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 回车提交：字段上的 `.onSubmit` 管「光标在字段里按回车」，按钮上的
    /// `.keyboardShortcut(.defaultAction)` 管「焦点不在字段里也认回车」。
    /// 两处都可能触发，但 `AppState.connect` 开头就把重复调用挡掉了。
    private func submit() {
        guard !isSubmitDisabled else { return }
        // 用户亲手接方向盘：停掉后台的自动连重试，别跟这一把抢。
        state.cancelAutoConnect()
        // 分段选哪种就按哪种连 —— 直连地址字段残留着不改变这一点。
        Task {
            await state.connect(password: password, method: selectedMethod)
            guard !state.isConnected else { return }
            // 失败就把密码框清掉：窗口关掉再唤起时视图不重建、@State 里的
            // 旧值会留着，用户以为「已经留空」其实还在送同一条错密码。
            // 清空后下一次点击直接走本机已存凭据，也少喂 DSM 自动封锁。
            password = ""
            passwordNote = nil
        }
    }

    /// 分段当前选的连接方式，传给 `connect` 与存凭据判断。
    private var selectedMethod: AppState.ConnectMethod {
        mode == .direct ? .direct : .quickconnect
    }

    /// 连接进行中（含自动连的退避等待）：整页输入与按钮锁住。
    private var isLocked: Bool { state.phase.isConnecting }

    /// 两个条件分开看：**能不能点**只看字段填全没有，**锁没锁**只看连接在不在跑。
    ///
    /// 域名 / 账号 / 密码三样缺一样都不让点 —— 以前漏了账号那一项，账号空着
    /// 按钮是亮的，点下去只换回一句登录失败。密码为空时，本机存过这条端点的
    /// 凭据也放行（`connect` 里会取来用）。
    private var isSubmitDisabled: Bool {
        if isLocked { return true }
        let endpointReady: Bool
        switch mode {
        case .quickconnect:
            endpointReady = !state.qcID
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .direct:
            endpointReady = DirectAddress.parse(state.directAddress) != nil
        }
        let accountReady = !state.username
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let passwordReady = !password.isEmpty
            || state.hasSavedPassword(for: selectedMethod)
        return !endpointReady || !accountReady || !passwordReady
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state.phase {
        case .idle:
            EmptyView()
        case .resolving, .loggingIn, .retrying:
            HStack(spacing: DmSpace.s6) {
                LucideIcon("loader", size: DmIcon.i12)
                    .foregroundColor(Color.dmInk3)
                Text(state.phase.label)
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk2)
            }
        case .connected:
            Text("已连接：\(state.endpointLabel)")
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmOk)
        case let .failed(message):
            HStack(alignment: .top, spacing: DmSpace.s6) {
                LucideIcon("triangle-alert", size: DmIcon.i12)
                    .foregroundColor(Color.dmDanger)
                Text(message)
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmDangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 只留半角 ASCII 的输入过滤（密码框用）。
///
/// 要挡的是输入法带来的「长得一样、字节不同」：全角「！」（U+FF01）、
/// 全角字母数字（U+FF10…）、中文标点、emoji。全角区间与 ASCII 是固定偏移
/// 0xFEE0，但这里不做自动转半角 —— 悄悄改用户密码的字，等于把错密码换成
/// 另一个错密码；挡掉并指明位置，人自己改那一位。
private enum AsciiInput {
    struct Dropped {
        let character: Character
        /// 在原输入里的位置（从 1 起），提示里说「第 12 位」用。
        let position: Int
    }

    static func filter(_ raw: String) -> (text: String, dropped: [Dropped]) {
        var kept = ""
        var dropped: [Dropped] = []
        for (offset, character) in raw.enumerated() {
            let scalars = character.unicodeScalars
            let isHalfWidth = scalars.count == 1
                && (0x20...0x7E).contains(scalars.first!.value)
            if isHalfWidth {
                kept.append(character)
            } else {
                dropped.append(Dropped(character: character, position: offset + 1))
            }
        }
        return (kept, dropped)
    }

    static func note(for dropped: [Dropped]) -> String {
        guard let first = dropped.first else { return "" }
        let head = dropped.count == 1
            ? "第 \(first.position) 位的“\(first.character)”不是半角字符"
            : "第 \(first.position) 位起有 \(dropped.count) 个非半角字符（首个是“\(first.character)”）"
        let tail = dropped.count == 1 ? "重输这一位" : "重输这几处"
        return "\(head)，已忽略。密码只能用半角英文输入，把输入法切到英文后\(tail)。"
    }
}

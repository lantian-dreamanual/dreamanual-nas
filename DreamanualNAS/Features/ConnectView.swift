import SwiftUI

/// 连接页：QuickConnect ID 或直连地址 + 账号口令。
///
/// 形态对着密码管理的解锁页（`.lock-card`）落：整屏 `bg`、卡片居中、卡内一律左对齐
/// （标记 → 标题 → 分段 → 字段 → 主按钮 → 状态行）。卡片取 `panel-2` + `line` 1px
/// + `r-16` + `shadow-card`，与 `.lock-card` 同一套角色；宽度按本页内容收到 420。
/// 两种连接方式走分段切换，口令连上即存钥匙串。
struct ConnectView: View {
    @Environment(AppState.self) private var state

    enum Mode: Hashable { case quickconnect, direct }

    @State private var mode: Mode = .quickconnect
    @State private var password = ""

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
                .padding(.bottom, DmSpace.s20)

            DmSegmented([.quickconnect, .direct], selection: $mode, fillsWidth: true, on: .card) {
                $0 == .quickconnect ? "QuickConnect" : "直连地址"
            }
            .padding(.bottom, DmSpace.s16)

            switch mode {
            case .quickconnect:
                field("QuickConnect ID") {
                    TextField("例如 mynas", text: $state.qcID)
                        .formField(on: .card)
                        .onSubmit { submit() }
                }
            case .direct:
                field("直连地址") {
                    TextField("主机或主机:端口（局域网 / Tailscale）", text: $state.directAddress)
                        .formField(on: .card)
                        .onSubmit { submit() }
                }
            }

            field("账号") {
                TextField("DSM 账号", text: $state.username)
                    .formField(on: .card)
                    .onSubmit { submit() }
            }

            field("口令") {
                SecureField("DSM 密码", text: $password)
                    .formField(on: .card)
                    .onSubmit { submit() }
            }

            Button {
                submit()
            } label: {
                Text("连接").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSubmitDisabled)
            .keyboardShortcut(.defaultAction)

            statusLine
                .padding(.top, DmSpace.s14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DmSpace.s24)
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
    }

    /// 一个字段：标签在上、控件在下，间距 `s6`；字段之间 `s14`。
    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DmSpace.s6) {
            FormLabel(label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DmSpace.s14)
    }

    /// 回车提交：字段上的 `.onSubmit` 管「光标在字段里按回车」，按钮上的
    /// `.keyboardShortcut(.defaultAction)` 管「焦点不在字段里也认回车」。
    /// 两处都可能触发，但 `AppState.connect` 开头就把重复调用挡掉了。
    private func submit() {
        guard !isSubmitDisabled else { return }
        Task { await state.connect(password: password) }
    }

    private var isSubmitDisabled: Bool {
        state.phase.isBusy || password.isEmpty
            || (mode == .quickconnect && state.qcID.isEmpty)
            || (mode == .direct && DirectAddress.parse(state.directAddress) == nil)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state.phase {
        case .idle:
            EmptyView()
        case .resolving, .loggingIn:
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

import SwiftUI

/// 连接页：QuickConnect ID 或直连地址 + 账号口令。
/// 两种连接方式走分段切换（与设计原型一致），口令连上即存钥匙串。
struct ConnectView: View {
    @Environment(AppState.self) private var state

    enum Mode: Hashable { case quickconnect, direct }

    @State private var mode: Mode = .quickconnect
    @State private var password = ""

    var body: some View {
        @Bindable var state = state

        VStack(spacing: DmSpace.s20) {
            VStack(spacing: DmSpace.s8) {
                LucideIcon("server", size: DmIcon.i32)
                    .foregroundColor(Color.dmAccent)
                Text("Dreamanual NAS 助手")
                    .font(.system(size: DmText.t17, weight: .semibold))
                    .foregroundColor(Color.dmInk)
                Text("仅支持管理群晖 NAS")
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk3)
            }

            VStack(alignment: .leading, spacing: DmSpace.s14) {
                DmSegmented([.quickconnect, .direct], selection: $mode) {
                    $0 == .quickconnect ? "QuickConnect" : "直连地址"
                }

                switch mode {
                case .quickconnect:
                    VStack(alignment: .leading, spacing: DmSpace.s6) {
                        FormLabel("QuickConnect ID")
                        TextField("例如 mynas", text: $state.qcID)
                            .formField()
                            .onSubmit { submit() }
                    }
                case .direct:
                    VStack(alignment: .leading, spacing: DmSpace.s6) {
                        FormLabel("直连地址")
                        TextField("主机或主机:端口（局域网 / Tailscale）", text: $state.directAddress)
                            .formField()
                            .onSubmit { submit() }
                    }
                }

                VStack(alignment: .leading, spacing: DmSpace.s6) {
                    FormLabel("账号")
                    TextField("DSM 账号", text: $state.username)
                        .formField()
                        .onSubmit { submit() }
                }

                VStack(alignment: .leading, spacing: DmSpace.s6) {
                    FormLabel("口令")
                    SecureField("DSM 密码", text: $password)
                        .formField()
                        .onSubmit { submit() }
                }
            }
            .frame(width: 340)

            VStack(spacing: DmSpace.s8) {
                Button {
                    submit()
                } label: {
                    Text("连接").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSubmitDisabled)
                .keyboardShortcut(.defaultAction)

                statusLine
            }
            .frame(width: 340)
        }
        .padding(DmSpace.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dmBg)
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

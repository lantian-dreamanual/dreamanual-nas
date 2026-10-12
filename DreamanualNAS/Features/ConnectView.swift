import SwiftUI

/// 连接页：QuickConnect ID 或直连地址 + 账号口令。
///
/// 字段顺序按产品定义第二节「地基」：连接 → 口令。口令只进钥匙串，
/// 勾了「记住口令」才落库，取消勾选会把已有条目删掉。
struct ConnectView: View {
    @Environment(AppState.self) private var state

    @State private var password = ""
    @State private var showDirect = false

    var body: some View {
        @Bindable var state = state

        VStack(spacing: DmSpace.s20) {
            VStack(spacing: DmSpace.s8) {
                LucideIcon("server", size: DmIcon.i32)
                    .foregroundColor(Color.dmAccent)
                Text("Dreamanual NAS 助手")
                    .font(.system(size: DmText.t17, weight: .semibold))
                    .foregroundColor(Color.dmInk)
                Text("连接群晖 NAS，听自己的曲库、管自己的文件")
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk3)
            }

            VStack(alignment: .leading, spacing: DmSpace.s14) {
                VStack(alignment: .leading, spacing: DmSpace.s6) {
                    FormLabel("QuickConnect ID")
                    TextField("例如 mynas", text: $state.qcID)
                        .formField()
                        .disabled(showDirect)
                        .opacity(showDirect ? 0.4 : 1)
                }

                if showDirect {
                    VStack(alignment: .leading, spacing: DmSpace.s6) {
                        FormLabel("直连地址")
                        TextField("主机或主机:端口（局域网 / Tailscale）", text: $state.directAddress)
                            .formField()
                    }
                }

                VStack(alignment: .leading, spacing: DmSpace.s6) {
                    FormLabel("账号")
                    TextField("DSM 账号", text: $state.username)
                        .formField()
                }

                VStack(alignment: .leading, spacing: DmSpace.s6) {
                    FormLabel("口令")
                    SecureField("DSM 密码", text: $password)
                        .formField()
                }

                HStack {
                    Toggle("记住口令", isOn: $state.rememberPassword)
                        .toggleStyle(DmToggleStyle())
                        .font(.system(size: DmText.t13))
                        .foregroundColor(Color.dmInk2)
                    Spacer(minLength: 0)
                    Button(showDirect ? "改用 QuickConnect" : "改用直连地址") {
                        showDirect.toggle()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .frame(width: 340)

            VStack(spacing: DmSpace.s8) {
                Button {
                    Task { await state.connect(password: password) }
                } label: {
                    Text("连接").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.phase.isBusy || password.isEmpty || (!showDirect && state.qcID.isEmpty))

                statusLine
            }
            .frame(width: 340)

            Text("口令存在 macOS 钥匙串，不落配置文件；外网走 QuickConnect 中继，局域网可直连。")
                .font(.system(size: DmText.t11))
                .foregroundColor(Color.dmInk3)
                .multilineTextAlignment(.center)
                .frame(width: 340)
        }
        .padding(DmSpace.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dmBg)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state.phase {
        case .idle:
            Text("填好上面的信息后连接")
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
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

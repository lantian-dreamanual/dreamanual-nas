import Foundation
import Observation

/// 连接状态机 + 外壳需要的全部全局状态。
///
/// 这一版只做到「连上、两个会话都在、心跳活着」；曲库 / 文件 / 系统三个模块
/// 的取数各自在后面批次接 `SessionManager.call(...)`。
@MainActor
@Observable
final class AppState {
    enum Module: String, CaseIterable, Identifiable {
        case music, files, status, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .music: return "听歌"
            case .files: return "文件管理"
            case .status: return "系统状态"
            case .settings: return "设置"
            }
        }

        var icon: String {
            switch self {
            case .music: return "headphones"
            case .files: return "folder"
            case .status: return "gauge"
            case .settings: return "settings"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case resolving
        case loggingIn
        case connected
        case failed(String)

        var isBusy: Bool { self == .resolving || self == .loggingIn }

        var label: String {
            switch self {
            case .idle: return "未连接"
            case .resolving: return "正在解析端点…"
            case .loggingIn: return "正在登录…"
            case .connected: return "已连接"
            case let .failed(message): return message
            }
        }
    }

    // MARK: - 连接表单（持久化，口令除外）

    var qcID: String { didSet { defaults.set(qcID, forKey: Keys.qcID) } }
    var directAddress: String { didSet { defaults.set(directAddress, forKey: Keys.direct) } }
    var username: String { didSet { defaults.set(username, forKey: Keys.username) } }

    // MARK: - 运行状态

    private(set) var phase: Phase = .idle
    /// 端点描述，连上之后显示在侧栏底部（走中继还是直连、主机端口、区域）。
    private(set) var endpointLabel = ""
    private(set) var module: Module = .music
    private(set) var sessionManager: SessionManager?
    private(set) var lastConnectedAt: Date?

    private let defaults = UserDefaults.standard
    private let resolver = QuickConnectResolver()

    private enum Keys {
        static let qcID = "nas.qcID"
        static let direct = "nas.directAddress"
        static let username = "nas.username"
    }

    init() {
        qcID = defaults.string(forKey: Keys.qcID) ?? ""
        directAddress = defaults.string(forKey: Keys.direct) ?? ""
        username = defaults.string(forKey: Keys.username) ?? ""
    }
    var isConnected: Bool { phase == .connected }
    var hasSavedPassword: Bool {
        guard !trimmedUsername.isEmpty else { return false }
        return KeychainStore.password(endpointID: endpointKey, username: trimmedUsername) != nil
    }

    func select(_ module: Module) {
        self.module = module
    }

    // MARK: - 连接

    /// 启动时自动连一次（钥匙串里真有那条凭据才动）。
    func restoreAndAutoConnect() async {
        guard isConnected == false, phase.isBusy == false, hasSavedPassword else { return }
        guard let password = KeychainStore.password(endpointID: endpointKey, username: trimmedUsername) else { return }
        await connect(password: password)
    }

    /// - Parameter password: 口令只在内存里传，落盘只落钥匙串。
    func connect(password: String) async {
        guard phase.isBusy == false else { return }
        phase = .resolving
        endpointLabel = ""

        // 表单里粘进来的值常带首尾空白，账号那一个字符之差就是 Auth 400，
        // 而错误提示看不出是空白 —— 发出去之前先剪掉。
        let qc = trimmedQCID
        let user = trimmedUsername

        do {
            let client: SynologyClient
            if let direct = DirectAddress.parse(directAddress) {
                // 直连覆盖：局域网或 Tailscale。这条路的证书是 NAS 自签的，要放行。
                client = SynologyClient(host: direct.host, port: direct.port, allowSelfSigned: true)
                endpointLabel = "直连 \(direct.host):\(direct.port)"
            } else {
                guard !qc.isEmpty else { throw QuickConnectError.badResponse("先填 QuickConnect ID，或填一个直连地址") }
                let endpoint = try await resolver.resolve(id: qc)
                // 中继挂的是真证书，走默认校验。
                client = SynologyClient(host: endpoint.host, port: endpoint.port, allowSelfSigned: false)
                let region = endpoint.region.map { " · \($0)" } ?? ""
                endpointLabel = "QuickConnect\(region) · \(endpoint.host):\(endpoint.port)"
            }

            phase = .loggingIn
            let manager = SessionManager(client: client, account: user, password: password)

            // 会话是否真能用，拿一次心跳说话 —— 登录成功但权限不对是另一回事。
            try await manager.probe()

            sessionManager = manager
            await manager.startKeepAlive()
            lastConnectedAt = Date()
            phase = .connected

            // 连上即存：口令只进钥匙串，下次启动自动重连。
            KeychainStore.save(
                password: password,
                account: KeychainStore.accountKey(endpointID: endpointKey, username: user)
            )
        } catch {
            phase = .failed(error.localizedDescription)
            sessionManager = nil
        }
    }

    func disconnect() async {
        if let manager = sessionManager {
            await manager.stopKeepAlive()
            await manager.logoutAll()
        }
        sessionManager = nil
        endpointLabel = ""
        phase = .idle
    }

    /// 钥匙串条目的键：QuickConnect ID 与直连地址是两个不同的「端点身份」，
    /// 各自记各自的凭据，切换连接方式不会互相覆盖。
    private var endpointKey: String {
        if let direct = DirectAddress.parse(directAddress) { return "direct:\(direct.host):\(direct.port)" }
        return "qc:\(trimmedQCID)"
    }

    /// 表单值发出去之前剪掉首尾空白。存储的那份保持原样 —— 一边敲一边被改，
    /// 光标会跳。
    private var trimmedQCID: String {
        qcID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 直连地址解析：接受 `主机`、`主机:端口`、`https://主机:端口`。
struct DirectAddress {
    let host: String
    let port: Int

    static func parse(_ text: String) -> DirectAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var rest = trimmed
        for scheme in ["https://", "http://"] where rest.hasPrefix(scheme) {
            rest = String(rest.dropFirst(scheme.count))
        }
        rest = rest.split(separator: "/").first.map(String.init) ?? rest

        let parts = rest.split(separator: ":")
        switch parts.count {
        case 1:
            return DirectAddress(host: String(parts[0]), port: 5001)
        case 2:
            guard let port = Int(parts[1]) else { return nil }
            return DirectAddress(host: String(parts[0]), port: port)
        default:
            return nil
        }
    }
}

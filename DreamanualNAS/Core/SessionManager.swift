import Foundation

/// 双会话管理器：AudioStation 管曲库、FileStation 管文件 / 系统，
/// **两个 sid 与两个 token 一一配对**，不能混用（混用一律 code=105）。
///
/// 三件事都在这里：
///   1. 懒登录 —— 第一次用到某个会话时才登，别一上来占两个会话名额；
///   2. 保活 —— 定时心跳，会话失效时自动重登并**重放当前请求**；
///   3. 登录端点兜底 —— `auth.cgi` 与 `entry.cgi` 两个端点都能用，实测
///      前者偶尔回 119、重跑又通（机制未查明），所以两条都试。
actor SessionManager {
    enum Kind: String, CaseIterable {
        case file = "FileStation"
        case audio = "AudioStation"

        var displayName: String {
            switch self {
            case .file: return "文件与系统"
            case .audio: return "曲库"
            }
        }
    }

    /// 心跳间隔。DSM 的会话有效期以分钟计，这个频率既够稳又不吵。
    static let keepAliveInterval: TimeInterval = 240

    private let client: SynologyClient
    private let account: String
    private let password: String
    private var sessions: [Kind: SynologyCredentials] = [:]
    private var keepAliveTask: Task<Void, Never>?

    /// 最近一次心跳成功的时间，界面上要看「连接还活着吗」。
    private(set) var lastHeartbeat: Date?
    private(set) var heartbeatFailure: String?

    init(client: SynologyClient, account: String, password: String) {
        self.client = client
        self.account = account
        self.password = password
    }

    // MARK: - 调用

    /// 调一个接口；会话失效时自动重登一次并重放。
    func call(
        kind: Kind,
        api: String,
        version: Int,
        method: String,
        params: [String: String] = [:]
    ) async throws -> Any {
        var fields = params
        fields["api"] = api
        fields["version"] = String(version)
        fields["method"] = method

        let creds = try await credentials(for: kind)
        do {
            return try await client.post(path: "entry.cgi", params: fields, credentials: creds)
        } catch let error as SynologyError where error.isSessionInvalid {
            // 会话过期：丢掉重登，重放这一条请求。
            sessions[kind] = nil
            let refreshed = try await credentials(for: kind)
            return try await client.post(path: "entry.cgi", params: fields, credentials: refreshed)
        }
    }

    func credentials(for kind: Kind) async throws -> SynologyCredentials {
        if let cached = sessions[kind] { return cached }
        return try await login(kind)
    }

    // MARK: - 登录 / 登出

    @discardableResult
    func login(_ kind: Kind) async throws -> SynologyCredentials {
        let params: [String: String] = [
            "api": "SYNO.API.Auth",
            "version": "6",
            "method": "login",
            "session": kind.rawValue,
            "account": account,
            "passwd": password,
            "format": "sid",
            "enable_syno_token": "yes",
        ]

        var lastError: Error?
        for path in ["auth.cgi", "entry.cgi"] {
            do {
                let raw = try await client.post(path: path, params: params, credentials: nil)
                let data = (raw as? [String: Any]) ?? [:]
                guard let sid = data["sid"] as? String, !sid.isEmpty else {
                    lastError = QuickConnectError.badResponse("登录回包里没有 sid")
                    continue
                }
                let credentials = SynologyCredentials(sid: sid, token: (data["synotoken"] as? String) ?? "")
                sessions[kind] = credentials
                return credentials
            } catch {
                lastError = error
            }
        }
        throw lastError ?? QuickConnectError.badResponse("登录失败")
    }

    func logout(_ kind: Kind) async {
        guard let credentials = sessions[kind] else { return }
        sessions[kind] = nil
        _ = try? await client.post(
            path: "auth.cgi",
            params: [
                "api": "SYNO.API.Auth", "version": "6", "method": "logout",
                "session": kind.rawValue,
            ],
            credentials: credentials
        )
    }

    func logoutAll() async {
        for kind in Kind.allCases { await logout(kind) }
    }

    // MARK: - 保活

    /// 心跳：拿文件会话打一次系统信息。失败不抛 —— 由下一次请求去触发重登。
    func heartbeat() async {
        do {
            _ = try await call(kind: .file, api: "SYNO.Core.System", version: 1, method: "info")
            lastHeartbeat = Date()
            heartbeatFailure = nil
        } catch {
            heartbeatFailure = error.localizedDescription
        }
    }

    func startKeepAlive() {
        stopKeepAlive()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.keepAliveInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.heartbeat()
            }
        }
    }

    func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// 供界面显示：当前已建立的会话。
    func establishedKinds() -> [Kind] {
        Kind.allCases.filter { sessions[$0] != nil }
    }
}

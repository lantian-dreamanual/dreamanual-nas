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
    ///
    /// - Parameter path: 覆盖请求路径用。**Audio Station 的接口不在 `entry.cgi`
    ///   上**（拿它打回 `code=102`），每条认自己的专路径，所以不传时按接口名去
    ///   `query.cgi` 的接口地图里查。地图是路径的唯一权威来源 —— 猜 cgi 名是
    ///   踩过的坑：猜错时服务端回 HTML 错误页，解包失败被当成「方法不存在」，
    ///   得看原始应答的 `Content-Type` 才判得出来。
    func call(
        kind: Kind,
        api: String,
        version: Int,
        method: String,
        params: [String: String] = [:],
        path: String? = nil
    ) async throws -> Any {
        var fields = params
        fields["api"] = api
        fields["version"] = String(version)
        fields["method"] = method

        let target = try await entryPath(for: api, overriding: path)
        let creds = try await credentials(for: kind)
        do {
            return try await client.post(path: target, params: fields, credentials: creds)
        } catch let error as SynologyError where error.isSessionInvalid {
            // 会话过期：丢掉重登，重放这一条请求。
            sessions[kind] = nil
            let refreshed = try await credentials(for: kind)
            return try await client.post(path: target, params: fields, credentials: refreshed)
        }
    }

    /// 取原始字节的非 JSON 接口（封面 / 缩略图）。与 `call` 同构 —— 会话失效
    /// 同样丢掉重登、重放这一条。
    func data(
        kind: Kind,
        api: String,
        version: Int,
        method: String,
        params: [String: String] = [:],
        path: String? = nil
    ) async throws -> Data {
        var fields = params
        fields["api"] = api
        fields["version"] = String(version)
        fields["method"] = method

        let target = try await entryPath(for: api, overriding: path)
        let creds = try await credentials(for: kind)
        do {
            return try await client.getData(path: target, params: fields, credentials: creds)
        } catch let error as SynologyError where error.isSessionInvalid {
            sessions[kind] = nil
            let refreshed = try await credentials(for: kind)
            return try await client.getData(path: target, params: fields, credentials: refreshed)
        }
    }

    /// 这一条请求该走哪条路径。文件与系统类的接口都在 `entry.cgi` 上，地图里
    /// 查不到（或地图本身拉不下来）时退回去。
    private func entryPath(for api: String, overriding path: String?) async throws -> String {
        if let path { return Self.relativePath(path) }
        if let info = try? await client.apiInfo(for: api) { return Self.relativePath(info.path) }
        return "entry.cgi"
    }

    /// 接口地图里的 `path` 写法不统一 —— 有的给 `entry.cgi`，有的给
    /// `/webapi/AudioStation/song.cgi`。`client.baseURL` 本身已经带 `/webapi/`
    /// 前缀，直接拼会把前缀叠成两层、服务端回 HTML 404，所以统一裁成相对路径。
    static func relativePath(_ path: String) -> String {
        if path.hasPrefix("/webapi/") { return String(path.dropFirst("/webapi/".count)) }
        if path.hasPrefix("/") { return String(path.dropFirst()) }
        return path
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
            } catch let error as SynologyError where !error.worthTryingOtherEndpoint {
                // 账号口令类的错换端点也一样错 —— 重打一遍只会把失败次数翻倍，
                // DSM 的自动封锁是照失败次数记的。
                throw error
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

    // MARK: - 取流

    /// 取流那一路要用的端点信息。AVPlayer 的请求加不了 `X-SYNO-TOKEN`、
    /// 直连模式还要放行自签证书 —— 都得自己发请求（`StreamLoader`），端点与
    /// 证书策略从这里拿，保证与普通调用走同一个主机、同一套规矩。
    var streamEndpoint: StreamLoader.Endpoint {
        get async throws {
            let creds = try await credentials(for: .audio)
            return StreamLoader.Endpoint(
                baseURL: client.baseURL,
                credentials: creds,
                allowSelfSigned: client.allowSelfSigned
            )
        }
    }

    // MARK: - 保活

    /// 心跳：拿文件会话打一次系统信息。失败不抛 —— 由下一次请求去触发重登。
    func heartbeat() async {
        do {
            try await probe()
        } catch {
            heartbeatFailure = error.localizedDescription
        }
    }

    /// 同上，但把错抛出来。连接流程要用它判「这个会话真的能用吗」——
    /// 登录回包里拿到 sid 不等于这个账号有权限，得真调一次。
    func probe() async throws {
        _ = try await call(kind: .file, api: "SYNO.Core.System", version: 2, method: "info")
        lastHeartbeat = Date()
        heartbeatFailure = nil
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

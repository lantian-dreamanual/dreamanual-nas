import Foundation

/// 会话凭据。`sid` 与 `X-SYNO-TOKEN` **必须成对** —— 拿 A 会话的 sid 配
/// B 会话的 token 一律回 `code=105`（看起来像权限问题，实际是配错了对）。
struct SynologyCredentials: Equatable {
    var sid: String
    var token: String
}

/// 业务错误。Synology 的应答信封是 `{success: false, error: {code: N}}`，
/// 但**写接口的外层 `code` 只是包装码**（1100 / 1200 / 900），真因在
/// `error.errors[]` 里 —— 这里把两条都带上，避免只看外层码就下结论。
struct SynologyError: LocalizedError {
    let code: Int
    let api: String
    let method: String
    let errors: [[String: Any]]

    /// 会话类错误：重登一次再重放通常就好。
    var isSessionInvalid: Bool { [105, 106, 107, 119].contains(code) }

    /// 这个错值不值得换另一个登录端点再试一次。
    /// 只有「这个端点不认识这个接口」和会话类才有意义；账号口令不对、
    /// 权限不够、被封锁这些换端点也是同一个答案。
    var worthTryingOtherEndpoint: Bool {
        [101, 102, 103, 104, 119].contains(code)
    }

    var errorDescription: String? {
        if let friendly = Self.friendlyMessage(api: api, code: code) { return friendly }
        let base = "\(api).\(method) 失败（code \(code)）"
        guard !errors.isEmpty else { return base }
        let detail = errors.map { err -> String in
            let c = (err["code"] as? Int).map(String.init) ?? "?"
            let path = (err["path"] as? String) ?? ""
            return path.isEmpty ? c : "\(c) @ \(path)"
        }.joined(separator: "，")
        return "\(base)：\(detail)"
    }

    /// 业务码转人话。**码的语义随 API 变**，所以只翻 `SYNO.API.Auth` 这一组
    /// —— 同一个 `400` 在 FileStation 是「路径不合法」，翻成「账号或口令不对」
    /// 就是把用户往错方向指。其余一律保留原始码，码本身是查文档的钥匙。
    static func friendlyMessage(api: String, code: Int) -> String? {
        guard api == "SYNO.API.Auth" else { return nil }
        switch code {
        case 400: return "账号或口令不对。"
        case 401: return "这个账号已被停用。"
        case 402: return "这个账号没有登录权限。"
        case 403, 406: return "这个账号开了两步验证，需要验证码才能登录，当前版本还不支持。"
        case 404: return "两步验证码不对。"
        case 407: return "这台设备的 IP 被 NAS 的自动封锁拦住了，去 DSM 的「控制面板 → 安全性 → 自动封锁」解开。"
        case 408, 409: return "这个账号的口令已过期，需要先在 DSM 里改。"
        case 105: return "登录会话权限不够或被顶掉了。"
        case 106: return "登录会话超时了。"
        case 107: return "这个账号在别处又登了一次，当前会话被顶掉。"
        case 119: return "登录会话已失效。"
        default: return nil
        }
    }
}

/// `query.cgi` 给的接口地图条目。**`path` 是相对路径**（`entry.cgi`），
/// 用之前要补 `/webapi/` 前缀，否则 `URL(string:)` 直接得到非法 URL。
struct SynologyAPIInfo {
    let path: String
    let minVersion: Int
    let maxVersion: Int
}

/// 直连模式要放行 NAS 自己的自签证书；中继走默认校验。
final class TLSPolicyDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowSelfSigned: Bool

    init(allowSelfSigned: Bool) {
        self.allowSelfSigned = allowSelfSigned
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// 一台 NAS 的 HTTP 客户端。只管「怎么发、怎么解信封」，不管会话与重登
/// （那是 SessionManager 的事）。
final class SynologyClient: @unchecked Sendable {
    /// 形如 `https://<主机>:<端口>/webapi/`
    let baseURL: URL
    /// 取流那一路（StreamLoader）要用同一套证书策略另开 URLSession。
    let allowSelfSigned: Bool
    private let session: URLSession
    private var apiMap: [String: SynologyAPIInfo]?
    private let lock = NSLock()

    /// - Parameter allowSelfSigned: 直连（局域网 / Tailscale）传 true，
    ///   QuickConnect 中继传 false。
    init(host: String, port: Int, allowSelfSigned: Bool) {
        self.allowSelfSigned = allowSelfSigned
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.port = port
        comps.path = "/webapi/"
        baseURL = comps.url ?? URL(string: "https://\(host):\(port)/webapi/")!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(
            configuration: config,
            delegate: TLSPolicyDelegate(allowSelfSigned: allowSelfSigned),
            delegateQueue: nil
        )
    }

    /// 接口清单（863 个接口的名字 / 相对路径 / 版本区间），**不需要登录**。
    func apiInfo(for api: String) async throws -> SynologyAPIInfo? {
        if let cached = cachedAPIInfo(for: api) { return cached }
        let map = try await fetchAPIMap()
        return map[api]
    }

    private func cachedAPIInfo(for api: String) -> SynologyAPIInfo? {
        lock.withLock { apiMap?[api] }
    }

    @discardableResult
    func fetchAPIMap() async throws -> [String: SynologyAPIInfo] {
        let raw = try await get(
            path: "query.cgi",
            params: ["api": "SYNO.API.Info", "version": "1", "method": "query", "query": "all"],
            credentials: nil
        )
        // 地图直接放在 data 下面，没有 apis 那一层。
        let data = (raw as? [String: Any]) ?? [:]
        var map: [String: SynologyAPIInfo] = [:]
        for (name, value) in data {
            guard let entry = value as? [String: Any],
                  let path = entry["path"] as? String
            else { continue }
            map[name] = SynologyAPIInfo(
                path: path,
                minVersion: (entry["minVersion"] as? Int) ?? 1,
                maxVersion: (entry["maxVersion"] as? Int) ?? 1
            )
        }
        lock.withLock { apiMap = map }
        return map
    }

    /// 调一个 `/webapi/` 接口，返回 `data` 段。
    ///
    /// - Parameters:
    ///   - path: 相对路径（`entry.cgi` / `auth.cgi` / `AudioStation/song.cgi`）。
    ///   - credentials: 带上它就会加表单 `_sid` 与请求头 `X-SYNO-TOKEN`。
    @discardableResult
    func get(path: String, params: [String: String], credentials: SynologyCredentials?) async throws -> Any {
        var fields = params
        if let credentials { fields["_sid"] = credentials.sid }
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        comps?.percentEncodedQuery = Self.formEncode(fields)
        guard let url = comps?.url else {
            throw QuickConnectError.badResponse("拼不出 URL：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let credentials {
            request.setValue(credentials.token, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        return try await send(request, api: params["api"] ?? path, method: params["method"] ?? "")
    }

    /// 表单 POST（登录、以及绝大多数 `entry.cgi` 调用）。
    @discardableResult
    func post(path: String, params: [String: String], credentials: SynologyCredentials?) async throws -> Any {
        var fields = params
        if let credentials { fields["_sid"] = credentials.sid }

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)
        if let credentials {
            request.setValue(credentials.token, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        return try await send(request, api: params["api"] ?? path, method: params["method"] ?? "")
    }

    /// 自己拼表单：`URLComponents` 默认那套会把口令里的 `+` 原样发出，
    /// 服务端按表单规则解成空格 —— 口令里带 `+` 就登不上，且报错看不出原因。
    /// 这里按 RFC 3986 只留 unreserved 字符，其余全部百分号转义。
    static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .sorted()
            .joined(separator: "&")
    }

    private func send(_ request: URLRequest, api: String, method: String) async throws -> Any {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuickConnectError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw QuickConnectError.network("HTTP \(http.statusCode)")
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuickConnectError.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        if let success = envelope["success"] as? Bool, success == false {
            let error = (envelope["error"] as? [String: Any]) ?? [:]
            throw SynologyError(
                code: (error["code"] as? Int) ?? -1,
                api: api,
                method: method,
                errors: (error["errors"] as? [[String: Any]]) ?? []
            )
        }
        return envelope["data"] ?? [:]
    }
}

import Foundation

/// 会话凭据。`sid` 与 `X-SYNO-TOKEN` **必须成对** —— 拿 A 会话的 sid 配
/// B 会话的 token 会被判成会话无效（看起来像权限问题，实际是配错了对）。
/// ⚠️ **码随接口变**：AudioStation 类回 `105`，`FileStation.Download` 回 `119`
/// （2026-10-13 实测，见 `docs/接口结论.md` 第十一节第 5 条）。
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

    /// 判据只此一处：普通调用、取流（`StreamLoader`）、下载（`FileDownloader`）
    /// 各开自己的 URLSession，三处共用这一条 —— 一处改了、另两处忘了，直连就会
    /// 只坏在某个场景上，很难查。
    static func allows(_ challenge: URLAuthenticationChallenge,
                       allowSelfSigned: Bool) -> URLCredential? {
        guard allowSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return nil }
        return URLCredential(trust: trust)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let credential = Self.allows(challenge, allowSelfSigned: allowSelfSigned) {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
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
    ///
    /// - Parameter cookie: 额外的 Cookie 头。`/webman/3rdparty/` 下的内部 CGI
    ///   不认表单 `_sid`、只认**会话 Cookie**（`id=<sid>`）—— 标签编辑接口
    ///   实测三件套齐才过（表单 `_sid` + `X-SYNO-TOKEN` 头 + 这枚 Cookie）。
    @discardableResult
    func post(path: String, params: [String: String], credentials: SynologyCredentials?,
              cookie: String? = nil) async throws -> Any {
        var fields = params
        if let credentials { fields["_sid"] = credentials.sid }

        // `path` 以 `/` 开头 = webapi 体系外的绝对路径（如 /webman/3rdparty/...）。
        // `appendingPathComponent` 会把它接在 baseURL 的 `/webapi/` 后面
        // （…/webapi/webman/...），服务端直接回 403 —— 绝对路径要整体替换。
        var url = baseURL.appendingPathComponent(path)
        if path.hasPrefix("/") {
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            comps.path = path
            url = comps.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 显式 Cookie 与自动附带不能共存：file / audio 两个会话轮流登录，共享的
        // CookieStorage 里永远留着**最后一次登录**的 `id`，自动附上去就是两个
        // `id` 打架 —— 标签编辑接口直接回 HTTP 403（2026-10-15 harness 二分定位）。
        // 会话凭据一律走显式参数（表单 `_sid` + 头 + 手工 Cookie），系统 Cookie 不参与。
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)
        if let credentials {
            request.setValue(credentials.token, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return try await send(request, api: params["api"] ?? path, method: params["method"] ?? "")
    }

    /// 取原始字节。封面 / 缩略图这类接口回的是图片，不是 `{success, data}` 信封
    /// —— 走 `send` 那套会把 JPEG 当 JSON 解、判成 badResponse。
    ///
    /// 失败判据不能只看状态码：业务错误依旧是「HTTP 200 + JSON 信封」，所以认
    /// **`Content-Type` 是 `image/`** 才算拿到图，其余一律当失败，并顺手把信封里
    /// 的业务码挖出来（不然那个码就丢在字节里了）。
    func getData(path: String, params: [String: String], credentials: SynologyCredentials?) async throws -> Data {
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuickConnectError.network(error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let mime = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if let http, (200..<300).contains(http.statusCode), mime.lowercased().hasPrefix("image/") {
            return data
        }
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = envelope["error"] as? [String: Any] {
            throw SynologyError(
                code: (error["code"] as? Int) ?? -1,
                api: params["api"] ?? path,
                method: params["method"] ?? "",
                errors: (error["errors"] as? [[String: Any]]) ?? []
            )
        }
        throw QuickConnectError.network(
            "HTTP \(http?.statusCode ?? -1) · \(mime.isEmpty ? "无 Content-Type" : mime)"
        )
    }

    /// multipart 上传一个文件，走 `SYNO.FileStation.Upload`。
    ///
    /// 六条硬约束全是实测出来的（`docs/接口结论.md` 第七节第 1 条末，15 种写法对照里
    /// 8 通 7 败），违背任一条都回 `401`、而且服务端**先等 10 秒再回**，排查时容易
    /// 误判成网络慢：
    ///
    ///   1. 目标目录 `path` 必须放 **multipart body**，放 query 回 `401`；
    ///   2. 每个 part 不能带 `Content-Length` 头（带 → `401`）；
    ///   3. 顶层 `Content-Type` 不能带 `; charset=utf-8`（带 → `401`）；
    ///   4. `X-SYNO-TOKEN` 必须带（不带 → `119`），放 query 的 `SynoToken` 也认；
    ///   5. `_sid` 只放 query（当 body 字段给 → `119`）；
    ///   6. **段序是硬约束：字段在前、`file` 段最后** —— 反过来服务端根本不回响应，
    ///      客户端一直等到自己超时。
    ///
    /// 身先落到临时文件再交给 `upload(for:fromFile:)`：几十 MB 的音频拼成一个
    /// `Data` 在内存里多一份，而且只有走 file 才有逐段进度回调。
    ///
    /// - Parameter progress: `(已发字节, 总字节)`。回调在 URLSession 的代理队列上，
    ///   调用方自己往主线程跳。
    @discardableResult
    func upload(
        path: String,
        query: [String: String],
        fields: [String: String],
        credentials: SynologyCredentials,
        fileName: String,
        fileURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Any {
        let boundary = "----DreamanualUpload\(UUID().uuidString)"
        let bodyURL = try Self.multipartBody(
            boundary: boundary, fields: fields, fileName: fileName, fileURL: fileURL
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var queryFields = query
        queryFields["_sid"] = credentials.sid
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        comps?.percentEncodedQuery = Self.formEncode(queryFields)
        guard let url = comps?.url else {
            throw QuickConnectError.badResponse("拼不出 URL：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.token, forHTTPHeaderField: "X-SYNO-TOKEN")

        let relay = UploadProgressRelay(progress: progress)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: bodyURL, delegate: relay)
        } catch {
            // 取消是用户主动的，照原样抛上去 —— 队列要把它与「连接断了」分开报。
            if (error as? URLError)?.code == .cancelled { throw error }
            throw QuickConnectError.network(error.localizedDescription)
        }
        return try decode(
            data: data, response: response,
            api: query["api"] ?? path, method: query["method"] ?? ""
        )
    }

    /// 把字段与文件拼成 multipart 身，落到临时文件。
    ///
    /// 逐块写而不是先拼 `Data`：文件本体边读边写，内存里始终只有一块缓冲。
    /// 每个 part 只有 `Content-Disposition`（**不加 `Content-Length`**，见上传那六条）。
    private static func multipartBody(
        boundary: String, fields: [String: String], fileName: String, fileURL: URL
    ) throws -> URL {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("nas-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }

        // 字段段：顺序按字典排序走，服务端只要求「字段在前」，字段之间不分先后。
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            out.write(Data("--\(boundary)\r\n".utf8))
            out.write(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            out.write(Data("\(value)\r\n".utf8))
        }
        out.write(Data("--\(boundary)\r\n".utf8))
        // 名字里的引号与反斜杠要转义，否则段头被拼断。
        let safeName = fileName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        out.write(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
        out.write(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 18), !chunk.isEmpty {
            out.write(chunk)
        }
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return target
    }

    /// 只管转发上传进度。`URLSession` 一次上传一个代理，用完即弃。
    private final class UploadProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let progress: @Sendable (Int64, Int64) -> Void

        init(progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.progress = progress
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didSendBodyData bytesSent: Int64,
            totalBytesSent: Int64,
            totalBytesExpectedToSend: Int64
        ) {
            progress(totalBytesSent, totalBytesExpectedToSend)
        }
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
        return try decode(data: data, response: response, api: api, method: method)
    }

    /// 解开信封：非 2xx 当网络错；2xx 但解不出 JSON 当应答坏；`success=false` 抛业务码。
    /// 上传那条自己拿到了 `(data, response)`，所以解信封这一段抽出来共用。
    private func decode(data: Data, response: URLResponse, api: String, method: String) throws -> Any {
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
        // webapi 信封取 `data`；webapi 体系外的内部 CGI（tag_editor 等）应答
        // 顶层就是业务字段（`files` / `success`，没有 `data` 键）—— 整包返回，
        // 吞成空字典会把读到的标签全部弄丢（2026-10-15 harness 二分定位）。
        return envelope["data"] ?? envelope
    }
}

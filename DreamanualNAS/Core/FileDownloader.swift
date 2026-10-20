import Foundation

/// 原始文件下载（音频原文件）。
///
/// 与取图那条 `SynologyClient.getData` 最不一样的地方是**失败有两种形状**
/// （2026-10-13 实测，见 `docs/接口结论.md` 第十一节第 4 条）：
///
///   · **会话问题**（缺 `_sid` / `_sid` 无效 / `sid` 与 token 不配对）
///     → **HTTP 200** + `application/json`，正文是 `{"error":{"code":119}}`；
///   · **路径问题**（文件不存在 / 是目录 / `path` 缺省）
///     → **HTTP 404** + `text/html`（DSM 自带的 404 页）。
///
/// 所以判失败要两条都认：**先认「回来的是 JSON」（会话类），再认「非 2xx」（路径类）**。
/// 只看状态码 → 会话过期时会把错误 JSON 原样存成 `.mp3`；
/// 只看 MIME → 404 那页 HTML 也会被存成 `.mp3`。
///
/// 走的接口：`FileStation.Download` v2 `download` + `mode=open`，拿的是曲库里
/// 那个**原始文件**（`audio/mpeg`），不是转码流。应答里 `Content-Length` 与
/// `Accept-Ranges: bytes` 都有 —— 能报百分比、能续传；**没有 `Content-Disposition`**，
/// 存盘文件名得自己拼。
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let credentials: SynologyCredentials
    private let allowSelfSigned: Bool
    private let destination: URL
    private let progressHandler: (@Sendable (Int64, Int64) -> Void)?

    private let lock = NSLock()
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var finished = false

    init(
        baseURL: URL,
        credentials: SynologyCredentials,
        allowSelfSigned: Bool,
        destination: URL,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.allowSelfSigned = allowSelfSigned
        self.destination = destination
        self.progressHandler = progress
    }

    /// 下载 `path`（曲库路径，形如 `/music/<歌手>/<年.专辑>/<曲>.mp3`）。
    func start(path: String) async throws {
        // 曲库给的就是完整路径，直接拿去 FileStation —— 与「在文件夹中显示」同一条。
        let fields: [String: String] = [
            "api": "SYNO.FileStation.Download",
            "version": "2",
            "method": "download",
            "path": path,
            "mode": "open",
            "_sid": credentials.sid,
        ]
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("entry.cgi"),
            resolvingAgainstBaseURL: false
        )
        comps?.percentEncodedQuery = SynologyClient.formEncode(fields)
        guard let url = comps?.url else {
            throw QuickConnectError.badResponse("拼不出下载地址")
        }

        var request = URLRequest(url: url)
        if !credentials.token.isEmpty {
            request.setValue(credentials.token, forHTTPHeaderField: "X-SYNO-TOKEN")
        }

        let config = SynologyClient.makeConfiguration(
            requestTimeout: 60, resourceTimeout: 3600, direct: allowSelfSigned)
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        lock.withLock { self.session = session }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock { continuation = cont }
            session.downloadTask(with: request).resume()
        }
    }

    // MARK: - 委托

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// 临时文件只在这个回调里有效 —— 搬运必须当场做完。
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let mime = http?.value(forHTTPHeaderField: "Content-Type") ?? ""

        // 会话类失败：HTTP 200 + JSON 信封（code 119）。先认这条 —— 它状态码是好的。
        if mime.lowercased().contains("json") {
            let body = (try? Data(contentsOf: location)) ?? Data()
            record(Self.sessionOrBusinessError(body, status: status))
            return
        }
        // 路径类失败：HTTP 404 + DSM 的 HTML 错误页。不认这条会把错误页存成音频。
        if let http, !(200..<300).contains(http.statusCode) {
            record(Self.pathError(status: http.statusCode))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            record(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { record(error) }
        session.invalidateAndCancel()
        let cont: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let pending = continuation
            continuation = nil
            self.session = nil
            return pending
        }
        guard let cont else { return }
        let error = lock.withLock { failure }
        cont.resume(with: error.map { .failure($0) } ?? .success(()))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let credential = TLSPolicyDelegate.allows(challenge, allowSelfSigned: allowSelfSigned) {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - 内部

    private func record(_ error: Error) {
        lock.withLock { if failure == nil { failure = error } }
    }

    /// JSON 信封里的错 —— 这条上确实是 `code=119`（会话无效），不是 105。
    /// 会话类给一句能照做的提示，其余把业务码原样带上（码是查文档的钥匙）。
    private static func sessionOrBusinessError(_ body: Data, status: Int) -> Error {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? -1
            if [105, 106, 107, 119].contains(code) {
                return QuickConnectError.badResponse("登录会话已失效，重新连接后再试。")
            }
            return SynologyError(
                code: code,
                api: "SYNO.FileStation.Download",
                method: "download",
                errors: (error["errors"] as? [[String: Any]]) ?? []
            )
        }
        // 原始应答只进日志（HTML 错误页 / JSON 片段对用户没有意义）。
        let text = String(data: body.prefix(200), encoding: .utf8) ?? ""
        if !text.isEmpty { NSLog("[download] 应答不是预期形状：%@", text) }
        return QuickConnectError.badResponse("下载没有完成，请重试。")
    }

    /// 路径类失败：DSM 回 404 + HTML 错误页，页里没有可用信息，按状态码给人话。
    /// 🔴 状态码不上界面（判据 9），只留一句「发生了什么 + 下一步」。
    private static func pathError(status: Int) -> Error {
        switch status {
        case 404: return QuickConnectError.badResponse("这个文件在 NAS 上找不到了。")
        case 403: return QuickConnectError.badResponse("没有下载这个文件的权限。")
        default: return QuickConnectError.badResponse("下载没有完成，请重试。")
        }
    }
}

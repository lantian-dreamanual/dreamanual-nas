import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum PlaybackError: LocalizedError {
    case badAsset
    case streamStatus(Int)
    /// DSM 业务码（HTTP 200 + JSON 信封里的 `error.code`）。
    case streamRejected(Int)
    /// 200 回来但内容不是媒体（服务端回了 JSON / HTML）。
    case streamNotMedia

    var errorDescription: String? {
        switch self {
        case .badAsset:
            return "取流地址拼不出来。"
        case .streamStatus(let status):
            return "取流失败（HTTP \(status)）。"
        case .streamRejected(let code):
            return "取流被拒（Synology 错误码 \(code)）。"
        case .streamNotMedia:
            return "取流返回的不是音视频。"
        }
    }
}

/// 取流装载器 —— 接口结论 §二的路线 A：自定义 scheme + `AVAssetResourceLoaderDelegate`。
///
/// 为什么要自己接手网络：AVPlayer 的请求加不了自定义头（Audio Station 的取流
/// 与别的接口一样要 `X-SYNO-TOKEN`），直连模式还要放行 NAS 的自签证书 ——
/// 这两条只有自己发请求才办得到。AVFoundation 只看到自定义 scheme，
/// 真正的字节由这里用 URLSession（带与 `SynologyClient` 同一套证书策略）去拉。
///
/// **音视频共用这一套**（2026-10-20 加照片视频）：差异只在取流地址，视频走
/// `SYNO.FotoTeam.Streaming`（`/webapi/` 前缀、条目 id + quality），其余探测总长、
/// 按 Range 裁、喂字节的逻辑逐行相同 —— 复制一份出来只会让两处慢慢走偏。
///
/// 实测约束（都写进接口结论了）：
/// - `contentInformationRequest.contentType` 必须填**正确的 UTI**（mp3 填
///   `public.mp3`；mp4 填 `public.mpeg-4`）；填 MIME `audio/mpeg` 得 -11828，
///   填错 UTI 得 -11829。
/// - AVPlayer 判格式还依赖 URL 扩展名，所以 asset URL 的尾部保留真扩展名。
/// - 服务端支持 Range（回 206 + Content-Range），拖进度条有基础；个别请求
///   回 200 全量时把 offset 前的字节丢掉再喂。
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    /// 自定义 scheme 必须是系统不认识的，AVFoundation 才会把装载请求交给 delegate。
    static let scheme = "dmnas"

    /// 取什么。地址按这个现拼 —— asset URL 只是给 AVFoundation 看的一个壳，
    /// 真实地址在 `streamURL` 里按来源生成。
    enum Source {
        /// Audio Station 的曲目 id。
        case audio(songID: String)
        /// 照片库的视频条目 id（**条目 id，不是 unit_id**）。
        case photoVideo(itemID: Int)
    }

    /// 三件套提升成了顶层 `StreamEndpoint`（小组件 target 不编本文件，但
    /// SessionManager 的引用照旧）—— 这里留个旧名字。
    typealias Endpoint = StreamEndpoint

    /// 冒烟日志开关（与 PlaybackEngine 同一个环境变量）。
    private static let smoke = ProcessInfo.processInfo.environment["DM_SMOKE"] == "1"

    private static func smokeLog(_ text: String) {
        guard smoke else { return }
        NSLog("[stream] %@", text)
    }


    /// codec → UTI。填错得 -11828 / -11829（接口结论 §二「AVPlayer 的三个坎」）。
    static func contentType(for song: AudioSong) -> String {
        switch song.codec.lowercased() {
        case "mp3": return UTType.mp3.identifier
        case "aac", "m4a", "mp4", "alac": return UTType.mpeg4Audio.identifier
        case "flac": return "org.xiph.flac"
        case "wav": return UTType.wav.identifier
        case "aiff", "aif": return UTType.aiff.identifier
        default: break
        }
        // codec 字段为空时退回扩展名；再认不出就当 mp3 —— 真放不了会在
        // 播放条上看到错误，不会静默。
        switch fileExtension(of: song).lowercased() {
        case "m4a", "mp4", "aac": return UTType.mpeg4Audio.identifier
        case "flac": return "org.xiph.flac"
        case "wav": return UTType.wav.identifier
        case "aiff", "aif": return UTType.aiff.identifier
        default: return UTType.mp3.identifier
        }
    }

    /// AVPlayer 判格式依赖 URL 扩展名 —— 从曲库路径取真扩展名，兜底 codec。
    static func fileExtension(of song: AudioSong) -> String {
        if !song.path.isEmpty {
            let ext = (song.path as NSString).pathExtension
            if !ext.isEmpty { return ext }
        }
        return switch song.codec.lowercased() {
        case "mp3": "mp3"
        case "aac", "m4a", "mp4", "alac": "m4a"
        case "flac": "flac"
        case "wav": "wav"
        case "aiff", "aif": "aiff"
        default: "mp3"
        }
    }

    private let source: Source
    private let contentType: String
    private let endpoint: Endpoint
    private let workQueue = DispatchQueue(label: "dreamanual.nas.stream", qos: .userInitiated)
    private let tlsPolicy: TLSPolicyDelegate
    private lazy var probeSession = URLSession(
        configuration: SynologyClient.makeConfiguration(
            requestTimeout: 60, resourceTimeout: 604_800, direct: endpoint.allowSelfSigned),
        delegate: tlsPolicy,
        delegateQueue: nil
    )
    private lazy var streamSession = URLSession(
        configuration: SynologyClient.makeConfiguration(
            requestTimeout: 60, resourceTimeout: 604_800, direct: endpoint.allowSelfSigned),
        delegate: self,
        delegateQueue: nil
    )

    /// 共享状态收进同步壳 —— 挂锁的访问全在同步方法里，async 侧只调方法
    /// （NSLock 的 lock/unlock 在 async 上下文里是 Swift 6 的编译错）。
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [Int: Handler] = [:]
        private var total: Int64?

        func handler(for task: URLSessionTask) -> Handler? {
            lock.withLock { handlers[task.taskIdentifier] }
        }

        func register(_ handler: Handler, for task: URLSessionDataTask) {
            lock.withLock { handlers[task.taskIdentifier] = handler }
        }

        func unregister(_ task: URLSessionDataTask) {
            lock.withLock { _ = handlers.removeValue(forKey: task.taskIdentifier) }
        }

        func cachedTotal() -> Int64? {
            lock.withLock { total }
        }

        func storeTotal(_ value: Int64) {
            lock.withLock { total = value }
        }
    }

    private let state = State()

    init(source: Source, contentType: String, endpoint: Endpoint) {
        self.source = source
        self.contentType = contentType
        self.endpoint = endpoint
        self.tlsPolicy = TLSPolicyDelegate(allowSelfSigned: endpoint.allowSelfSigned)
        super.init()
    }

    /// 曲库那一路的旧写法（调用点保持原样）。
    convenience init(songID: String, contentType: String, endpoint: Endpoint) {
        self.init(source: .audio(songID: songID), contentType: contentType, endpoint: endpoint)
    }

    /// 照片库的视频。UTI 与扩展名都从文件名推（`.MOV` 服务端也标 `video/mp4`，
    /// AVFoundation 只认容器，`public.mpeg-4` 对两种容器都成立）。
    convenience init(videoItemID: Int, endpoint: Endpoint) {
        self.init(source: .photoVideo(itemID: videoItemID),
                  contentType: UTType.mpeg4Movie.identifier,
                  endpoint: endpoint)
    }

    /// 视频的扩展名。AVFoundation 判格式依赖 URL 尾巴上的扩展名，取不到就按 mp4。
    static func videoExtension(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["mov", "mp4", "m4v"].contains(ext) ? ext : "mp4"
    }

    /// 把自己挂上 asset 的资源装载器。loader 由调用方（PlaybackEngine）与
    /// asset 成对持有 —— resource loader 不保证持住 delegate。
    func attach(to asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: workQueue)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        Self.smokeLog("装载请求进入代理 url=\(loadingRequest.request.url?.absoluteString ?? "?")")
        start(loadingRequest)
        return true
    }

    private func start(_ loadingRequest: AVAssetResourceLoadingRequest) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let total = try await self.probeTotal()
                if let info = loadingRequest.contentInformationRequest {
                    info.contentType = self.contentType
                    info.isByteRangeAccessSupported = true
                    if total > 0 { info.contentLength = total }
                }
                if let dataRequest = loadingRequest.dataRequest {
                    try await self.fetch(dataRequest, total: total, loadingRequest: loadingRequest)
                } else {
                    loadingRequest.finishLoading()
                }
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
    }

    // MARK: - 取字节

    /// 真实取流地址。两条路都是 GET、都直接回字节（不走 JSON 信封）：
    /// 曲库走 `AudioStation/stream.cgi`，照片视频走 `entry.cgi` 的 Streaming。
    /// `_sid` 走查询串；`X-SYNO-TOKEN` 在请求头（登录时开了 `enable_syno_token`，
    /// 缺 token 会被判会话无效）。
    private var streamURL: URL? {
        switch source {
        case .audio(let songID):
            var comps = URLComponents(
                url: endpoint.baseURL.appendingPathComponent("AudioStation/stream.cgi"),
                resolvingAgainstBaseURL: false
            )
            comps?.percentEncodedQuery = SynologyClient.formEncode([
                "api": "SYNO.AudioStation.Stream",
                "version": "2",
                "method": "stream",
                "id": songID,
                "_sid": endpoint.credentials.sid,
            ])
            return comps?.url
        case .photoVideo(let itemID):
            return PhotosAPI.streamingURL(itemID: itemID, endpoint: endpoint)
        }
    }

    /// 取流的请求：与 `SynologyClient` 同一套 —— `_sid` 在查询串，`X-SYNO-TOKEN`
    /// 在请求头（登录时开了 `enable_syno_token`，缺 token 会被判会话无效）。
    private func makeRequest(range: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        let token = endpoint.credentials.token
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        return request
    }

    /// 日志用的地址（`_sid` 换成星号 —— 会话令牌不落日志）。
    private func redactedURL(_ url: URL) -> String {
        let text = url.absoluteString
        guard let range = text.range(of: "_sid=") else { return text }
        let rest = text[range.upperBound...]
        let sid = rest.prefix { $0 != "&" }
        return text.replacingOccurrences(of: "_sid=\(sid)", with: "_sid=***")
    }

    /// 总长：`Range: bytes=0-0` 探一次，优先认 `Content-Range`。
    ///
    /// 服务端**不保证按 Range 裁**（实测回 200 全量），所以拿不到 `Content-Range`
    /// 时退一步用 `Content-Length`；两个都没有说明回的不是音频（DSM 的业务错误
    /// 也是 200 + JSON），这时必须抛出去 —— 不填 `contentLength` 的话 AVPlayer
    /// 会给一个看不出所以然的失败，错误信息就丢在装载请求里了。
    /// 只探一次，缓存在实例里 —— 每个装载请求都探一遍是多出来的往返。
    private func probeTotal() async throws -> Int64 {
        if let total = state.cachedTotal() { return total }

        guard let url = streamURL else { throw PlaybackError.badAsset }
        let request = makeRequest(range: "bytes=0-0", url: url)
        Self.smokeLog("探测地址 \(redactedURL(url)) token=\(endpoint.credentials.token.isEmpty ? "无" : "有")")
        let (body, response) = try await probeSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlaybackError.streamStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "-"
        let total = Self.totalBytes(from: http) ?? http.expectedContentLength
        Self.smokeLog("探测总长 http=\(http.statusCode) mime=\(mime) total=\(total) 头=\(http.allHeaderFields)")

        guard total > 0, Self.looksLikeMedia(mime) else {
            // 不是媒体：多半是 JSON 错误信封（`{"error":{"code":N}}`），把 code 挖出来。
            let snippet = String(data: body.prefix(300), encoding: .utf8) ?? "<非文本>"
            Self.smokeLog("探测应答不是媒体，体=\(snippet)")
            if let code = Self.errorCode(in: body) { throw PlaybackError.streamRejected(code) }
            throw PlaybackError.streamStatus(http.statusCode)
        }
        state.storeTotal(total)
        return total
    }

    /// MIME 看起来是媒体（服务端给 `audio/mpeg` / `video/mp4` 一类；有的回
    /// `application/octet-stream`）。DSM 的业务错误也是 200，所以这一条断言是
    /// 「回的不是错误信封」的判据。
    private static func looksLikeMedia(_ mime: String) -> Bool {
        let lower = mime.lowercased()
        return lower.hasPrefix("audio/") || lower.hasPrefix("video/")
            || lower.contains("octet-stream") || lower.contains("mpegurl")
    }

    /// 从 DSM 的错误信封里挖业务码。
    private static func errorCode(in body: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return nil }
        return error["code"] as? Int
    }

    /// `Content-Range: bytes 0-0/5316164` → 5316164。
    private static func totalBytes(from response: HTTPURLResponse) -> Int64? {
        for (key, value) in response.allHeaderFields {
            guard (key as? String)?.caseInsensitiveCompare("Content-Range") == .orderedSame,
                  let text = value as? String,
                  let slash = text.lastIndex(of: "/")
            else { continue }
            return Int64(text[text.index(after: slash)...])
        }
        return nil
    }

    private func fetch(
        _ dataRequest: AVAssetResourceLoadingDataRequest,
        total: Int64,
        loadingRequest: AVAssetResourceLoadingRequest
    ) async throws {
        let offset = Int64(dataRequest.requestedOffset)
        let wantsAll = dataRequest.requestsAllDataToEndOfResource
        let length: Int64 = wantsAll
            ? (total > 0 ? total - offset : -1)
            : Int64(dataRequest.requestedLength)
        guard length != 0 else {
            loadingRequest.finishLoading()
            return
        }

        guard let url = streamURL else { throw PlaybackError.badAsset }
        // -1 = 开放到结尾（探测没拿到总长时）。
        let request = makeRequest(
            range: length > 0 ? "bytes=\(offset)-\(offset + length - 1)" : "bytes=\(offset)-",
            url: url
        )

        let handler = Handler(loadingRequest: loadingRequest, offset: offset, limit: length)
        let task = streamSession.dataTask(with: request)
        handler.attach(task: task)
        state.register(handler, for: task)

        task.resume()
        Self.smokeLog("开始取字节 offset=\(offset) length=\(length) wantsAll=\(wantsAll)")
        await handler.waitForCompletion()
        state.unregister(task)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        tlsPolicy.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.allow)
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            state.handler(for: dataTask)?.finish(with: PlaybackError.streamStatus(http.statusCode))
            return
        }
        // 2xx 之外还能骗人：DSM 的业务错误是 200 + JSON。MIME 不像音频就当场判失败。
        let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "-"
        guard Self.looksLikeMedia(mime) else {
            Self.smokeLog("取字节应答不是媒体 mime=\(mime)")
            state.handler(for: dataTask)?.finish(with: PlaybackError.streamNotMedia)
            return
        }
        // 服务端没按 Range 裁（回 200 全量）时，把 offset 前的字节丢掉再喂。
        Self.smokeLog("取字节应答 http=\(http.statusCode) mime=\(mime) len=\(http.expectedContentLength)")
        state.handler(for: dataTask)?.begin(status: http.statusCode)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.handler(for: dataTask)?.deliver(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let handler = state.handler(for: task) else { return }
        // 取消不是错误 —— AVPlayer 换歌 / 暂停时主动掐断连接，-999 上报出去
        // 只会让 item 莫名其妙 failed。
        if let error = error as? URLError, error.code == .cancelled {
            handler.finish(with: nil)
            return
        }
        handler.finish(with: error)
    }
}

// MARK: - 单个装载请求的搬运

/// 把一个 Range 请求的字节喂给一个装载请求。`respond(with:)` 可以分多次调，
/// 数据到手就喂，不必攒完整段。
///
/// `limit` 是这次装载请求要的字节数：服务端**忽略 Range 回 200 全量**时它必须
/// 生效 —— 喂多了 AVFoundation 会判请求不满足（实测直接掉 item failed）。
private final class Handler: @unchecked Sendable {
    private let loadingRequest: AVAssetResourceLoadingRequest
    private let offset: Int64
    private let limit: Int64
    private let lock = NSLock()
    private var skip = Int64(0)
    private var delivered = Int64(0)
    private var finished = false
    private var task: URLSessionDataTask?
    private var completion: CheckedContinuation<Void, Never>?

    init(loadingRequest: AVAssetResourceLoadingRequest, offset: Int64, limit: Int64) {
        self.loadingRequest = loadingRequest
        self.offset = offset
        self.limit = limit
    }

    func attach(task: URLSessionDataTask) {
        lock.withLock { self.task = task }
    }

    func begin(status: Int) {
        lock.withLock { skip = status == 206 ? 0 : offset }
    }

    func deliver(_ data: Data) {
        var chunk: Data?
        var cancelled = false
        var satisfied = false
        lock.withLock {
            if finished { return }
            if loadingRequest.isCancelled {
                finished = true
                task?.cancel()
                cancelled = true
                return
            }
            var payload = data
            if skip > 0 {
                if payload.count <= Int(skip) {
                    skip -= Int64(payload.count)
                    return
                }
                payload = payload.dropFirst(Int(skip))
                skip = 0
            }
            if limit > 0 {
                let remaining = limit - delivered
                if remaining <= 0 {
                    satisfied = true
                    return
                }
                if Int64(payload.count) > remaining {
                    payload = payload.prefix(Int(remaining))
                }
                delivered += Int64(payload.count)
                satisfied = delivered >= limit
            }
            chunk = payload.isEmpty ? nil : payload
        }
        if cancelled {
            finish(with: nil)
            return
        }
        if let chunk {
            loadingRequest.dataRequest?.respond(with: chunk)
        }
        // 要的字节喂齐了就收工 —— 别等服务端把整个文件推完。
        if satisfied {
            finish(with: nil)
        }
    }

    func finish(with error: Error?) {
        // 已收过工就别再碰 loadingRequest —— 重复 finish AVFoundation 会告警。
        var alreadyFinished = false
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !finished else {
                alreadyFinished = true
                return nil
            }
            finished = true
            task?.cancel()
            let pending = completion
            completion = nil
            return pending
        }
        guard !alreadyFinished else { return }
        // finishLoading 会回调回 AVFoundation，别持着锁调。
        if let error {
            loadingRequest.finishLoading(with: error)
        } else {
            loadingRequest.finishLoading()
        }
        cont?.resume()
    }

    func waitForCompletion() async {
        if lock.withLock({ finished }) { return }
        await withCheckedContinuation { cont in
            lock.withLock {
                if finished {
                    cont.resume()
                } else {
                    completion = cont
                }
            }
        }
    }
}

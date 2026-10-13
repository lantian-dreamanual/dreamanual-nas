import Foundation

/// 专辑封面缓存。
///
/// 曲库表一屏几十行，滚起来会不停要图 —— 三件事必须有：
///   ① **按「专辑 + 专辑艺术家」做键**：封面接口只认这两个参数（拿 id 要一律
///      404），一张专辑一次请求，同专辑的歌共用，命中缓存就是零请求；
///   ② **负缓存**：专辑没有内嵌封面时也把这个结果记住，否则每次滚回来都重问；
///   ③ **限流**：同时最多 4 个在飞 —— 对面是家用 NAS，不是 CDN。
actor CoverStore {
    static let shared = CoverStore()

    /// 冒烟日志开关（与 `AudioLibrary` / `PlaybackEngine` 同一个环境变量）。
    private static let smoke = ProcessInfo.processInfo.environment["DM_SMOKE"] == "1"

    private static func smokeLog(_ text: String) {
        guard smoke else { return }
        NSLog("[cover] %@", text)
    }

    private let maxConcurrent = 4

    private var cache: [String: Data?] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 缓存键。中间那个 `\u{1}` 是防撞的分隔符 —— 专辑名里本来就可能出现
    /// `-` / `/` / 空格，直接拼接会让「同名但不同艺术家」的两张专辑互为对方。
    private static func key(_ album: String, _ artist: String) -> String {
        "\(album)\u{1}\(artist)"
    }

    /// 取一张专辑的封面。**取不到不报错**，回 `nil` 让界面退回占位 ——
    /// 专辑没有内嵌封面是常态，不是异常。
    ///
    /// - Returns: JPEG 字节；没有专辑标签、服务端没有这张图、或回的压根不是
    ///   图片（DSM 的业务错误也是 200 + JSON）时为 `nil`。
    func cover(manager: SessionManager, album: String, artist: String) async -> Data? {
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !album.isEmpty else { return nil }
        let key = Self.key(album, artist)

        if let cached = cache[key] { return cached }
        // 同一张专辑常常同时有几行在要（一屏里同专辑的歌挨着）—— 只发一次。
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<Data?, Never> {
            await load(manager: manager, album: album, artist: artist)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = result
        return result
    }

    private func load(manager: SessionManager, album: String, artist: String) async -> Data? {
        await acquire()
        var result: Data?
        do {
            result = try await AudioLibrary.cover(manager, album: album, artist: artist)
            Self.smokeLog("「\(album)」/\(artist.isEmpty ? "-" : artist) → \(result?.count ?? 0) 字节")
        } catch {
            Self.smokeLog("「\(album)」取不到：\(error.localizedDescription)")
        }
        release()
        return result
    }

    /// 换一台 NAS（重新连接）时清掉 —— 键里只有专辑名，不区分是哪个库。
    func clear() {
        cache.removeAll()
        inFlight.removeAll()
    }

    // MARK: 限流

    /// 名额还有就直接走；没有了排队，等前一个 `release()` 放行。
    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    private func release() {
        running -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }
}

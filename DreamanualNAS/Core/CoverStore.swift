import Foundation

/// 专辑封面缓存。
///
/// 曲库表一屏几十行，滚起来会不停要图 —— 三件事必须有：
///   ① **按「专辑所在目录 + 档位」做键**：首选从歌自己目录里的图片取图（同一张
///      专辑一个目录，一屏里同专辑的歌共用一份），目录里没图才退到按
///      「专辑名 + 专辑艺术家」问 `cover.cgi`。缓存命中就是零请求；
///   ② **负缓存**：两条路都没有图时也把这个结果记住，否则每次滚回来都重问；
///   ③ **限流**：同时最多 4 个在飞 —— 对面是家用 NAS，不是 CDN。
///
/// 🔴 **为什么键从「专辑 + 艺术家」换成了目录**（2026-10-13）：库里同名但不同源的
/// 专辑只要都缺 `album_artist` 标签，DSM 会把它们并成一个专辑实体、只给一张图
/// （实测「0」并了 Low Roar / Superfly / 林忆莲 三家）—— 按专辑名取图必然串台。
/// 目录是曲库自己的分法（一张专辑一个目录），跟着目录走就不会串。
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
    /// 目录为空（拿不到路径）时退回「专辑 + 艺术家」那套键。
    private static func key(_ album: String, _ artist: String, _ folder: String, _ highRes: Bool) -> String {
        let base = folder.isEmpty ? "\(album)\u{1}\(artist)" : "dir\u{1}\(folder)"
        return base + (highRes ? "\u{1}full" : "\u{1}small")
    }

    /// 取一张专辑的封面。**取不到不报错**，回 `nil` 让界面退回占位 ——
    /// 专辑没有封面图是常态，不是异常。
    ///
    /// - Parameters:
    ///   - folder: 歌所在目录（`AudioSong.folder`）。**首选从它取图**。
    ///   - highRes: 大图场景（沉浸屏）取原图，小图走 120×120 缩略图。
    /// - Returns: JPEG 字节；两条路都没有时为 `nil`。
    func cover(
        manager: SessionManager,
        album: String,
        artist: String,
        folder: String = "",
        highRes: Bool = false
    ) async -> Data? {
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只有专辑名空、目录也空时才是真的没得取。
        guard !album.isEmpty || !folder.isEmpty else { return nil }
        let key = Self.key(album, artist, folder, highRes)

        if let cached = cache[key] { return cached }
        // 同一张专辑常常同时有几行在要（一屏里同专辑的歌挨着）—— 只发一次。
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<Data?, Never> {
            await load(manager: manager, album: album, artist: artist,
                       folder: folder, highRes: highRes)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = result
        return result
    }

    private func load(
        manager: SessionManager,
        album: String,
        artist: String,
        folder: String,
        highRes: Bool
    ) async -> Data? {
        await acquire()
        var result: Data?
        // 一档：歌自己目录里的封面图（不受 DSM 专辑合并影响）。
        if !folder.isEmpty {
            do {
                result = try await AudioLibrary.folderCover(manager, folder: folder, highRes: highRes)
                Self.smokeLog("目录 \(folder) → \(result?.count ?? 0) 字节")
            } catch {
                Self.smokeLog("目录 \(folder) 取不到：\(error.localizedDescription)")
            }
        }
        // 二档：目录里没有图，才按专辑名问 Audio Station。
        if result == nil, !album.isEmpty {
            do {
                result = try await AudioLibrary.cover(manager, album: album, artist: artist)
                Self.smokeLog("「\(album)」/\(artist.isEmpty ? "-" : artist) → \(result?.count ?? 0) 字节")
            } catch {
                Self.smokeLog("「\(album)」取不到：\(error.localizedDescription)")
            }
        }
        release()
        return result
    }

    /// 换一台 NAS（重新连接）时清掉 —— 键里只有目录，不区分是哪个库。
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

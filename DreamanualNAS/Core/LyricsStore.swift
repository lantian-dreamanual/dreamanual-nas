import Foundation

/// 歌词缓存 + 取词次序。
///
/// 取一次词是**两个请求**（先问内嵌、没有再问在线搜索），而沉浸模式会在
/// 切歌时反复要 —— 按歌曲 id 缓存，切回来就是零请求。与 `CoverStore` 同构
/// （actor + 在飞去重 + 负结果也记），但不限流：歌词是换歌才要一次，
/// 不像封面那样一屏几十张。
actor LyricsStore {
    static let shared = LyricsStore()

    /// 冒烟日志开关（与 `AudioLibrary` / `PlaybackEngine` 同一个环境变量）。
    private static let smoke = ProcessInfo.processInfo.environment["DM_SMOKE"] == "1"
    private static let immersiveSmoke = ProcessInfo.processInfo.environment["DM_IMMERSIVE"] == "1"

    private static func smokeLog(_ text: String) {
        guard smoke || immersiveSmoke else { return }
        NSLog("[lyrics] %@", text)
    }

    /// 歌曲 id → 歌词（nil = 内嵌与在线都没有，负结果也记）。
    private var cache: [String: Lyrics?] = [:]
    private var inFlight: [String: Task<Lyrics?, Never>] = [:]

    /// 取一首歌的歌词：**内嵌优先、在线兜底**，两边都没有回 nil。
    func lyrics(manager: SessionManager, song: AudioSong) async -> Lyrics? {
        let key = song.id
        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<Lyrics?, Never> { await load(manager: manager, song: song) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = result
        return result
    }

    /// 换一台 NAS 时清掉（键只有歌曲 id，不区分是哪个库）。
    func clear() {
        cache.removeAll()
        inFlight.removeAll()
    }

    private func load(manager: SessionManager, song: AudioSong) async -> Lyrics? {
        do {
            if let embedded = try await LyricsService.embedded(manager, songID: song.id) {
                Self.smokeLog("「\(song.title)」内嵌 \(embedded.lines.count) 行（时间轴 \(embedded.hasTimeline ? "有" : "无")）")
                return embedded
            }
        } catch {
            Self.smokeLog("「\(song.title)」内嵌读取失败：\(error.localizedDescription)")
        }

        // 在线搜索：取**第一条有正文的候选**。同一首歌常有多个版本（Live / 现场），
        // 界面不做挑选（挑版本要另开一屏，本期不做）。
        do {
            let candidates = try await LyricsService.search(
                manager,
                title: song.title,
                artist: song.artist
            )
            guard let hit = candidates.first(where: { $0.lyrics != nil }), let lyrics = hit.lyrics else {
                Self.smokeLog("「\(song.title)」在线 \(candidates.count) 条候选，都没正文 → 未匹配")
                return nil
            }
            Self.smokeLog("「\(song.title)」在线命中 \(hit.plugin) \(lyrics.lines.count) 行")
            return lyrics
        } catch {
            Self.smokeLog("「\(song.title)」在线搜索失败：\(error.localizedDescription)")
            return nil
        }
    }
}

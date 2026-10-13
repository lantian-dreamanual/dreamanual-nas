import Foundation

// MARK: - 模型

/// 一行歌词。`time` 为 nil = 这行没有时间轴（整篇纯文本歌词都是 nil）。
struct LyricLine: Equatable {
    let time: Double?
    let text: String
}

/// 一首歌的歌词。
///
/// 两个来源、同一种用法：**文件内嵌**（`getlyrics` 读 ID3 的 `USLT` 帧，
/// 原文透传、自带 LRC 时间轴）与**在线搜索**（歌词插件装在 NAS 上，回多候选）。
/// 库里带内嵌歌词的只有约 0.3%（接口结论 §八实测），所以在线搜索是主力。
struct Lyrics: Equatable {
    enum Origin: Equatable {
        case embedded
        case online(plugin: String)
    }

    let lines: [LyricLine]
    let origin: Origin

    var isEmpty: Bool { lines.isEmpty }

    /// 有时间轴才逐行高亮；纯文本歌词整篇一起显示、不标当前行。
    var hasTimeline: Bool { lines.contains { $0.time != nil } }

    /// 当前时间落在哪一行：时间不晚于 `seconds` 的**最后一行**。
    /// 纯文本歌词（没有一行带时间）回 nil。
    func activeIndex(at seconds: Double) -> Int? {
        var found: Int?
        for (index, line) in lines.enumerated() {
            guard let time = line.time else { continue }
            if time <= seconds { found = index } else { break }
        }
        return found
    }
}

/// 在线搜索的一条候选。同一首歌常有多个版本（Live / 现场 / 翻唱），
/// 所以搜索回的是**列表**而不是一条。`lyrics` 为 nil = 这条候选本身没正文
/// （实测存在的边界，界面上要能认出来）。
struct LyricsCandidate: Equatable {
    let id: String
    let plugin: String
    let preview: String
    let lyrics: Lyrics?
}

// MARK: - 读取层

/// 歌词读取（只读）。
///
/// 🔴 两个接口**都只在专路径上**，走 `entry.cgi` 一律回 `code 102`（接口结论
/// §八实测）。路径照实测写死，不是猜 cgi 名 —— 猜错时服务端回 HTML 错误页，
/// 解包失败会被当成「方法不存在」，得看原始应答的 `Content-Type` 才判得出来。
enum LyricsService {

    private static let mediaAPI = "SYNO.AudioStation.Lyrics"
    private static let searchAPI = "SYNO.AudioStation.LyricsSearch"

    /// 读文件内嵌歌词。**没有歌词回 nil，不当错误** —— 全库只有约 0.3% 带内嵌，
    /// 空串是这个接口的常态应答。
    static func embedded(_ manager: SessionManager, songID: String) async throws -> Lyrics? {
        let data = try await manager.get(
            kind: .audio,
            api: mediaAPI,
            version: 2,
            method: "getlyrics",
            params: ["id": songID],
            path: "AudioStation/lyrics.cgi"
        )
        let raw = (data as? [String: Any])?["lyrics"] as? String ?? ""
        let lines = parse(raw)
        return lines.isEmpty ? nil : Lyrics(lines: lines, origin: .embedded)
    }

    /// 在线搜索：按「歌名 + 歌手」问 Nano 上装的歌词插件，回候选数组。
    ///
    /// 参数是实测的那一组（`title` / `artist` / `limit` / `additional`）——
    /// 插件会变（实测两次分别经手 QQ音乐、网易云音乐），**不要按插件名写死**。
    static func search(
        _ manager: SessionManager,
        title: String,
        artist: String,
        limit: Int = 5
    ) async throws -> [LyricsCandidate] {
        let data = try await manager.get(
            kind: .audio,
            api: searchAPI,
            version: 2,
            method: "searchlyrics",
            params: [
                "title": title,
                "artist": artist,
                "limit": String(limit),
                // `additional` 在 AudioStation 侧只认逗号串（与相册侧正好相反）。
                "additional": "full_lyrics",
            ],
            path: "AudioStation/lyrics_search.cgi"
        )
        let raw = (data as? [String: Any])?["lyrics"] as? [Any] ?? []
        return raw.compactMap { item in
            guard let item = item as? [String: Any] else { return nil }
            let plugin = item["plugin"] as? String ?? ""
            let additional = (item["additional"] as? [String: Any]) ?? [:]
            let lines = parse(additional["full_lyrics"] as? String ?? "")
            return LyricsCandidate(
                id: item["id"] as? String ?? "",
                plugin: plugin,
                preview: item["partial_lyrics"] as? String ?? "",
                lyrics: lines.isEmpty ? nil : Lyrics(lines: lines, origin: .online(plugin: plugin))
            )
        }
    }

    // MARK: LRC 解析

    /// 解析歌词文本，两种形态都吃：
    ///
    /// · **LRC**（带时间轴）：`[00:12.34] 灯熄了 路还长` —— 行首方括号里的时间
    ///   抽成 `time`。一行挂多个时间戳时（`[00:10][01:20]同一句`）按多个时间展开。
    /// · **纯文本**：没有方括号、或方括号里不是时间，整行当 `time = nil`。
    ///
    /// 元数据标签（`[ti:]` / `[ar:]` / `[al:]` / `[by:]` / `[offset:]`）剥掉不留 ——
    /// 它们是 ID3 的行，不是歌词的行。剥完没内容的行整行丢掉。
    static func parse(_ raw: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            var times: [Double] = []

            // 行首连续的方括号标签。正文一出现就停（行中间的方括号不是标签）。
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let inner = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = String(rest[rest.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
                if let seconds = seconds(inner) { times.append(seconds) }
            }

            // 剥完只剩空白：整行是标签（`[ti:]` / `[by:]` 这类元数据行），不进歌词。
            guard !rest.isEmpty else { continue }

            if times.isEmpty {
                out.append(LyricLine(time: nil, text: rest))
            } else {
                for time in times { out.append(LyricLine(time: time, text: rest)) }
            }
        }
        return out
    }

    /// 标签内文 → 秒。认 `mm:ss` / `mm:ss.xx` / `mm:ss.xxx`，不认就回 nil
    /// （元数据标签走的就是这一支）。
    private static func seconds(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count >= 2, let minutes = Double(parts[0]) else { return nil }
        let secondParts = parts[1].split(whereSeparator: { $0 == "." || $0 == ":" })
        guard let whole = secondParts.first.flatMap({ Double($0) }) else { return nil }
        var fraction = 0.0
        if secondParts.count > 1, let digits = Int(secondParts[1]) {
            fraction = Double(digits) / pow(10, Double(secondParts[1].count))
        }
        return minutes * 60 + whole + fraction
    }
}

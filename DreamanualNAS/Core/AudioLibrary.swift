import Foundation

// MARK: - 模型

/// 曲库里的一首歌。字段名与来源照 `docs/接口结论.md` 第二节的实测表：
/// 顶层 `id` / `path` / `title`；`additional.song_tag` 带专辑与标签；
/// `additional.song_audio` 带时长与码率；`additional.song_rating` 带评分。
struct AudioSong: Identifiable, Equatable {
    let id: String
    /// 完整曲库路径（`/music/<歌手>/<年.专辑>/<轨道>.<标题>.mp3`）。
    /// 「在文件管理中显示」直接拿它去 FileStation，不必另查。
    let path: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let genre: String
    let year: Int?
    let track: Int?
    let disc: Int?
    /// 时长（秒）。接口给的就是秒。
    let duration: Int
    let bitrate: Int
    let frequency: Int
    let codec: String
    let container: String
    let filesize: Int64
    /// 0–5，未评分是 0。
    let rating: Int

    init?(_ raw: [String: Any]) {
        let id = jsonString(raw["id"])
        let title = jsonString(raw["title"])
        guard !id.isEmpty, !title.isEmpty else { return nil }

        // 标签与音频信息都包在 `additional` 这一层下面（song_tag / song_audio /
        // song_rating 是它的三个键）—— 直接读顶层会拿到空，整张表只剩标题。
        let additional = (raw["additional"] as? [String: Any]) ?? [:]
        let tag = (additional["song_tag"] as? [String: Any]) ?? [:]
        let audio = (additional["song_audio"] as? [String: Any]) ?? [:]
        let ratingBox = (additional["song_rating"] as? [String: Any]) ?? [:]

        self.id = id
        self.path = jsonString(raw["path"])
        self.title = title
        self.artist = jsonString(tag["artist"])
        self.album = jsonString(tag["album"])
        self.albumArtist = jsonString(tag["album_artist"])
        self.genre = jsonString(tag["genre"])
        self.year = jsonInt(tag["year"])
        self.track = jsonInt(tag["track"])
        self.disc = jsonInt(tag["disc"])
        self.duration = jsonInt(audio["duration"]) ?? 0
        self.bitrate = jsonInt(audio["bitrate"]) ?? 0
        self.frequency = jsonInt(audio["frequency"]) ?? 0
        self.codec = jsonString(audio["codec"])
        self.container = jsonString(audio["container"])
        self.filesize = Int64(jsonInt(audio["filesize"]) ?? 0)
        self.rating = jsonInt(ratingBox["rating"]) ?? 0
    }

    /// 流派是多值字段，用「;」分隔 —— 列表里拆成标签。
    var genreTags: [String] {
        genre.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 时长显示：`4:12` / `1:02:03`。
    var durationText: String {
        let total = max(0, duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    var yearText: String { year.map(String.init) ?? "" }
}

struct AudioArtist: Identifiable, Equatable {
    let name: String
    var id: String { name }
}

/// 专辑条目**没有 `id` 字段**（实测），拿「专辑名 + 专辑艺术家」当身份。
struct AudioAlbum: Identifiable, Equatable {
    let name: String
    let artist: String
    let year: Int?
    var id: String { "\(name)\u{1}\(artist)" }
    var yearText: String { year.map(String.init) ?? "" }
}

/// 单字段筛选的四个字段 —— `Song.search` 认这几个，**一次只认一个**。
enum SongField: String, CaseIterable {
    case title
    case artist
    case album
    case genre

    var label: String {
        switch self {
        case .title: return "标题"
        case .artist: return "艺术家"
        case .album: return "专辑"
        case .genre: return "流派"
        }
    }
}

struct SongFilter: Equatable {
    let field: SongField
    let value: String
}

struct AudioSongPage {
    let songs: [AudioSong]
    let total: Int
}

// MARK: - 读取层

/// 曲库读取（只读）。会话由 `SessionManager` 管，这里只管「发哪条接口、怎么解包」。
///
/// 四条实测约束，改了会**静默出错**（服务端不报错，只能靠结果不对发现）：
/// ① `additional` 只认逗号串 —— 给 JSON 数组时标签一条都不回来，
///    条目只剩 `id` / `path` / `title`；
/// ② `library` 一律传 `all` —— 这台机器的曲库在**共享库**，`personal` 会把结果筛空
///    （流派数从 97 掉到 0）；
/// ③ 筛选走 `Song.search`（子串匹配），`Song.list` 是精确匹配 ——
///    `list album=潮汐` 回 0 条、`search album=潮汐` 回 2 条；
/// ④ 统一搜索的方法名是 `list` 不是 `search`；`keyword` 空着会回**全库**，
///    调用点必须自己拦住空关键词。
enum AudioLibrary {

    /// 一页 1000 首约 1.1 秒，整库 12331 首拉完要 14.7 秒 —— 首屏拉一页，
    /// 滚到底再要下一页。
    static let pageSize = 1000

    /// 一次要齐三类附加字段。**逗号串，不是数组。**
    private static let additional = "song_tag,song_audio,song_rating"

    private static let songAPI = "SYNO.AudioStation.Song"

    // MARK: 全部曲目

    static func songs(
        _ manager: SessionManager,
        offset: Int = 0,
        limit: Int = pageSize
    ) async throws -> AudioSongPage {
        let data = try await manager.call(
            kind: .audio,
            api: songAPI,
            version: 3,
            method: "list",
            params: [
                "library": "all",
                "offset": String(offset),
                "limit": String(limit),
                "additional": additional,
            ]
        )
        return songPage(data)
    }

    // MARK: 筛选

    static func songs(
        _ manager: SessionManager,
        matching filter: SongFilter,
        offset: Int = 0,
        limit: Int = pageSize
    ) async throws -> AudioSongPage {
        let data = try await manager.call(
            kind: .audio,
            api: songAPI,
            version: 3,
            method: "search",
            params: [
                "library": "all",
                filter.field.rawValue: filter.value,
                "offset": String(offset),
                "limit": String(limit),
                "additional": additional,
            ]
        )
        return songPage(data)
    }

    /// 按标题 / 艺术家 / 专辑三个字段各搜一次，按曲目 id 合并去重。
    ///
    /// 曲库搜索框一次要覆盖这三类（原型搜索框的占位就是「搜索标题、艺术家、专辑」），
    /// 而 `Song.search` 一次只认一个字段 —— 那就并发发三条、合并。拿到的是
    /// **每个字段的前 `limit` 条**，不是全量命中：搜索框用来找歌，不是导库。
    ///
    /// 统一搜索 `SYNO.AudioStation.Search`（一次回艺术家 / 专辑 / 单曲三组）不在这条路上
    /// —— 它回的单曲条目只有 `id` / `path` / `title`，没有艺术家与专辑，
    /// 铺不出这张表。
    static func search(
        _ manager: SessionManager,
        keyword: String,
        limit: Int = 300
    ) async throws -> AudioSongPage {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AudioSongPage(songs: [], total: 0) }

        async let titlePage = songs(manager, matching: SongFilter(field: .title, value: trimmed), limit: limit)
        async let artistPage = songs(manager, matching: SongFilter(field: .artist, value: trimmed), limit: limit)
        async let albumPage = songs(manager, matching: SongFilter(field: .album, value: trimmed), limit: limit)

        let pages = [try await titlePage, try await artistPage, try await albumPage]
        var seen = Set<String>()
        var merged: [AudioSong] = []
        for page in pages {
            for song in page.songs where seen.insert(song.id).inserted {
                merged.append(song)
            }
        }
        merged.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return AudioSongPage(songs: merged, total: merged.count)
    }

    // MARK: 艺术家 / 专辑 / 流派

    static func artists(_ manager: SessionManager) async throws -> [AudioArtist] {
        try await paged(manager, api: "SYNO.AudioStation.Artist", version: 4, key: "artists")
            .map { AudioArtist(name: jsonString($0["name"])) }
            .filter { !$0.name.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func albums(_ manager: SessionManager) async throws -> [AudioAlbum] {
        try await paged(manager, api: "SYNO.AudioStation.Album", version: 3, key: "albums")
            .compactMap { raw -> AudioAlbum? in
                let name = jsonString(raw["name"])
                guard !name.isEmpty else { return nil }
                // 专辑条目没有 id；`display_artist` 是界面上该显示的那个名字，
                // 拿不到才退到 `album_artist` / `artist`。
                var artist = jsonString(raw["display_artist"])
                if artist.isEmpty { artist = jsonString(raw["album_artist"]) }
                if artist.isEmpty { artist = jsonString(raw["artist"]) }
                return AudioAlbum(name: name, artist: artist, year: jsonInt(raw["year"]))
            }
    }

    /// 流派列表。实测 97 条里**含一个空名**，在这里滤掉。
    static func genres(_ manager: SessionManager) async throws -> [String] {
        try await paged(manager, api: "SYNO.AudioStation.Genre", version: 3, key: "genres")
            .map { jsonString($0["name"]) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 逐页拉一个实体列表，直到拿满 `total` 或某一页不满。
    ///
    /// 三个实体接口都回 `total`，但**不要**指望去调 `limit=-1` 一把拿完 ——
    /// 未知参数值会被服务端静默吞掉、退回默认页大小（这一族接口的通用坑），
    /// 结果就是列表被悄悄截断。宁可多几次请求。
    private static func paged(
        _ manager: SessionManager,
        api: String,
        version: Int,
        key: String
    ) async throws -> [[String: Any]] {
        var collected: [[String: Any]] = []
        var offset = 0
        while true {
            let data = try await manager.call(
                kind: .audio,
                api: api,
                version: version,
                method: "list",
                params: [
                    "library": "all",
                    "offset": String(offset),
                    "limit": String(pageSize),
                ]
            )
            guard let dict = data as? [String: Any],
                  let list = dict[key] as? [[String: Any]],
                  !list.isEmpty
            else { break }
            collected.append(contentsOf: list)
            offset += list.count
            let total = jsonInt(dict["total"]) ?? offset
            if offset >= total || list.count < pageSize { break }
        }
        return collected
    }

    // MARK: 解包

    private static func songPage(_ raw: Any) -> AudioSongPage {
        guard let dict = raw as? [String: Any] else { return AudioSongPage(songs: [], total: 0) }
        let list = (dict["songs"] as? [[String: Any]]) ?? []
        let songs = list.compactMap { AudioSong($0) }
        return AudioSongPage(songs: songs, total: jsonInt(dict["total"]) ?? songs.count)
    }
}

// MARK: - JSON 取值

/// 接口偶尔把数字给成字符串（`duration` 见过 `"252"`），两种都收。
private func jsonInt(_ value: Any?) -> Int? {
    switch value {
    case let number as Int: return number
    case let number as Double: return Int(number)
    case let text as String: return Int(text)
    default: return nil
    }
}

private func jsonString(_ value: Any?) -> String {
    switch value {
    case let text as String: return text
    case let number as NSNumber: return number.stringValue
    default: return ""
    }
}

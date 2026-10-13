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
    /// 0–5，未评分是 0。**唯一可变字段** —— 评完分只动这一格，
    /// 不重拉整页（写评分那条路要回读校验，拿回来的值与这里对齐）。
    var rating: Int

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

    /// 歌所在目录。曲库的约定是一张专辑一个目录（`/music/<歌手>/<年.专辑>/`），
    /// 封面就放在这个目录里 —— 取图用它比问专辑名可靠，理由见 `folderCover`。
    var folder: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }
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

/// 歌单。`type` 是 `normal` / `smart`（智能歌单，按规则自动收歌）；
/// `__SYNO_` 开头的是系统歌单，界面上不出现。
struct AudioPlaylist: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let type: String

    /// 系统歌单靠 **name** 前缀判 —— `id` 的形态是 `playlist_personal_normal/<名字>`
    /// （实测，「共享歌曲」的 id 也是这个前缀拼出来的），挂在 id 上永远判不中。
    var isSystem: Bool { name.hasPrefix("__SYNO_") }
    var isSmart: Bool { type == "smart" }
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

/// 评分写入没有真的生效（写了与回读对不上）。
///
/// `Song.setrating` 的成功标志不可信 —— 拿一个不存在的 id 去写，服务端照样回
/// `{"success": true}`。所以判据只能是自己再读一遍。
enum RatingError: LocalizedError {
    case notApplied(wrote: Int, readBack: Int)

    var errorDescription: String? {
        switch self {
        case .notApplied(let wrote, let readBack):
            return "评分没写进去：写的是 \(wrote) 星，回读是 \(readBack) 星。"
        }
    }
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

    /// 冒烟自检的日志开关（`DM_SMOKE=1`）：歌单曲目的字段带没带全，只能看真机应答。
    private static let smoke = ProcessInfo.processInfo.environment["DM_SMOKE"] == "1"

    private static func smokeLog(_ text: String) {
        guard smoke else { return }
        NSLog("[library] %@", text)
    }

    /// 一页 1000 首约 1.1 秒，整库 12331 首拉完要 14.7 秒 —— 首屏拉一页，
    /// 滚到底再要下一页。
    static let pageSize = 1000

    /// 一次要齐三类附加字段。**逗号串，不是数组。**
    private static let additional = "song_tag,song_audio,song_rating"

    /// 歌单补标签的并发批宽。一批齐了再发下一批。
    private static let enrichBatch = 8

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

    // MARK: 每日随机

    /// 每日随机：`sort_by=random` 是服务端原生随机（实测连发 4 次回 4 种顺序、
    /// 都异于默认）。⚠️ 只有 `random` 这一个值有效，`shuffle` / `random_song`
    /// 都被静默吞掉、退回默认顺序、且不报错。
    static func randomSongs(_ manager: SessionManager, limit: Int = 100) async throws -> AudioSongPage {
        let data = try await manager.call(
            kind: .audio,
            api: songAPI,
            version: 3,
            method: "list",
            params: [
                "library": "all",
                "offset": "0",
                "limit": String(limit),
                "sort_by": "random",
                "additional": additional,
            ]
        )
        return songPage(data)
    }

    // MARK: 评分 ≥ N 星

    /// 高分曲：**评分筛不了**（`rating=` / `rating_from=` 全被静默忽略，`total`
    /// 始终是全库数），但 `sort_by=rating&sort_direction=desc` 是被认的。
    /// 全库几乎都是 0 分 → 高分的都在最前，按评分降序翻页、遇到低于门槛就停，
    /// 一次都不用拉全库。返回的 `total` 是**收上来的条数**，不是服务端的全库数
    /// —— 上面那个 `total` 对这一路没有意义，照搬会让「还有更多」永远为真。
    static func topRatedSongs(
        _ manager: SessionManager,
        minRating: Int = 4
    ) async throws -> AudioSongPage {
        var collected: [AudioSong] = []
        var offset = 0
        while true {
            let data = try await manager.call(
                kind: .audio,
                api: songAPI,
                version: 3,
                method: "list",
                params: [
                    "library": "all",
                    "offset": String(offset),
                    "limit": String(pageSize),
                    "sort_by": "rating",
                    "sort_direction": "desc",
                    "additional": additional,
                ]
            )
            let page = songPage(data)
            let qualifying = page.songs.prefix { $0.rating >= minRating }
            collected.append(contentsOf: qualifying)
            // 这一页里出现了不够星的 → 后面只会更低，收工。
            if qualifying.count < page.songs.count { break }
            if page.songs.count < pageSize { break }
            offset += page.songs.count
            if offset >= page.total { break }
        }
        return AudioSongPage(songs: collected, total: collected.count)
    }

    // MARK: 封面

    /// 专辑封面（`cover.cgi`，回 480×480 JPEG）。**现在只当兜底** —— 首选走
    /// `folderCover`（歌自己目录里那张图），理由见那个方法的注释。
    ///
    /// 🔴 参数只认 **`album_name` + `album_artist_name`** —— 拿歌曲 `id` 或文件
    /// 路径去要一律 404 回 HTML 错误页（接口结论 §二踩过：12 首逐首用 id 全 404，
    /// 当时误判成「这些文件没有内嵌封面」）。所以这一路按**专辑**问，同一张专辑
    /// 的歌共用一张图。
    static func cover(_ manager: SessionManager, album: String, artist: String) async throws -> Data {
        try await manager.data(
            kind: .audio,
            api: "SYNO.AudioStation.Cover",
            version: 3,
            method: "getcover",
            params: [
                "album_name": album,
                "album_artist_name": artist,
                "size": "small",
            ]
        )
    }

    /// 歌所在目录里的封面图（`cover.jpg` 之类）。取不到回 `nil`，交给调用方兜底。
    ///
    /// 🔴 **为什么要走这条路（2026-10-13 用户真机抓到串台）**：`getcover` 是按
    /// 「专辑名 + 专辑艺术家」在 DSM 的专辑库里找图，而库里同名但不同源的专辑只要
    /// 都缺 `album_artist` 标签，DSM 就把它们并成**一个专辑实体** —— 实测专辑名
    /// 「0」下并了 Low Roar（2014.0）/ Superfly（2020.0）/ 林忆莲（2024.0）三家
    /// 五首，于是别人的歌全挂着同一张图（用户原话：「封面都变成了林忆莲的专辑
    /// 封面」）。这不是取图接口的错，是那几张专辑在 DSM 眼里就是同一张。
    /// 曲库的目录约定是一张专辑一个目录，封面是目录里的图片文件，**从歌自己所在
    /// 的目录取图**完全不受专辑合并影响（实测三张同名专辑各自 `cover.jpg` 的
    /// md5 互不相同，随机 20 个专辑目录 20/20 有图）。
    ///
    /// - Parameter highRes: 大图场景（沉浸屏 280 见方）取原图 —— `Thumb` 只给
    ///   120×120，放大到 280 会糊。原图走 `Download` 的 **`mode=open`**：
    ///   `mode=download` 回的字节一样，但 `Content-Type` 是
    ///   `application/octet-stream`，按 MIME 判类型的代码会判错。
    static func folderCover(
        _ manager: SessionManager,
        folder: String,
        highRes: Bool
    ) async throws -> Data? {
        guard !folder.isEmpty else { return nil }
        let listing = try await manager.call(
            kind: .file,
            api: "SYNO.FileStation.List",
            version: 2,
            method: "list",
            // 🔴 `folder_path` 必须给**纯字符串**，给 JSON 数组回一整页 HTML。
            params: ["folder_path": folder, "limit": "100"]
        )
        let files = ((listing as? [String: Any])?["files"] as? [[String: Any]]) ?? []
        // 文件名不固定（这台机上是 cover.jpg），按扩展名挑第一个图片文件；
        // `.DS_Store` 这类隐藏文件跳过。
        guard let image = files.first(where: { item in
            let name = (item["name"] as? String) ?? ""
            return !name.hasPrefix(".")
                && coverExtensions.contains((name as NSString).pathExtension.lowercased())
        }), let path = image["path"] as? String else { return nil }

        if highRes {
            return try await manager.data(
                kind: .file,
                api: "SYNO.FileStation.Download",
                version: 2,
                method: "download",
                params: ["path": path, "mode": "open"]
            )
        }
        return try await manager.data(
            kind: .file,
            api: "SYNO.FileStation.Thumb",
            version: 2,
            method: "get",
            params: ["path": path, "size": "small", "rotate": "0"]
        )
    }

    /// 目录里算封面图的扩展名。
    private static let coverExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    // MARK: 评分写入

    /// 写评分（0–5，0 = 清除）。**只有 v2** —— v1 回 103（方法不存在）。
    ///
    /// 🔴 `setrating` 对一个**不存在的 id 也回 `{"success": true}`**，成功标志
    /// 不可信。写完必须回读校验：对不上就抛出去，让界面说实话，而不是把
    /// 「看起来成功」画成一颗星。
    static func setRating(
        _ manager: SessionManager,
        songID: String,
        rating: Int
    ) async throws -> Int {
        let value = max(0, min(5, rating))
        _ = try await manager.call(
            kind: .audio,
            api: songAPI,
            version: 2,
            method: "setrating",
            params: ["id": songID, "rating": String(value)]
        )
        let readBack = try await Self.rating(manager, songID: songID)
        smokeLog("写评分 \(songID) → \(value)，回读 \(readBack)")
        guard readBack == value else {
            throw RatingError.notApplied(wrote: value, readBack: readBack)
        }
        return readBack
    }

    /// 读单曲评分。`Song.getinfo` 认 `additional=song_rating` —— 键名就是它，
    /// 给 `rating` 会被忽略，`song_tag,song_audio` 也不带它。
    static func rating(_ manager: SessionManager, songID: String) async throws -> Int {
        let raw = try await songInfo(manager, id: songID)
        let box = ((raw?["additional"] as? [String: Any])?["song_rating"] as? [String: Any]) ?? [:]
        return jsonInt(box["rating"]) ?? 0
    }

    // MARK: 歌单

    /// 歌单列表。条目只有 `id` / `library` / `name` / `sharing_status` / `type`，
    /// **不带曲目数**（`Playlist.list` 给 `additional=songs` 也不展开）。
    /// `__SYNO_` 开头的是系统歌单（如「共享歌曲」），不进「我的歌单」。
    static func playlists(_ manager: SessionManager) async throws -> [AudioPlaylist] {
        let data = try await manager.call(
            kind: .audio,
            api: "SYNO.AudioStation.Playlist",
            version: 2,
            method: "list",
            params: ["offset": "0", "limit": String(pageSize)]
        )
        let list = ((data as? [String: Any])?["playlists"] as? [[String: Any]]) ?? []
        return list.compactMap { raw in
            let id = jsonString(raw["id"])
            let name = jsonString(raw["name"])
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return AudioPlaylist(id: id, name: name, type: jsonString(raw["type"]))
        }
        .filter { !$0.isSystem }
    }

    /// 歌单里的曲目。`Playlist.getinfo` + `additional=songs` 只回**壳** ——
    /// 每首只有 `id` / `path` / `title` / `type`，把三类附加字段一起要也**不展开**
    /// （实测三种写法首条顶层键完全一样），批量补的路也全灭：
    /// `Song.getinfo` 逗号串 / 重复参数都只回 1 条，`id[]` / `id[0]` 回 101，
    /// `Song.list ids=` 被静默忽略退回全库。
    ///
    /// 所以标签要**逐首** `Song.getinfo` 补（8 首一批并发）。补不到的行不丢
    /// —— 退回壳条目，表格里艺人 / 专辑留空，标题总在。
    static func songs(
        _ manager: SessionManager,
        playlistID: String
    ) async throws -> AudioSongPage {
        let data = try await manager.call(
            kind: .audio,
            api: "SYNO.AudioStation.Playlist",
            version: 2,
            method: "getinfo",
            params: [
                "id": playlistID,
                "offset": "0",
                "limit": String(pageSize),
                "additional": "songs",
            ]
        )
        let dict = (data as? [String: Any]) ?? [:]
        // 曲目挂在 `data.playlists[0].additional.songs`（实测结构，不是顶层）。
        let box = ((dict["playlists"] as? [[String: Any]])?.first?["additional"] as? [String: Any]) ?? [:]
        let list = (box["songs"] as? [[String: Any]]) ?? []
        let total = jsonInt(box["songs_total"]) ?? list.count

        var enriched = [[String: Any]?](repeating: nil, count: list.count)
        for start in stride(from: 0, to: list.count, by: enrichBatch) {
            let range = start..<min(start + enrichBatch, list.count)
            await withTaskGroup(of: (Int, [String: Any]?).self) { group in
                for index in range {
                    let id = jsonString(list[index]["id"])
                    group.addTask { [manager] in
                        guard !id.isEmpty else { return (index, nil) }
                        return (index, try? await Self.songInfo(manager, id: id))
                    }
                }
                for await (index, raw) in group {
                    enriched[index] = raw
                }
            }
        }
        smokeLog("歌单壳 \(list.count) 条 / total \(total)，标签补齐 \(enriched.compactMap { $0 }.count) 条")
        let songs = list.enumerated().compactMap { index, shell -> AudioSong? in
            AudioSong(enriched[index] ?? shell)
        }
        return AudioSongPage(songs: songs, total: max(total, songs.count))
    }

    /// 单首详情。应答结构是 `data.songs`（数组，只装一条）。
    private static func songInfo(
        _ manager: SessionManager,
        id: String
    ) async throws -> [String: Any]? {
        let data = try await manager.call(
            kind: .audio,
            api: songAPI,
            version: 3,
            method: "getinfo",
            params: ["id": id, "additional": additional]
        )
        return ((data as? [String: Any])?["songs"] as? [[String: Any]])?.first
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

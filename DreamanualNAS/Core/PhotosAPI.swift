import Foundation

/// Synology Photos（共享空间）的只读接口。
///
/// 参数形态照 2026-10-19 / 10-20 实测写（`experiments/shuffle-lab/photosprobe*.py`）：
///
/// - `Browse.Item` 的**按天过滤已失灵**（2026-10-20，Photos 1.9.1 / DSM 7.4.1 起：
///   `year` / `month` / `day` 被 `list` 与 `count` 一并无视，`list` 恒回全库
///   「从新到旧」）—— 所以条目**全量翻页取回、客户端按天分组**，不再依赖
///   服务端的日期参数；
/// - **分类过滤是好的**（10-20 实测）：`person_id` / `geocoding_id` / `album_id`
///   真生效（`person_id=387` 翻页取到 1235 条 = 人物的 `item_count`，与全库基线
///   不是同一批）；🔴 标签的参数名是 **`general_tag_id`**，`tag_id` 被静默忽略
///   （照回全库前 100 条）；`album_id` 只认裸数字（给 `[1]` 回 0 条）；
/// - `Search.Search` v7 的结果方法是 **`list_item`**（`list` / `search` / `query`
///   全 103），按 `keyword` 真过滤、无 `total`、空 `keyword` 回 `code=100`；
/// - `Browse.Person` 的封面是条目 id，缩略图要 `unit_id` —— 服务端只给
///   `additional.thumbnail.cache_key`，**它的前缀就是 `unit_id`**（实测
///   `41_1749783901` 配 `id=41` 出 42 KB 的图，配 `id=3` 回 404）；
/// - `Thumbnail` 的 `id` 要传 **`unit_id`**，传条目 `id` 回 404；`type=unit`，
///   尺寸走 `size`（sm / m / xl），认证靠 `_sid` + `X-SYNO-TOKEN`；
/// - 条目本身**没有 `path`**（`additional` 给 `path` / `folder_path` 一律 120），
///   真实路径靠 `Browse.Folder` v2 `get` 的 `name`（形如 `/2026/10`）拼 ——
///   `Browse.Folder` 的名字**是相对照片库根的完整路径**，不是叶子名。
///
/// 个人空间（`SYNO.Foto.*`）在本机回 602，先只做共享空间；接入个人空间时多一个
/// 前缀参数，调用点不用改结构。
enum PhotosAPI {
    /// 共享空间的 API 前缀。个人空间是 `SYNO.Foto`。
    static let team = "SYNO.FotoTeam"
    /// 相册只有一套接口，靠 `team_space` 切空间（`SYNO.FotoTeam.Browse.Album`
    /// 不存在恰恰是因为不需要第二套）。
    static let albumAPI = "SYNO.Foto.Browse.Album"
    /// 相册的**写**操作在另一族上：`create` / `add_item` / `delete_item` 都只在这里
    /// （`Album` 族没有 `create`，2026-10-20 实测）。
    static let normalAlbumAPI = "SYNO.Foto.Browse.NormalAlbum"
    /// 照片库在文件系统里的根（`/photo`），在文件夹中显示时拼在 `Folder.name` 前面。
    static let libraryRoot = "/photo"

    /// 条目要带的附加字段。`exif` / `rating` / `description` 是查看器信息栏用的；
    /// 人物 / 地点 / 标签的条目清单同样用这一份（多带几个字段不额外收费）。
    static let itemAdditional = "[\"thumbnail\",\"resolution\",\"exif\",\"rating\",\"description\"]"

    /// 客户端分组产生的一天（服务端骨架不再参与）。
    struct Day: Identifiable, Hashable {
        let year: Int
        let month: Int
        let day: Int

        var id: String { String(format: "%04d-%02d-%02d", year, month, day) }

        /// 分组标题：`2026年10月19日`；跨年由分组本身区分，不写星期。
        var title: String { "\(year)年\(month)月\(day)日" }
    }

    /// 一条照片或视频。
    struct Item: Identifiable, Hashable {
        let id: Int
        let filename: String
        let filesize: Int
        /// 拍摄时间。Unix 秒，**按 UTC 读出来的才是墙上时间**（12 条样本里
        /// 11 条与文件名逐字对上），显示时统一走 `PhotoDate`。
        let time: Date
        /// 进库（索引）时间。毫秒，同样按 UTC 读。「最近添加」按它排序与分组 ——
        /// 它取的是**最近 30 天进库**的项，与拍摄时间无关。
        let indexedTime: Date
        let folderID: Int
        let type: String
        let unitID: Int
        let cacheKey: String
        let width: Int
        let height: Int
        /// `additional.exif` 六件，服务端随条目下发（不另查 EXIF 接口）。
        let exif: Exif
        /// 0–5，0 就是没评过。
        let rating: Int
        /// 用户写的描述，空串按没有处理。
        let note: String?

        var isVideo: Bool { type == "video" }
        /// 像素尺寸文案：`3024 × 4032`，缺一维就不显示。
        var pixelText: String? {
            guard width > 0, height > 0 else { return nil }
            return "\(width) × \(height)"
        }

        /// 类型文案（信息栏一行）。只看 `type` 字段，不看扩展名。
        var kindText: String { isVideo ? "视频" : "照片" }

        /// EXIF 六件。全是字符串，缺一件就是没有 —— 服务端对没有 EXIF 的图
        /// （截图、导出图）整块都不下发。
        struct Exif: Hashable {
            let camera: String?
            let lens: String?
            let aperture: String?
            let exposure: String?
            let iso: String?
            let focal: String?

            static let empty = Exif(camera: nil, lens: nil, aperture: nil,
                                    exposure: nil, iso: nil, focal: nil)

            var isEmpty: Bool {
                camera == nil && lens == nil && aperture == nil
                    && exposure == nil && iso == nil && focal == nil
            }
        }
    }

    /// 条目过滤。参数名逐个实测过，见类型注释。
    enum Filter: Hashable {
        case none
        case person(Int)
        case place(Int)
        case tag(Int)
        case album(Int)

        var params: [String: String] {
            switch self {
            case .none: return [:]
            case .person(let id): return ["person_id": String(id)]
            case .place(let id): return ["geocoding_id": String(id)]
            case .tag(let id): return ["general_tag_id": String(id)]
            case .album(let id): return ["album_id": String(id)]
            }
        }
    }

    enum ThumbSize: String {
        case sm, m, xl

        /// 长边像素，信息栏与查看器用得上（服务端不告诉实际尺寸）。
        var longEdge: Int {
            switch self {
            case .sm: return 240
            case .m: return 320
            case .xl: return 1280
            }
        }
    }

    enum PhotosError: LocalizedError {
        case badShape(String)
        case emptyKeyword
        case emptyName
        case notWritable(String)
        /// 保存面板被取消。不是错误 —— 调用方据此静默返回，别弹失败提示。
        case cancelled

        var errorDescription: String? {
            switch self {
            case .badShape(let what):
                return "照片服务回了预料之外的数据（\(what)）。"
            case .emptyKeyword:
                return "请输入关键词。"
            case .emptyName:
                return "名字不能为空。"
            case .notWritable(let what):
                return "\(what)失败，NAS 没有完成这个操作。"
            case .cancelled:
                return nil
            }
        }
    }

    // MARK: - 条目

    /// 取一页条目。**不传日期参数** —— 2026-10-20 实测（Photos 1.9.1）它们被
    /// 服务端无视，传不传都回同一份全库列表；就按它给的「从新到旧」全量翻页，
    /// 分组交给 `PhotoLibrary`。应答没有 `total`，翻页终止判据是「这页不满 `limit`」。
    static func itemsPage(offset: Int, limit: Int, filter: Filter = .none,
                          manager: SessionManager) async throws -> [Item] {
        var params: [String: String] = [
            "offset": String(offset),
            "limit": String(limit),
            "additional": itemAdditional,
        ]
        params.merge(filter.params) { _, new in new }
        return try await itemList(
            api: "\(team).Browse.Item", version: 7, method: "list", params: params,
            shape: "items", manager: manager)
    }

    /// 翻页取完某个过滤下的全部条目。分类网格用（人物 1235 条 ≈ 2 页）。
    ///
    /// `cap` 是保险丝：分类过滤万一像按天过滤那样失准时，别把 1 万条当成某个人的
    /// 照片一路拉下来。超了就在日志里说一声（界面照常显示已取到的部分）。
    static func allItems(filter: Filter, pageSize: Int = 1000, cap: Int = 4000,
                         manager: SessionManager) async throws -> [Item] {
        var all: [Item] = []
        var offset = 0
        while all.count < cap {
            let page = try await itemsPage(offset: offset, limit: pageSize,
                                           filter: filter, manager: manager)
            all.append(contentsOf: page)
            offset += page.count
            if page.count < pageSize { break }
        }
        if all.count >= cap {
            NSLog("[photos] 过滤 %@ 取到上限 %d 条，余下不再拉",
                  String(describing: filter), cap)
        }
        return all
    }

    /// 「最近添加」：最近 30 天**进库**的项，按 `indexed_time` 倒序，无 `total`。
    static func recentlyAddedPage(offset: Int, limit: Int,
                                  manager: SessionManager) async throws -> [Item] {
        try await itemList(
            api: "\(team).Browse.RecentlyAdded", version: 6, method: "list",
            params: ["offset": String(offset), "limit": String(limit),
                     "additional": itemAdditional],
            shape: "recentlyAdded", manager: manager)
    }

    /// 关键词搜索。`Search.Search` v7 的结果方法是 `list_item`（`list` / `search`
    /// 全 103）。无 `total`，翻到不满页为止；空词服务端回 `code=100`，客户端先拦。
    static func searchPage(keyword: String, offset: Int, limit: Int,
                           manager: SessionManager) async throws -> [Item] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PhotosError.emptyKeyword }
        return try await itemList(
            api: "\(team).Search.Search", version: 7, method: "list_item",
            params: ["keyword": trimmed, "offset": String(offset),
                     "limit": String(limit), "additional": itemAdditional],
            shape: "search", manager: manager)
    }

    private static func itemList(api: String, version: Int, method: String,
                                 params: [String: String], shape: String,
                                 manager: SessionManager) async throws -> [Item] {
        let raw = try await manager.call(kind: .file, api: api, version: version,
                                         method: method, params: params)
        guard let root = raw as? [String: Any] else {
            throw PhotosError.badShape(shape)
        }
        return ((root["list"] as? [[String: Any]]) ?? []).compactMap { Item(json: $0) }
    }

    // MARK: - 分类

    /// 一个人物。`name` 空串即**未确认**（服务端没有过滤参数，客户端分段）。
    struct Person: Identifiable, Hashable {
        let id: Int
        let name: String
        let itemCount: Int
        /// 封面走 `Thumbnail` 的两件：`cache_key` 的前缀就是 `unit_id`。
        let coverKey: String
        let coverUnitID: Int

        var isNamed: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }
        var displayName: String { isNamed ? name : "未确认" }
    }

    /// 一个地点。字段是服务端按行政层级拼的，`name` 已经是「浦东新区, 三林镇」。
    struct Place: Identifiable, Hashable {
        let id: Int
        let name: String
        let country: String
        let itemCount: Int
    }

    /// 一个标签。
    struct Tag: Identifiable, Hashable {
        let id: Int
        let name: String
        let itemCount: Int
    }

    /// 一个相册。共享空间的相册库与个人空间同一套接口，靠 `team_space` 切。
    struct Album: Identifiable, Hashable {
        let id: Int
        let name: String
        let itemCount: Int
    }

    /// 清单翻页的通用形状：无 `total`，翻到不满页为止。人物本机 120、地点 291、
    /// 标签 11、相册 1 —— 地点那种几百条的，单页 200 一次拿不完。
    private static func paged(api: String, version: Int, additional: String? = nil,
                              extra: [String: String] = [:],
                              pageSize: Int = 200,
                              manager: SessionManager) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var offset = 0
        while rows.count < 2000 {
            var params: [String: String] = [
                "offset": String(offset),
                "limit": String(pageSize),
            ]
            if let additional { params["additional"] = additional }
            params.merge(extra) { _, new in new }
            let raw = try await manager.call(kind: .file, api: api, version: version,
                                             method: "list", params: params)
            guard let root = raw as? [String: Any] else {
                throw PhotosError.badShape(api)
            }
            let list = (root["list"] as? [[String: Any]]) ?? []
            rows.append(contentsOf: list)
            offset += list.count
            if list.count < pageSize { break }
        }
        return rows
    }

    /// 人物列表。`keyword` 服务端忽略（回的还是原序列表），搜索只能客户端过滤。
    static func persons(manager: SessionManager) async throws -> [Person] {
        try await paged(api: "\(team).Browse.Person", version: 3,
                        additional: "[\"thumbnail\"]", manager: manager)
            .compactMap { Person(json: $0) }
    }

    /// 人物命名 / 改名（`Person` v3 `set`，`name` 必传）。假 id 回 117。
    ///
    /// 🔴 参数形态实测（2026-10-21，`photosprobe22/23.py`）：**空串被服务端拒**
    /// （120 name required），首尾空白会被它 trim 掉 —— 「取消命名」就传 `" "`，
    /// 落库是无名。只改 `show` 也躲不开 `name`（见 `photosprobe23.py`，四形态全试）。
    static func setPersonName(_ personID: Int, name: String,
                              manager: SessionManager) async throws {
        _ = try await manager.call(
            kind: .file, api: "\(team).Browse.Person", version: 3, method: "set",
            params: ["id": String(personID), "name": name])
    }

    /// 人物归并：`source` 被吸收进 `target`。
    ///
    /// 🔴 形态与方向实测（2026-10-21，`photosprobe19-21.py`）：`id` 明文 =
    /// 被吸收方、`merged_id` **方括号串**（`"[243]"`）、`target_id` 明文 = 幸存方。
    /// 三个全给明文时服务端**静默空转**（回 ok、谁都不动，三种组合都试过）——
    /// `merged_id` 必须是数组串，与 `Download.unit_id` / `Item.delete` 同一套约定。
    /// 回执就是幸存者（`item_count` 已相加），照样要回读。
    static func mergePerson(source: Int, into target: Int,
                            manager: SessionManager) async throws {
        _ = try await manager.call(
            kind: .file, api: "\(team).Browse.Person", version: 3, method: "merge",
            params: ["id": String(source), "merged_id": "[\(source)]",
                     "target_id": String(target)])
    }

    static func places(manager: SessionManager) async throws -> [Place] {
        try await paged(api: "\(team).Browse.Geocoding", version: 1, manager: manager)
            .compactMap { Place(json: $0) }
    }

    static func tags(manager: SessionManager) async throws -> [Tag] {
        try await paged(api: "\(team).Browse.GeneralTag", version: 1, manager: manager)
            .compactMap { Tag(json: $0) }
    }

    static func albums(manager: SessionManager) async throws -> [Album] {
        try await paged(api: albumAPI, version: 5,
                        extra: ["team_space": "true"], manager: manager)
            .compactMap { Album(json: $0) }
    }

    // MARK: - 路径

    /// 条目所在目录（照片库内的相对路径，形如 `/2026/10`）。
    ///
    /// 条目上没有 `path`（`additional` 给 `path` 一律 120），只能拿 `folder_id`
    /// 问 `Browse.Folder`。它的 `name` 是**相对照片库根的完整路径**，不是叶子名 ——
    /// 上溯 `parent` 拼起来会得到 `/2026/2026/10`，别拼。
    static func folderName(folderID: Int, manager: SessionManager) async -> String? {
        guard folderID > 0 else { return nil }
        let raw = try? await manager.call(
            kind: .file, api: "\(team).Browse.Folder", version: 2, method: "get",
            params: ["id": String(folderID)])
        guard let root = raw as? [String: Any] else { return nil }
        let folder = (root["folder"] as? [String: Any]) ?? root
        return text(folder["name"])
    }

    // MARK: - 图

    /// 缩略图。`id` 那一位传的是 **unit_id**（条目 id 会 404）。
    static func thumbnail(unitID: Int, cacheKey: String, size: ThumbSize,
                          manager: SessionManager) async throws -> Data {
        try await manager.data(
            kind: .file, api: "\(team).Thumbnail", version: 2, method: "get",
            params: [
                "id": String(unitID),
                "cache_key": cacheKey,
                "type": "unit",
                "size": size.rawValue,
            ]
        )
    }

    static func thumbnail(_ item: Item, size: ThumbSize,
                          manager: SessionManager) async throws -> Data {
        try await thumbnail(unitID: item.unitID, cacheKey: item.cacheKey,
                            size: size, manager: manager)
    }

    /// 原图 / 原视频的字节。`unit_id` 必须是**方括号串**（裸数字回 117，2026-10-20
    /// 复核），`cache_key` 从条目的 `additional.thumbnail` 拿。
    static func originalData(_ item: Item, manager: SessionManager) async throws -> Data {
        try await manager.data(
            kind: .file, api: "\(team).Download", version: 2, method: "download",
            params: ["unit_id": "[\(item.unitID)]", "cache_key": item.cacheKey]
        )
    }

    // MARK: - 视频流（2026-10-20 实测，`photosprobe14.py` / `photosprobe15.py`）

    /// 视频的取流地址。**只给 `StreamLoader` 用**：AVPlayer 加不了 `X-SYNO-TOKEN`，
    /// 直连还要放行自签证书，所以字节由装载器自己拉，这里只负责拼地址。
    ///
    /// 🔴 路径必须是 `/webapi/entry.cgi`（`endpoint.baseURL` 就是这个前缀）——
    /// `/photo/webapi/` 对照片族一律回 403。参数 `id` 是**条目 id**（不是 unit_id，
    /// 给了也认，但 `unit_id` 那一路是 103），`quality` 必填，认 high / medium / low。
    /// 服务端按 Range 裁（206 + `Content-Range`），`.MOV` 也标 `video/mp4`。
    static func streamingURL(itemID: Int, endpoint: StreamEndpoint,
                             quality: String = "high") -> URL? {
        var comps = URLComponents(url: endpoint.baseURL.appendingPathComponent("entry.cgi"),
                                  resolvingAgainstBaseURL: false)
        comps?.percentEncodedQuery = SynologyClient.formEncode([
            "api": "\(team).Streaming",
            "version": "2",
            "method": "streaming",
            "id": String(itemID),
            "quality": quality,
            "_sid": endpoint.credentials.sid,
        ])
        return comps?.url
    }

    // MARK: - 写操作（2026-10-20 实测，`photosprobe12.py`）

    /// 删除一条。
    ///
    /// 🔴 **`id` 要方括号串**（`"[15727]"`），裸数字回 `{"success":true}` 却什么也不删
    /// —— 2026-10-20 真机探测（`DM_UI=photodelprobe`，四种写法逐一回读列表 + 文件系统）：
    /// 裸数字 `仍在库=是 · 文件在盘=是`，方括号 `仍在库=否 · 文件在盘=否`。与 `Download`
    /// 的 `unit_id=[…]` 是同一套方括号约定，此前照单值写所以「删了又回来」。
    /// 一次一条（`ids` 回 `120 id required`），批量逐条调；对不存在的 id 也回 `success`，
    /// **成败只能靠回读**。
    static func deleteItem(id: Int, manager: SessionManager) async throws {
        _ = try await manager.call(
            kind: .file, api: "\(team).Browse.Item", version: 7, method: "delete",
            params: ["id": "[\(id)]"])
    }

    /// 新建相册。**`Album` 族没有 `create`** —— 它在 `Browse.NormalAlbum` 上
    /// （`Album` 只管列 `list` / `get` / `set_name` / `delete`）。
    ///
    /// 回的是整个相册对象（含 `id`），不必再列一次。
    static func createAlbum(name: String, manager: SessionManager) async throws -> Album {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PhotosError.emptyName }
        let raw = try await manager.call(
            kind: .file, api: normalAlbumAPI, version: 4, method: "create",
            params: ["name": trimmed, "team_space": "true"])
        guard let root = raw as? [String: Any],
              let json = root["album"] as? [String: Any],
              let album = Album(json: json) else {
            throw PhotosError.badShape("create album")
        }
        return album
    }

    /// 往相册里加条目。`item` 是方括号串；失败的 id 从 `error_list` 里回。
    ///
    /// 重复加同一张不会去重报错 —— 服务端就当它已经在里面（回空 `error_list`）。
    @discardableResult
    static func addItems(_ ids: [Int], toAlbum albumID: Int,
                         manager: SessionManager) async throws -> [Int] {
        guard !ids.isEmpty else { return [] }
        let raw = try await manager.call(
            kind: .file, api: normalAlbumAPI, version: 4, method: "add_item",
            params: ["id": String(albumID),
                     "item": Self.bracket(ids), "team_space": "true"])
        return failureIDs(raw)
    }

    /// 从相册移出：**只移容器、不删图**（`delete_item` 的语义就是移出相册）。
    @discardableResult
    static func removeItems(_ ids: [Int], fromAlbum albumID: Int,
                            manager: SessionManager) async throws -> [Int] {
        guard !ids.isEmpty else { return [] }
        let raw = try await manager.call(
            kind: .file, api: normalAlbumAPI, version: 4, method: "delete_item",
            params: ["id": String(albumID),
                     "item": Self.bracket(ids), "team_space": "true"])
        return failureIDs(raw)
    }

    /// 相册改名。写回 `ok {}` 不代表生效的接口不止一个，调用方回读确认。
    static func setAlbumName(_ albumID: Int, name: String,
                             manager: SessionManager) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PhotosError.emptyName }
        _ = try await manager.call(
            kind: .file, api: albumAPI, version: 5, method: "set_name",
            params: ["id": String(albumID), "name": trimmed, "team_space": "true"])
    }

    /// 删相册（**只删容器，照片留在库里**）。
    ///
    /// 🔴 在 `SYNO.Foto.Browse.Album` v5 上，**不在 `NormalAlbum`** 上
    /// （那一族 v1–4 没有 `delete`，全 103）—— 批 3 记的「恒回 ok 却删不掉」
    /// 是在不存在的 `SYNO.FotoTeam.Browse.Album` 上打的，2026-10-20 下午更正。
    /// `id` 认 `"2"` / `"[2]"` / `2` 三种形态。照样回读确认。
    static func deleteAlbum(_ albumID: Int, manager: SessionManager) async throws {
        _ = try await manager.call(
            kind: .file, api: albumAPI, version: 5, method: "delete",
            params: ["id": String(albumID), "team_space": "true"])
    }

    /// 方括号串：`[1,2]`。`item` / `unit_id` 这一族只认这个形态。
    static func bracket(_ ids: [Int]) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }

    /// 写接口回的 `error_list`：非空说明有 id 没落地。`[{"id": 3, "error": 4}]`。
    private static func failureIDs(_ raw: Any) -> [Int] {
        guard let root = raw as? [String: Any],
              let list = root["error_list"] as? [[String: Any]] else { return [] }
        return list.compactMap { intValue($0["id"]) }
    }
}

// MARK: - 解析

private extension PhotosAPI.Item {
    init?(json: [String: Any]) {
        guard let id = PhotosAPI.intValue(json["id"]),
              let name = json["filename"] as? String,
              let stamp = PhotosAPI.intValue(json["time"]) else { return nil }
        let additional = (json["additional"] as? [String: Any]) ?? [:]
        let thumb = (additional["thumbnail"] as? [String: Any]) ?? [:]
        let resolution = (additional["resolution"] as? [String: Any]) ?? [:]
        let exif = (additional["exif"] as? [String: Any]) ?? [:]
        // `indexed_time` 是毫秒，`time` 是秒 —— 同一个字段名族里量纲不同。
        let indexed = PhotosAPI.intValue(json["indexed_time"]).map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }

        self.init(
            id: id,
            filename: name,
            filesize: PhotosAPI.intValue(json["filesize"]) ?? 0,
            time: Date(timeIntervalSince1970: TimeInterval(stamp)),
            indexedTime: indexed ?? Date(timeIntervalSince1970: TimeInterval(stamp)),
            folderID: PhotosAPI.intValue(json["folder_id"]) ?? 0,
            type: (json["type"] as? String) ?? "photo",
            unitID: PhotosAPI.intValue(thumb["unit_id"]) ?? 0,
            cacheKey: (thumb["cache_key"] as? String) ?? "",
            width: PhotosAPI.intValue(resolution["width"]) ?? 0,
            height: PhotosAPI.intValue(resolution["height"]) ?? 0,
            exif: PhotosAPI.Item.Exif(
                camera: PhotosAPI.text(exif["camera"]),
                lens: PhotosAPI.text(exif["lens"]),
                aperture: PhotosAPI.text(exif["aperture"]),
                exposure: PhotosAPI.text(exif["exposure_time"]),
                iso: PhotosAPI.text(exif["iso"]),
                focal: PhotosAPI.text(exif["focal_length"])
            ),
            rating: PhotosAPI.intValue(additional["rating"]) ?? 0,
            note: PhotosAPI.text(additional["description"])
        )
    }
}

private extension PhotosAPI.Person {
    init?(json: [String: Any]) {
        guard let id = PhotosAPI.intValue(json["id"]) else { return nil }
        let additional = (json["additional"] as? [String: Any]) ?? [:]
        let thumb = (additional["thumbnail"] as? [String: Any]) ?? [:]
        let key = (thumb["cache_key"] as? String) ?? ""
        self.init(
            id: id,
            name: (json["name"] as? String) ?? "",
            itemCount: PhotosAPI.intValue(json["item_count"]) ?? 0,
            coverKey: key,
            // `cache_key` 形如 `41_1749783901`，前缀就是 unit_id。
            coverUnitID: Int(key.split(separator: "_").first ?? "") ?? 0
        )
    }
}

private extension PhotosAPI.Place {
    init?(json: [String: Any]) {
        guard let id = PhotosAPI.intValue(json["id"]) else { return nil }
        self.init(
            id: id,
            name: (json["name"] as? String) ?? "",
            country: (json["country"] as? String) ?? "",
            itemCount: PhotosAPI.intValue(json["item_count"]) ?? 0
        )
    }
}

private extension PhotosAPI.Tag {
    init?(json: [String: Any]) {
        guard let id = PhotosAPI.intValue(json["id"]) else { return nil }
        self.init(
            id: id,
            name: (json["name"] as? String) ?? "",
            itemCount: PhotosAPI.intValue(json["item_count"]) ?? 0
        )
    }
}

private extension PhotosAPI.Album {
    init?(json: [String: Any]) {
        guard let id = PhotosAPI.intValue(json["id"]) else { return nil }
        self.init(
            id: id,
            name: (json["name"] as? String) ?? "",
            itemCount: PhotosAPI.intValue(json["item_count"]) ?? 0
        )
    }
}

extension PhotosAPI {
    /// JSON 里的数字可能是 `Int` 也可能是 `Double`（同一条应答里两种都见过）。
    static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? String { return Int(value) }
        return nil
    }

    /// 空串等同于没有：服务端对没有值的字段也回 `""`。
    static func text(_ any: Any?) -> String? {
        guard let value = any as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

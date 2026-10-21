import Foundation
import Observation

/// 照片页的浏览维度：时间轴之外的几屏，以及它们的列表数据。
///
/// 为什么与 `PhotoLibrary` 分开：时间轴那一份是**全库一万条**的常驻缓存（查看器
/// 的翻页序列、缩略图缓存都挂在它上面），而分类屏各自只有几十到一两千条、切一次
/// 就该换一份。两件事一个模型里会互相踩 —— 换一次维度把全库清掉，回到时间轴又
/// 得重拉十一页。
///
/// 条目过滤的参数名逐个实测过（2026-10-20，`photosprobe10/11.py`）：人物
/// `person_id`、地点 `geocoding_id`、相册 `album_id` 都真生效；标签是
/// **`general_tag_id`**（`tag_id` 被静默忽略）。见 `PhotosAPI.Filter`。
@MainActor
@Observable
final class PhotoShelf {
    /// 一屏。详情页（person / place / tag / album）带 id，返回走页头的 chevron。
    enum Route: Hashable {
        case timeline
        case recent
        case people
        case person(Int)
        case places
        case place(Int)
        case tags
        case tag(Int)
        case albums
        case album(Int)

        var title: String {
            switch self {
            case .timeline: return "时间轴"
            case .recent: return "最近添加"
            case .people, .person: return "人物"
            case .places, .place: return "地点"
            case .tags, .tag: return "标签"
            case .albums, .album: return "相册"
            }
        }

        /// 详情页的返回目标（列表页）。一级屏为 `nil`。
        var parent: Route? {
            switch self {
            case .person: return .people
            case .place: return .places
            case .tag: return .tags
            case .album: return .albums
            default: return nil
            }
        }

        var isDetail: Bool { parent != nil }

        /// 这一屏是不是网格（相对「卡片 / 列表」屏）。
        var isGrid: Bool {
            switch self {
            case .people, .places, .tags, .albums: return false
            default: return true
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var route: Route = .timeline
    /// 当前网格的条目（时间轴那一屏不用它）。
    private(set) var phase: Phase = .ready
    private(set) var items: [PhotosAPI.Item] = []
    /// 网格按哪个时间字段分组：最近添加按**进库日**，其余按拍摄日。
    private(set) var groupsByIndexed = false

    private(set) var people: [PhotosAPI.Person] = []
    private(set) var places: [PhotosAPI.Place] = []
    private(set) var tags: [PhotosAPI.Tag] = []
    private(set) var albums: [PhotosAPI.Album] = []
    private(set) var listsPhase: Phase = .idle
    /// 服务端没开的能力（接口回错）。**整条不渲染** —— 不做灰掉的假入口。
    private(set) var unavailable: Set<String> = []

    /// 「最近添加」的条目与相册封面：进列表页时顺手取，计数与封面都要用。
    private(set) var recentItems: [PhotosAPI.Item] = []
    private(set) var albumCovers: [Int: PhotosAPI.Item] = [:]

    /// 搜索是**提交式**：回车才筛一次。空词＝退出搜索。
    ///
    /// 筛在本地做：条目全量已经在 `PhotoLibrary.loadedItems` 里（全库一万条上下），
    /// 按文件名子串匹配，一条请求都不用发。
    /// 🔴 不走服务端 `Search.Search` v7 是因为**纯数字关键词回 `code=120`** ——
    /// 而「2026」「1018」正是搜文件名时最常输的东西（2026-10-20 真机复现）。本地筛
    /// 没有这个毛病，顺带还省掉 4000 条的截断和服务端二十多次翻页。
    private(set) var keyword = ""
    private(set) var searchItems: [PhotosAPI.Item] = []
    private(set) var searchPhase: Phase = .idle
    var isSearching: Bool { !keyword.isEmpty }

    /// 详情页当前实体（页头的名字 / 张数 / 头像都从这里取）。
    private(set) var person: PhotosAPI.Person?
    private(set) var place: PhotosAPI.Place?
    private(set) var tag: PhotosAPI.Tag?
    private(set) var album: PhotosAPI.Album?

    private static let pageSize = 1000

    // MARK: - 列表数据（同时也喂侧栏计数）

    func bootstrap(_ manager: SessionManager?) async {
        guard let manager, listsPhase != .loading else { return }
        if listsPhase == .ready { return }
        listsPhase = .loading
        do {
            recentItems = try await recentlyAdded(manager)
        } catch {
            // 「最近添加」取不到不致命：侧栏那一行照样在，进去是空态。
            NSLog("[photos] 最近添加失败：%@", Self.describe(error))
        }
        do {
            people = try await PhotosAPI.persons(manager: manager)
        } catch {
            unavailable.insert("people")
            NSLog("[photos] 人物列表失败：%@", Self.describe(error))
        }
        do {
            places = try await PhotosAPI.places(manager: manager)
        } catch {
            unavailable.insert("places")
            NSLog("[photos] 地点列表失败：%@", Self.describe(error))
        }
        do {
            tags = try await PhotosAPI.tags(manager: manager)
        } catch {
            unavailable.insert("tags")
            NSLog("[photos] 标签列表失败：%@", Self.describe(error))
        }
        do {
            albums = try await PhotosAPI.albums(manager: manager)
        } catch {
            unavailable.insert("albums")
            NSLog("[photos] 相册列表失败：%@", Self.describe(error))
        }
        listsPhase = .ready
        NSLog("[photos] 侧栏：最近 %d · 人物 %d（未确认 %d）· 地点 %d · 标签 %d · 相册 %d",
              recentItems.count, people.count, people.filter { !$0.isNamed }.count,
              places.count, tags.count, albums.count)
    }

    private func recentlyAdded(_ manager: SessionManager) async throws -> [PhotosAPI.Item] {
        var out: [PhotosAPI.Item] = []
        var offset = 0
        while true {
            let page = try await PhotosAPI.recentlyAddedPage(
                offset: offset, limit: 200, manager: manager)
            out.append(contentsOf: page)
            offset += page.count
            if page.count < 200 { break }
        }
        return out
    }

    // MARK: - 切屏

    func select(_ target: Route, manager: SessionManager?) async {
        // 点侧栏等于退出搜索：搜索框里的词还留着会让人以为筛的是这一屏。
        if !keyword.isEmpty { clearSearch() }
        route = target
        person = nil
        place = nil
        tag = nil
        album = nil
        items = []
        groupsByIndexed = false

        switch target {
        case .timeline:
            phase = .ready
        case .recent:
            groupsByIndexed = true
            if recentItems.isEmpty {
                await loadRecent(manager)
            } else {
                items = recentItems
                phase = .ready
            }
        case .people, .places, .tags, .albums:
            phase = .ready
            if target == .albums { await loadAlbumCovers(manager) }
        case .person(let id):
            person = people.first { $0.id == id }
            await load(filter: .person(id), manager)
        case .place(let id):
            place = places.first { $0.id == id }
            await load(filter: .place(id), manager)
        case .tag(let id):
            tag = tags.first { $0.id == id }
            await load(filter: .tag(id), manager)
        case .album(let id):
            album = albums.first { $0.id == id }
            await load(filter: .album(id), manager)
        }
    }

    /// 重新取当前这一屏（详情页的重试按钮与相册封面）。
    func reload(_ manager: SessionManager?) async {
        switch route {
        case .timeline:
            return
        case .recent:
            await loadRecent(manager, force: true)
        case .people, .places, .tags, .albums:
            listsPhase = .idle
            await bootstrap(manager)
            if route == .albums { await loadAlbumCovers(manager) }
        case .person(let id):
            await load(filter: .person(id), manager)
        case .place(let id):
            await load(filter: .place(id), manager)
        case .tag(let id):
            await load(filter: .tag(id), manager)
        case .album(let id):
            await load(filter: .album(id), manager)
        }
    }

    private func loadRecent(_ manager: SessionManager?, force: Bool = false) async {
        guard let manager else { return }
        if !force, !recentItems.isEmpty { return }
        phase = .loading
        do {
            recentItems = try await recentlyAdded(manager)
            items = recentItems
            phase = .ready
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    private func load(filter: PhotosAPI.Filter, _ manager: SessionManager?) async {
        guard let manager else { return }
        phase = .loading
        do {
            items = try await PhotosAPI.allItems(filter: filter, pageSize: Self.pageSize,
                                                 manager: manager)
            phase = .ready
            NSLog("[photos] 过滤 %@ → %d 条", String(describing: filter), items.count)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// 相册封面：相册列表不带封面，取每个相册的第一张条目，走条目缩略图。
    /// 相册个数是个位数，一次一页就够。
    func loadAlbumCovers(_ manager: SessionManager?) async {
        guard let manager else { return }
        for album in albums where albumCovers[album.id] == nil && album.itemCount > 0 {
            if let first = try? await PhotosAPI.itemsPage(
                offset: 0, limit: 1, filter: .album(album.id), manager: manager).first {
                albumCovers[album.id] = first
            }
        }
    }

    // MARK: - 搜索

    /// 提交一次搜索。`library` 是时间轴里那份全库条目 —— 就地筛，不发请求。
    /// 只有一条路会退回服务端：全库还没读进来（首屏没加载完就搜）。那会儿本地
    /// 没有可筛的数据，问一下服务端比给「没有找到」诚实。
    func submitSearch(_ text: String, in library: [PhotosAPI.Item],
                      manager: SessionManager?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSearch()
            return
        }
        keyword = trimmed
        guard !library.isEmpty else {
            await searchOnServer(trimmed, manager: manager)
            return
        }
        let needle = trimmed.lowercased()
        let hits = library.filter { $0.filename.lowercased().contains(needle) }
        searchItems = hits
        searchPhase = .ready
        NSLog("[photos] 搜索「%@」→ %d 条（本地筛，全库 %d 条）",
              trimmed, hits.count, library.count)
    }

    /// 服务端搜索（只在本地没有数据时用）。
    ///
    /// 🔴 `Search.Search` v7 对**纯数字关键词**回 `code=120`（「2026」这种），
    /// 所以它当不了主路；留着只是因为首屏还没读完时得有个来源。
    private func searchOnServer(_ trimmed: String, manager: SessionManager?) async {
        guard let manager else { return }
        searchPhase = .loading
        var offset = 0
        do {
            var out: [PhotosAPI.Item] = []
            while out.count < 4000 {
                let page = try await PhotosAPI.searchPage(
                    keyword: trimmed, offset: offset, limit: 200, manager: manager)
                out.append(contentsOf: page)
                offset += page.count
                if page.count < 200 { break }
            }
            searchItems = out
            searchPhase = .ready
            NSLog("[photos] 搜索「%@」→ %d 条（服务端）", trimmed, out.count)
        } catch {
            searchItems = []
            searchPhase = .failed(Self.describe(error))
            // 界面上只给一句人话，接口层回的原话得留在日志里 —— 报错码是排查的唯一线索。
            NSLog("[photos] 搜索「%@」失败（offset=%d）：%@", trimmed, offset,
                  String(describing: error))
        }
    }

    func clearSearch() {
        keyword = ""
        searchItems = []
        searchPhase = .idle
    }

    // MARK: - 写操作之后

    /// 本地剔除（删掉的条目从当前屏、最近添加、搜索结果里一并拿掉）。
    func forget(ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        items = items.filter { !ids.contains($0.id) }
        recentItems = recentItems.filter { !ids.contains($0.id) }
        searchItems = searchItems.filter { !ids.contains($0.id) }
        if let current = album {
            let removed = items.count == 0 ? 0 : min(current.itemCount, ids.count)
            album = PhotosAPI.Album(id: current.id, name: current.name,
                                    itemCount: max(0, current.itemCount - removed))
        }
    }

    /// 从人物里移除照片后的就地校正：人物详情这一屏把该条摘掉、计数减一。
    /// 序列摘除走 `PhotoLibrary.forgetInViewSequence`（不归这管）。
    func notePersonItemRemoved(_ itemID: Int, personID: Int) {
        guard person?.id == personID,
              items.contains(where: { $0.id == itemID }) else { return }
        items.removeAll { $0.id == itemID }
        if let current = person {
            person = PhotosAPI.Person(id: current.id, name: current.name,
                                      itemCount: max(0, current.itemCount - 1),
                                      coverKey: current.coverKey,
                                      coverUnitID: current.coverUnitID)
        }
    }

    /// 相册里加减了照片之后校正计数：相册详情页与相册卡都拿 `item_count` 报数，
    /// 不重拉整份列表也得让数字对得上。
    func noteAlbumCount(_ albumID: Int, delta: Int) {
        guard delta != 0 else { return }
        if let current = album, current.id == albumID {
            album = PhotosAPI.Album(id: current.id, name: current.name,
                                    itemCount: max(0, current.itemCount + delta))
        }
        albums = albums.map { entry in
            guard entry.id == albumID else { return entry }
            return PhotosAPI.Album(id: entry.id, name: entry.name,
                                   itemCount: max(0, entry.itemCount + delta))
        }
    }

    /// 人物命名 / 改名之后校正本地清单与详情页头（不重拉整份人物列表）。
    /// 服务端 trim 空白，这里存 trim 后的值保持一致。
    func notePersonRenamed(id: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        people = people.map { entry in
            guard entry.id == id else { return entry }
            return PhotosAPI.Person(id: entry.id, name: trimmed,
                                    itemCount: entry.itemCount,
                                    coverKey: entry.coverKey,
                                    coverUnitID: entry.coverUnitID)
        }
        if let current = person, current.id == id {
            person = people.first { $0.id == id }
        }
    }

    /// 人物归并落库之后校正：source 从清单摘掉、张数并给 target。
    /// 正在看的 source 详情由 `AppState` 负责退回列表。
    func notePersonMerged(source: Int, target: Int) {
        let moved = people.first { $0.id == source }?.itemCount ?? 0
        people.removeAll { $0.id == source }
        people = people.map { entry in
            guard entry.id == target else { return entry }
            return PhotosAPI.Person(id: entry.id, name: entry.name,
                                    itemCount: entry.itemCount + moved,
                                    coverKey: entry.coverKey,
                                    coverUnitID: entry.coverUnitID)
        }
        if let current = person, current.id == source { person = nil }
        if let current = person, current.id == target {
            person = people.first { $0.id == target }
        }
    }

    // MARK: - 分组

    /// 网格的分组。最近添加按**进库日**（`indexed_time`），其余按拍摄日 ——
    /// 「最近添加」不是「最近拍的」，一条 10-03 拍的 10-13 才拷进来，就该排在
    /// 10-11 拍的前面。
    func groups(for items: [PhotosAPI.Item]) -> [(day: PhotosAPI.Day, items: [PhotosAPI.Item])] {
        let calendar = PhotoDate.utcCalendar
        var buckets: [String: [PhotosAPI.Item]] = [:]
        var order: [PhotosAPI.Day] = []
        for item in items {
            let stamp = groupsByIndexed ? item.indexedTime : item.time
            let c = calendar.dateComponents([.year, .month, .day], from: stamp)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let day = PhotosAPI.Day(year: y, month: m, day: d)
            if buckets[day.id] == nil {
                order.append(day)
                buckets[day.id] = []
            }
            buckets[day.id]!.append(item)
        }
        return order.map { ($0, buckets[$0.id] ?? []) }
    }

    /// 副标题里的张数统计。相册 / 人物 / 地点 / 标签用实体自己的 `item_count`，
    /// 不等条目拉完才敢报数。
    func headlineCount() -> Int {
        switch route {
        case .timeline: return 0
        case .recent: return recentItems.count
        case .people: return people.count
        case .person: return person?.itemCount ?? items.count
        case .places: return places.count
        case .place: return place?.itemCount ?? items.count
        case .tags: return tags.count
        case .tag: return tag?.itemCount ?? items.count
        case .albums: return albums.count
        case .album: return album?.itemCount ?? items.count
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription {
            return text
        }
        return error.localizedDescription
    }
}

import SwiftUI

// MARK: - 状态

/// 曲库页的状态：数据源、维度、筛选、搜索、分页。
///
/// 三组控件的分工（原型「听歌 · 曲库」那一屏）：
/// · **内容区侧栏**定「这一屏看的是哪一份曲目」—— 全部曲目 / 每日随机 /
///   我的歌单 / 评分 ≥ 4 星，四者都落成同一张表，只是数据源不同；
/// · **分段控件**定「在曲库快照里按哪个维度浏览」—— 全部曲目 / 艺术家 / 专辑 / 流派；
/// · **搜索框**与**行内链接**（点艺术家名、专辑名）压过上面两者。
///
/// 后两者只在数据源是「全部曲目」时说得通：一份 100 首的随机单里没有「艺术家列表」
/// 可言。所以点维度或落筛选时，数据源自动回到全部曲目 —— 控件不做隐藏/禁用，
/// 而是点一下就顺过来，省得用户先去侧栏把来源改回去。
@MainActor
@Observable
final class LibraryModel {

    enum Dimension: String, CaseIterable, Hashable {
        case all
        case artist
        case album
        case genre

        var title: String {
            switch self {
            // 分段这一格说的是「按什么粒度看」，不是「看哪一份曲目」—— 后者是
            // 左侧栏那行「全部曲目」的活。同名两处在同一屏同时高亮，用户要在
            // 两个同名之间来回确认是不是一个东西（2026-10-18 用户指出、拍板改）。
            case .all: return "歌曲"
            case .artist: return "艺术家"
            case .album: return "专辑"
            case .genre: return "流派"
            }
        }

        /// 在这一维里选中一个实体，落成哪个字段的筛选。
        var filterField: SongField {
            switch self {
            case .all: return .title
            case .artist: return .artist
            case .album: return .album
            case .genre: return .genre
            }
        }
    }

    /// 内容区侧栏的数据源。
    enum Source: Hashable {
        case all
        case dailyRandom
        case topRated
        case playlist(AudioPlaylist)

        var title: String {
            switch self {
            case .all: return "全部曲目"
            case .dailyRandom: return "每日随机"
            case .topRated: return "评分 ≥ 4 星"
            case .playlist(let playlist): return playlist.name
            }
        }
    }

    /// 每日随机取多少首（原型侧栏上写的就是 100）。
    static let randomCount = 100
    /// 「评分 ≥ 4 星」的门槛。
    static let chartRating = 4

    var dimension: Dimension = .all
    var searchText = ""
    private(set) var source: Source = .all
    private(set) var searchKeyword = ""

    /// 表头排序。`nil` = 服务端默认顺序（曲库写入的先后）—— 表头一个箭头都不亮。
    /// 跨来源保留：在曲库按年份排过，切到歌单还是按年份看，这才合用。
    private(set) var sort: SongSort?
    /// 显示的列，**有序** —— 数组顺序就是列的先后，表头拖动改的就是它。
    /// 恒含 `.title`：主键列不可隐藏，且钉在首位（它是唯一自适应宽的一列，
    /// 挪到中间会让「吸收余量」的行为落在中间，后面的固定列位置随窗口宽漂）。
    private(set) var visibleColumns: [TrackField] = TrackField.allCases
    /// 表头各格在**窗口坐标**里的位置。落点判定不用它（表头自己那份 `@State` 更近），
    /// 它是给冒烟通路定位用的：AI 点不了 UI，只能合成鼠标事件，「点哪一格」得先数出来。
    /// 加 `@ObservationIgnored`：它是量出来的读数，不是状态，写它不该触发重绘
    /// （否则每次布局都重绘表头，还可能自己把自己转起来）。
    @ObservationIgnored var headerFrames: [TrackField: CGRect] = [:]
    /// 字段配置菜单开合。挂模型上而不是表视图的 `@State`：这一页会随沉浸模式
    /// 上下层级，状态跟着视图走就丢；真机核对也要能从入口把它展开（见 `DM_LIBRARY`）。
    var showsFieldMenu = false

    private(set) var songs: [AudioSong] = []
    private(set) var total = 0
    private(set) var artists: [AudioArtist] = []
    private(set) var albums: [AudioAlbum] = []
    private(set) var genres: [String] = []
    private(set) var playlists: [AudioPlaylist] = []
    private(set) var filter: SongFilter?
    private(set) var selectedSongID: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    /// 请求代号。连点维度、连打字时先发的请求可能后回 —— 只让最后一次的结果落地。
    private var generation = 0

    private enum Mode: Equatable {
        case allSongs
        case filtered(SongFilter)
        case searched(String)
        case artistList
        case albumList
        case genreList
        case random
        case topRated
        case playlist(String)
    }

    private var mode: Mode {
        if !searchKeyword.isEmpty { return .searched(searchKeyword) }
        if let filter { return .filtered(filter) }
        switch source {
        case .dailyRandom: return .random
        case .topRated: return .topRated
        case .playlist(let playlist): return .playlist(playlist.id)
        case .all: break
        }
        switch dimension {
        case .all: return .allSongs
        case .artist: return .artistList
        case .album: return .albumList
        case .genre: return .genreList
        }
    }

    // MARK: 页头

    var headTitle: String {
        switch mode {
        case .allSongs: return "全部曲目"
        case .filtered(let filter): return filter.value
        case .searched(let keyword): return "搜索「\(keyword)」"
        case .artistList: return "艺术家"
        case .albumList: return "专辑"
        case .genreList: return "流派"
        case .random: return "每日随机"
        case .topRated: return "评分 ≥ \(Self.chartRating) 星"
        case .playlist(let id): return playlists.first { $0.id == id }?.name ?? "歌单"
        }
    }

    /// 只报当前这一屏的数。四个维度各拉一次全量只为凑一行副标题，
    /// 是十几次请求换一句话。
    var headSubtitle: String {
        switch mode {
        case .allSongs: return "\(total) 首"
        case .filtered(let filter): return "\(filter.field.label) · 从曲库筛出 \(total) 首"
        case .searched: return "命中 \(total) 首"
        case .artistList: return "\(artists.count) 位"
        case .albumList: return "\(albums.count) 张"
        case .genreList: return "\(genres.count) 个"
        case .random: return "\(songs.count) 首 · 每次进来重新抽"
        case .topRated: return "\(songs.count) 首 · 按评分降序"
        case .playlist: return "\(songs.count) 首"
        }
    }

    var isFilterActive: Bool { filter != nil }

    /// 侧栏行上的计数：只有拿得到的才写（歌单曲目数要逐个 `getinfo`，
    /// 侧栏不为此发 N 个请求 —— 点进去看页头）。
    func count(for source: Source) -> Int? {
        switch source {
        case .all: return total > 0 ? total : nil
        case .dailyRandom: return Self.randomCount
        case .topRated: return isTopRatedLoaded ? songs.count : nil
        case .playlist: return nil
        }
    }

    /// 高分曲是当前屏的唯一来源，切走了就不知道数了 —— 只在自己这一屏报。
    private var isTopRatedLoaded: Bool {
        if case .topRated = mode { return true }
        return false
    }

    var showsTrackTable: Bool {
        switch mode {
        case .artistList, .albumList, .genreList: return false
        default: return true
        }
    }

    /// 只有两路能翻页：曲库快照与它的字段筛选。搜索每路只取前 `limit` 条、
    /// 每日随机与高分曲是一次要齐、歌单按 `getinfo` 一把回 —— 都不该出现「还有更多」。
    var hasMore: Bool {
        switch mode {
        case .allSongs, .filtered: return songs.count < total
        default: return false
        }
    }

    var isEmptyContent: Bool {
        songs.isEmpty && artists.isEmpty && albums.isEmpty && genres.isEmpty
    }

    // MARK: 取数

    func loadIfNeeded(_ manager: SessionManager?) async {
        guard !hasLoaded else { return }
        await loadPlaylists(manager)
        await refresh(manager)
    }

    /// 侧栏的「我的歌单」只有切进听歌页才拉一次，之后常驻。
    func loadPlaylists(_ manager: SessionManager?) async {
        guard let manager else { return }
        do {
            playlists = try await AudioLibrary.playlists(manager)
        } catch {
            // 歌单拉不到不该让整页报错 —— 侧栏少一组行，曲库照看。
            playlists = []
        }
    }

    /// 当前是不是正在看这个歌单（加歌成功后决定要不要重拉那一屏）。
    func isShowing(_ playlist: AudioPlaylist) -> Bool {
        source == .playlist(playlist)
    }

    func refresh(_ manager: SessionManager?) async {
        guard let manager else { return }
        generation += 1
        let token = generation
        isLoading = true
        errorMessage = nil

        do {
            switch mode {
            case .allSongs:
                let page = try await AudioLibrary.songs(manager, sort: sort)
                guard token == generation else { return }
                setSongs(page)
            case .filtered(let filter):
                let page = try await AudioLibrary.songs(manager, matching: filter, sort: sort)
                guard token == generation else { return }
                setSongs(page)
            case .searched(let keyword):
                let page = try await AudioLibrary.search(manager, keyword: keyword)
                guard token == generation else { return }
                setSongs(page, localSort: true)
            case .random:
                let page = try await AudioLibrary.randomSongs(manager, limit: Self.randomCount)
                guard token == generation else { return }
                setSongs(page, localSort: true)
            case .topRated:
                let page = try await AudioLibrary.topRatedSongs(manager, minRating: Self.chartRating)
                guard token == generation else { return }
                setSongs(page, localSort: true)
            case .playlist(let id):
                let page = try await AudioLibrary.songs(manager, playlistID: id)
                guard token == generation else { return }
                setSongs(page, localSort: true)
            case .artistList:
                let list = try await AudioLibrary.artists(manager)
                guard token == generation else { return }
                clearContent()
                artists = list
            case .albumList:
                let list = try await AudioLibrary.albums(manager)
                guard token == generation else { return }
                clearContent()
                albums = list
            case .genreList:
                let list = try await AudioLibrary.genres(manager)
                guard token == generation else { return }
                clearContent()
                genres = list
            }
            if token == generation { hasLoaded = true }
        } catch {
            guard token == generation else { return }
            errorMessage = error.localizedDescription
        }
        if token == generation { isLoading = false }
    }

    /// 滚到底再要下一页（列表行分页懒加载）。其余的来源都不分页，见 `hasMore`。
    func loadMore(_ manager: SessionManager?) async {
        guard let manager, !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let token = generation
        do {
            let page: AudioSongPage
            if case .filtered(let filter) = mode {
                page = try await AudioLibrary.songs(manager, matching: filter, offset: songs.count, sort: sort)
            } else {
                page = try await AudioLibrary.songs(manager, offset: songs.count, sort: sort)
            }
            guard token == generation else { return }
            songs.append(contentsOf: page.songs)
            total = page.total
        } catch {
            guard token == generation else { return }
            errorMessage = error.localizedDescription
        }
        if token == generation { isLoadingMore = false }
    }

    // MARK: 动作

    /// 侧栏切换数据源。拿一份「每日随机」「某个歌单」时维度没有意义，
    /// 顺手回到全部曲目 —— 免得下次点维度时带着一个说不通的维。
    func select(source: Source, on manager: SessionManager?) async {
        self.source = source
        dimension = .all
        resetScope()
        clearContent()
        await refresh(manager)
    }

    func select(_ dimension: Dimension, on manager: SessionManager?) async {
        // 点维度 = 回曲库快照：随机单 / 歌单里没有「艺术家列表」这一层。
        source = .all
        self.dimension = dimension
        resetScope()
        clearContent()
        await refresh(manager)
    }

    /// 点艺术家 / 专辑名 / 流派 —— 回到同一张表并代入筛选（原型「曲库 · 已筛选」屏）。
    func apply(_ value: String, on manager: SessionManager?) async {
        await apply(value, in: dimension, on: manager)
    }

    /// 同上，但筛选字段由调用点指定。沉浸模式的歌手名没有「当前维度」这个上下文
    /// （那一屏里没有分段控件），必须明说是按艺术家筛。
    func apply(_ value: String, in dimension: Dimension, on manager: SessionManager?) async {
        self.dimension = dimension
        source = .all
        filter = SongFilter(field: dimension.filterField, value: value)
        searchKeyword = ""
        searchText = ""
        selectedSongID = nil
        clearContent()
        await refresh(manager)
    }

    func clearFilter(on manager: SessionManager?) async {
        filter = nil
        selectedSongID = nil
        clearContent()
        await refresh(manager)
    }

    func submitSearch(on manager: SessionManager?) async {
        source = .all
        searchKeyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        filter = nil
        selectedSongID = nil
        clearContent()
        await refresh(manager)
    }

    func select(song: AudioSong) {
        selectedSongID = song.id
    }

    /// 评分：写出去、拿回落地值，再改本地这一格 —— 不整页重拉（评一次分重拉
    /// 一千首是白费）。失败原因由 `AppState` 落成 Toast，这里不重复报。
    func rate(_ song: AudioSong, to stars: Int, on state: AppState) async {
        guard let applied = await state.rate(song.id, to: stars) else { return }
        if let index = songs.firstIndex(where: { $0.id == song.id }) {
            songs[index].rating = applied
        }
    }

    /// 标签编辑保存后的行内替换（与评分同一条道理，不整页重拉）。
    /// NAS 索引当场就跟上（实测 0 秒），下次排序 / 搜索拿到的是新值。
    func applyTags(_ info: SongTagInfo, to songID: String) {
        if let index = songs.firstIndex(where: { $0.id == songID }) {
            songs[index] = songs[index].withTags(info)
        }
    }

    // MARK: 表视图偏好（排序与列显隐，持久化）

    private let defaults = UserDefaults.standard

    private enum PrefKey {
        static let sortField = "nas.library.sortField"
        static let sortAscending = "nas.library.sortAscending"
        static let columns = "nas.library.columns"
        static let columnWidths = "nas.library.columnWidths"
    }

    /// 列宽覆盖（拖表头右缘改的），跨重启保留。**全列都收** —— 标题列的
    /// 覆盖是**最小宽**（自适应语义不变，见 `ColumnWidth`），其余列是钉死宽。
    /// 表头与行共用同一份。
    var columnWidths: [TrackField: CGFloat] = [:] {
        didSet { storeColumnWidths() }
    }

    init() {
        sort = Self.storedSort()
        visibleColumns = Self.storedColumns()
        columnWidths = Self.storedColumnWidths()
    }

    /// 拖宽落模型：clamp 到下限，取整（半个像素的列宽没有意义）。
    /// 拖回默认宽就清掉覆盖（标题列默认 `titleMinWidth`）。
    func setColumnWidth(_ width: CGFloat, for field: TrackField) {
        let next = max(TrackMetrics.minColumnWidth, width.rounded())
        let fallback = field.width ?? TrackMetrics.titleMinWidth
        if next == fallback {
            columnWidths[field] = nil   // 拖回默认宽 = 清掉覆盖
        } else {
            columnWidths[field] = next
        }
    }

    /// 一列的实际宽度：覆盖优先，默认值兜底。
    func effectiveWidth(_ field: TrackField) -> CGFloat {
        columnWidths[field] ?? field.fixedWidth
    }

    /// 点表头：同一列切换正序 / 倒序，换一列从正序起（原型「点表头切换正序 / 倒序」）。
    ///
    /// 曲库快照与它的字段筛选是分页的两路，**顺序变了要重新问服务端** —— 只排已经
    /// 加载的这几页，滚到底拿回来的第二页会又按默认顺序接在后面。其余四路
    /// （搜索 / 每日随机 / 高分曲 / 歌单）一次要齐，本地就能排。
    func toggleSort(_ field: TrackField, on manager: SessionManager?) async {
        let next: SongSort
        if let current = sort, current.field == field {
            next = SongSort(field: field, ascending: !current.ascending)
        } else {
            next = SongSort(field: field, ascending: true)
        }
        await applySort(next, on: manager)
    }

    /// 直接落一个排序（表头点按走 `toggleSort`）。回默认顺序传 `nil`。
    func applySort(_ next: SongSort?, on manager: SessionManager?) async {
        sort = next
        if let next {
            defaults.set(next.field.rawValue, forKey: PrefKey.sortField)
            defaults.set(next.ascending, forKey: PrefKey.sortAscending)
        } else {
            defaults.removeObject(forKey: PrefKey.sortField)
            defaults.removeObject(forKey: PrefKey.sortAscending)
        }

        if usesServerOrdering {
            await refresh(manager)
        } else {
            songs = applyLocalSort(songs)
        }
    }

    func isVisible(_ field: TrackField) -> Bool { visibleColumns.contains(field) }

    /// 勾 / 取消一列。标题是主键列 —— `canHide` 为假时直接不理会。
    ///
    /// 重新显示一列时插回**默认顺序里的位置**（插在前一个默认序可见列的后面），
    /// 不是插到末尾：这样「藏了再显示」与「恢复默认字段」的结果一致，
    /// 列序不会被勾选动作搅乱、拖动排好的顺序也不会被一次勾选打散。
    func setVisible(_ field: TrackField, _ visible: Bool) {
        guard field.canHide else { return }
        if visible {
            guard !visibleColumns.contains(field) else { return }
            let defaultOrder = TrackField.allCases
            let index = defaultOrder.firstIndex(of: field) ?? defaultOrder.count
            let anchor = defaultOrder[..<index].last { visibleColumns.contains($0) }
            let at = anchor.flatMap { visibleColumns.firstIndex(of: $0) }.map { $0 + 1 } ?? 1
            visibleColumns.insert(field, at: min(at, visibleColumns.count))
        } else {
            visibleColumns.removeAll { $0 == field }
        }
        storeColumns()
    }

    /// 表头拖动改列序：把一列挪到第 `index` 位（**落点列的下标**，即插到它前面）。
    /// 标题列钉在首位 —— 它不可拖，落点计算也把它排除在外（最小落点是 1）。
    func moveColumn(_ field: TrackField, to index: Int) {
        guard field.canHide, let from = visibleColumns.firstIndex(of: field) else { return }
        visibleColumns.remove(at: from)
        // 移除后下标会左移一格：落点在被拖列右边时目标下标要减一。
        let target = min(max(1, index > from ? index - 1 : index), visibleColumns.count)
        visibleColumns.insert(field, at: target)
        storeColumns()
    }

    /// 恢复默认字段：八列全开、回到默认顺序，**拖宽的覆盖一并清掉** ——
    /// 「恢复默认」就该连宽度一起回默认。
    func resetColumns() {
        visibleColumns = TrackField.allCases
        columnWidths = [:]
        defaults.removeObject(forKey: PrefKey.columns)
        defaults.removeObject(forKey: PrefKey.columnWidths)
    }

    private func storeColumns() {
        defaults.set(visibleColumns.map(\.rawValue), forKey: PrefKey.columns)
    }

    private func storeColumnWidths() {
        let raw = Dictionary(uniqueKeysWithValues: columnWidths.map { ($0.key.rawValue, Double($0.value)) })
        defaults.set(raw, forKey: PrefKey.columnWidths)
    }

    /// 读回列宽覆盖。**全列都收**（标题列的覆盖是最小宽），宽度 clamp 到
    /// 下限 —— 存档被手改过也别让一列缩没。plist 里手写的整数经 CFPreferences
    /// 进来是 NSNumber，逐值转而不是整字典 cast。
    private static func storedColumnWidths() -> [TrackField: CGFloat] {
        guard let raw = UserDefaults.standard.dictionary(forKey: PrefKey.columnWidths) else {
            NSLog("[prefs] columnWidths 无存档")
            return [:]
        }
        var result: [TrackField: CGFloat] = [:]
        for (key, value) in raw {
            // 数值优先（app 自己写的），字符串数字也认（手工改存档 / 外部工具）。
            let width = (value as? NSNumber)?.doubleValue
                ?? (value as? String).flatMap(Double.init)
            guard let field = TrackField(rawValue: key), let width else { continue }
            result[field] = max(TrackMetrics.minColumnWidth, width)
        }
        NSLog("[prefs] columnWidths 读回 %d 项: %@", result.count, String(describing: result))
        return result
    }

    /// 分页的两路必须服务端排序（理由见 `toggleSort`）。
    private var usesServerOrdering: Bool {
        switch mode {
        case .allSongs, .filtered: return true
        default: return false
        }
    }

    /// 本地排序。文本列用 `localizedStandardCompare`（中文 / 日文按当地习惯排，
    /// 不是码点序）；全等键上再按 id 兜底 —— 否则同一批数据每次排出来的次序都
    /// 可能不同（Swift 的 `sorted` 不保证稳定）。
    private func applyLocalSort(_ list: [AudioSong]) -> [AudioSong] {
        guard let sort else { return list }
        let ascending = sort.ascending
        return list.sorted { a, b in
            let order: ComparisonResult
            switch sort.field {
            case .title: order = a.title.localizedStandardCompare(b.title)
            case .artist: order = a.artist.localizedStandardCompare(b.artist)
            case .album: order = a.album.localizedStandardCompare(b.album)
            case .genre: order = a.genre.localizedStandardCompare(b.genre)
            case .year: order = Self.compare(a.year ?? 0, b.year ?? 0)
            case .duration: order = Self.compare(a.duration, b.duration)
            case .track: order = Self.compare(a.track ?? 0, b.track ?? 0)
            case .rating: order = Self.compare(a.rating, b.rating)
            }
            if order == .orderedSame { return a.id < b.id }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        if a == b { return .orderedSame }
        return a < b ? .orderedAscending : .orderedDescending
    }

    /// 读回排序偏好。没存过 = 不排序（服务端默认顺序）。
    private static func storedSort() -> SongSort? {
        guard let raw = UserDefaults.standard.string(forKey: PrefKey.sortField),
              let field = TrackField(rawValue: raw) else { return nil }
        let ascending = UserDefaults.standard.object(forKey: PrefKey.sortAscending) as? Bool ?? true
        return SongSort(field: field, ascending: ascending)
    }

    /// 读回列序。没存过就是默认顺序；存过的里无论有没有标题列，标题都在
    /// 首位 —— 主键列不可隐藏，这条不能靠存出来的数据保证。
    /// 顺手去重：存档被手改过也别让一列在表头出现两次。
    private static func storedColumns() -> [TrackField] {
        guard let raw = UserDefaults.standard.array(forKey: PrefKey.columns) as? [String] else {
            return TrackField.allCases
        }
        var seen = Set<TrackField>()
        let order = raw.compactMap(TrackField.init(rawValue:)).filter { seen.insert($0).inserted }
        return [.title] + order.filter { $0 != .title }
    }

    // MARK: 内部

    private func resetScope() {
        filter = nil
        searchKeyword = ""
        searchText = ""
        selectedSongID = nil
    }

    /// 落一页数据。`localSort` 给「一次要齐」的来源用（服务端没排，本地排）；
    /// 分页的两路服务端已经排好了，本地不能再排一遍 —— 两边的 collation 不完全
    /// 一致，重排会让「已加载的前几页」与「服务端顺序」对不上。
    private func setSongs(_ page: AudioSongPage, localSort: Bool = false) {
        songs = localSort ? applyLocalSort(page.songs) : page.songs
        total = page.total
        artists = []
        albums = []
        genres = []
    }

    private func clearContent() {
        songs = []
        total = 0
        artists = []
        albums = []
        genres = []
    }
}

// MARK: - 页面

/// 听歌 · 曲库：内容区侧栏选数据源，主区一张表到底。
///
/// 「点艺术家 / 专辑名」不新开版式 —— 回到同一张表、代入筛选、页头换字。
/// 这是原型「曲库 · 已筛选」那一屏的规矩，也是产品定义里「不新增专辑页 / 艺人页」那条。
struct LibraryView: View {
    @Environment(AppState.self) private var state

    /// 曲库状态挂在 `AppState` 上，不是这个视图的 `@State` —— 沉浸模式会把这一页
    /// 从层级上换下来，状态跟着视图走的话，进出一次沉浸模式就退回「全部曲目」
    /// 并重拉一千首（理由同样写在 `AppState.library`）。
    private var model: LibraryModel { state.library }

    var body: some View {
        HStack(spacing: 0) {
            LibraryRail(model: model, manager: state.sessionManager)
            main
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dmPanel)
        .task { await model.loadIfNeeded(state.sessionManager) }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            DmPageHead(model.headTitle, subtitle: model.headSubtitle) {
                if model.isFilterActive {
                    Button("清除筛选") {
                        Task { await model.clearFilter(on: state.sessionManager) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                IconButton(iconName: "refresh-cw") {
                    Task { await model.refresh(state.sessionManager) }
                }
            }

            toolbar

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolbar: some View {
        HStack(spacing: DmSpace.s8) {
            DmSegmented(
                LibraryModel.Dimension.allCases,
                selection: Binding(
                    get: { model.dimension },
                    set: { newValue in
                        Task { await model.select(newValue, on: state.sessionManager) }
                    }
                ),
                on: .panel
            ) { $0.title }

            Spacer(minLength: 0)

            DmSearchField(
                // 模型不归本视图所有（在 `AppState` 上），没有 `$` 投影，手动包一层。
                text: Binding(
                    get: { model.searchText },
                    set: { model.searchText = $0 }
                ),
                placeholder: "搜索标题、艺术家、专辑",
                // 冒烟通路的「把光标放进搜索框」请求（AI 点不了 UI）。
                focusTicket: state.searchFocusTicket
            ) {
                Task { await model.submitSearch(on: state.sessionManager) }
            }
            .frame(width: 280)
        }
        .padding(.horizontal, DmSpace.s24)
        .padding(.bottom, DmSpace.s12)
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.errorMessage {
            LibraryNotice(
                icon: "triangle-alert",
                title: "读不到曲库",
                note: message,
                actionTitle: "重试"
            ) {
                Task { await model.refresh(state.sessionManager) }
            }
        } else if model.isLoading && model.isEmptyContent {
            LibraryNotice(
                icon: "loader",
                title: "正在载入…",
                note: "首屏拉一页 1000 首，约 1 秒"
            )
        } else if model.showsTrackTable {
            if model.songs.isEmpty {
                LibraryNotice(
                    icon: "music",
                    title: "这里还没有曲目",
                    note: "换一个维度，或改个关键词"
                )
            } else {
                TrackTable(model: model, manager: state.sessionManager, engine: state.playback) { song, stars in
                    Task { await model.rate(song, to: stars, on: state) }
                } onContextMenu: { song, point in
                    state.openSongMenu(song, at: point, queue: model.songs)
                }
            }
        } else if model.isEmptyContent {
            LibraryNotice(
                icon: "music",
                title: "这里还没有内容",
                note: "曲库里还没扫到这一类"
            )
        } else {
            EntityList(model: model, manager: state.sessionManager)
        }
    }
}

// MARK: - 内容区侧栏

/// 听歌模块的内容区侧栏（原型 `.msider`）：资料库的四个来源 + 我的歌单。
///
/// 这一列是**二级导航（灰底白字轨）**：选中 `panel-3` 底 + 白字（`RailRowState`），
/// 与外壳侧栏的实心主色底 + 白字（`SelectState`）分轨 —— 侧栏行表达「你在哪个
/// 模块」，这一列表达「这一屏在看哪份曲目」。主色底全页只留外壳侧栏一处
/// （2026-10-18「导航权重方案」四层口径）。
private struct LibraryRail: View {
    let model: LibraryModel
    let manager: SessionManager?
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("资料库")
                .font(.system(size: DmText.t11, weight: .bold))
                .kerning(0.66)
                .foregroundColor(Color.dmInk3)
                .padding(.horizontal, DmSpace.s16)
                .padding(.top, DmSpace.s14)
                .padding(.bottom, DmSpace.s8)

            ScrollView {
                VStack(alignment: .leading, spacing: DmSpace.s2) {
                    LibraryRailRow(
                        icon: "sparkles",
                        title: "每日随机",
                        count: model.count(for: .dailyRandom),
                        isSelected: model.source == .dailyRandom
                    ) {
                        Task { await model.select(source: .dailyRandom, on: manager) }
                    }

                    LibraryRailRow(
                        icon: "music",
                        title: "全部曲目",
                        count: model.count(for: .all),
                        isSelected: model.source == .all
                    ) {
                        Task { await model.select(source: .all, on: manager) }
                    }

                    // 分组标题行：右侧一颗小 +（低频操作不占整行）—— 新建歌单弹窗
                    // 与右键菜单二级面板里的「新建歌单…」是同一个入口。
                    HStack(spacing: DmSpace.s4) {
                        Text("我的歌单")
                            .font(.system(size: DmText.t11, weight: .bold))
                            .kerning(0.66)
                            .foregroundColor(Color.dmInk3)
                        Spacer(minLength: 0)
                        Button {
                            state.openLibraryDialog(.newPlaylist)
                        } label: {
                            LucideIcon("plus", size: DmIcon.i12)
                                .foregroundColor(Color.dmInk3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, DmSpace.s8)
                    .padding(.top, DmSpace.s14)
                    .padding(.bottom, DmSpace.s4)

                    ForEach(model.playlists) { playlist in
                        LibraryRailRow(
                            icon: playlist.isSmart ? "sparkles" : "list-music",
                            title: playlist.name,
                            count: model.count(for: .playlist(playlist)),
                            isSelected: model.source == .playlist(playlist)
                        ) {
                            Task { await model.select(source: .playlist(playlist), on: manager) }
                        }
                    }

                    LibraryRailRow(
                        icon: "star",
                        title: "评分 ≥ \(LibraryModel.chartRating) 星",
                        count: model.count(for: .topRated),
                        isSelected: model.source == .topRated
                    ) {
                        Task { await model.select(source: .topRated, on: manager) }
                    }
                }
                .padding(DmSpace.s8)
            }
        }
        .frame(width: 200, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.dmLine)
                .frame(width: DmLine.hairline)
        }
    }
}

/// 侧栏一行：图标 14 / 字 13 / 计数 11，横向 8、纵向 6 —— 照原型 `.tree-row`。
/// 高度由内边距长出来，不写死。
private struct LibraryRailRow: View {
    let icon: String
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon(icon, size: DmIcon.i14)
                .foregroundColor(RailRowState.secondaryForeground(isSelected: isSelected, hovered: isHovered))
            Text(title)
                .font(.system(size: DmText.t13))
                .foregroundColor(RailRowState.foreground(isSelected: isSelected, hovered: isHovered))
                .lineLimit(1)
            Spacer(minLength: DmSpace.s4)
            if let count {
                Text("\(count)")
                    .font(.system(size: DmText.t11))
                    .monospacedDigit()
                    .foregroundColor(RailRowState.secondaryForeground(isSelected: isSelected, hovered: isHovered))
            }
        }
        .padding(.horizontal, DmSpace.s8)
        .padding(.vertical, DmSpace.s6)
        .background(RailRowState.background(isSelected: isSelected, hovered: isHovered && !isSelected))
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r6))
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: action)
    }
}

// MARK: - 曲目表

/// 表的排版参数。列宽、对齐与「能不能隐藏」都跟着 `TrackField`（那一组同时也是
/// 可排序的字段，定义在 `AudioLibrary`）；这里只剩列内边距 —— 曲库表与队列表
/// 共用同一档，两边的表头与行都从这里取。
enum TrackMetrics {
    static let padH: CGFloat = 10
    /// 表头行高。由 cell 的上下 `s8` + 11px 字 + 底下一根发丝决定 ——
    /// 字段配置菜单浮在它下面，改表头内边距要一起改这里。
    static let headerHeight: CGFloat = 30
    /// 字段配置那一列的宽（原型 `colgroup` 最后一格 32）。表头那一格放竖三点，
    /// 行尾是**一格空道** —— 曲库表的行也要留出这一格，否则行的自适应标题列会比
    /// 表头宽 32，后面每一列整体右移、与表头错位（2026-10-13 用户真机抓到）。
    static let configWidth: CGFloat = 32
    /// 标题列保底宽。固定列合计 536，主区一挤自适应列会被压成 0、整列凭空消失。
    static let titleMinWidth: CGFloat = 180
    /// 固定列拖宽后的下限。再窄右对齐的数字格就贴边了（默认最窄的列是 48）。
    static let minColumnWidth: CGFloat = 44

    /// 表格内容宽。视口比它宽时标题列吸收余量（铺满），比它窄时**横向滚动**
    /// —— 表头与行在同一个滚动容器里，一起滚，列不会各滚各的。
    /// 固定列合计**与列序无关**（求和），所以这里只按「显示了哪几列」算；
    /// 宽度优先取拖宽覆盖（`widths`），没有就用 `TrackField` 的默认值。
    static func contentWidth(viewport: CGFloat, visible: [TrackField],
                             widths: [TrackField: CGFloat] = [:]) -> CGFloat {
        var fixed = CGFloat.zero
        for field in visible where field != .title {
            fixed += widths[field] ?? field.fixedWidth
        }
        // 标题列的覆盖是**最小宽**：内容宽下限跟着它走，视口更宽仍吸收余量。
        return max(viewport, (widths[.title] ?? titleMinWidth) + fixed + configWidth)
    }
}

/// 表头固定——列表滚多长表头都钉在顶上，所以它放在 `ScrollView` 外面，
/// 不对着滚（原型是 CSS `sticky`）。
///
/// 字段配置菜单浮在表头右下方（原型 `.menu` 定位在 `top:151px;right:11px` 那一格）：
/// 它压在 `ZStack` 最上层，配一层透明遮罩接住「点别处关闭」—— 不参与布局，
/// 也不进滚动区。
private struct TrackTable: View {
    let model: LibraryModel
    let manager: SessionManager?
    let engine: PlaybackEngine?
    let onRate: (AudioSong, Int) -> Void
    /// 右键一行：参数是**根视图坐标**（左上原点）里的指针位置 —— 菜单浮在整个
    /// 窗口之上，行在滚动区里画不了（会被后面的行盖住、也会被滚动区裁掉）。
    let onContextMenu: (AudioSong, CGPoint) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 视口窄于内容时横向滚动（表头与行在同一个滚动容器里，一起滚）。
            // 内容宽由可见列算出，标题列吸收余量 —— 窗口宽时与以前完全一样。
            GeometryReader { geo in
                let width = TrackMetrics.contentWidth(viewport: geo.size.width,
                                                      visible: model.visibleColumns,
                                                      widths: model.columnWidths)
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        TrackHeader(
                            sort: model.sort,
                            columns: model.visibleColumns,
                            widths: model.columnWidths,
                            onSort: { field in
                                Task { await model.toggleSort(field, on: manager) }
                            },
                            onConfigure: { model.showsFieldMenu = true },
                            onMove: { field, index in model.moveColumn(field, to: index) },
                            onResize: { field, width in
                                model.setColumnWidth(width, for: field)
                            },
                            onFrames: { frames in model.headerFrames = frames }
                        )

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(model.songs) { song in
                                    TrackRow(
                                        song: song,
                                        isSelected: model.selectedSongID == song.id,
                                        isPlaying: engine?.currentSong?.id == song.id,
                                        visible: model.visibleColumns,
                                        widths: model.columnWidths,
                                        // 行尾留出字段配置那一格的空道，与表头对齐。
                                        trailingLane: TrackMetrics.configWidth
                                    ) {
                                        model.select(song: song)
                                    } onPlay: {
                                        // 双击 = 从这首起播，当前这张表就是队列（滚到底懒加载
                                        // 追加进模型后，下次播放自然带上新页）。
                                        model.select(song: song)
                                        engine?.play(model.songs, songID: song.id)
                                    } onRate: { stars in
                                        onRate(song, stars)
                                    } onContextMenu: { point in
                                        model.select(song: song)
                                        onContextMenu(song, point)
                                    }
                                }
                                if model.hasMore {
                                    LoadMoreRow(
                                        loaded: model.songs.count,
                                        isLoading: model.isLoadingMore
                                    ) {
                                        Task { await model.loadMore(manager) }
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: width)
                }
            }

            if model.showsFieldMenu {
                // 压在表头与列表之上的一层：点哪儿都先收菜单。
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { model.showsFieldMenu = false }

                fieldMenu
                    .padding(.top, TrackMetrics.headerHeight)
                    .padding(.trailing, DmSpace.s4)
            }
        }
    }

    /// 表头最右竖三点弹出来的字段配置（照原型那一格）：标题 + 八列勾选框
    /// （标题是主键列，走禁用态勾选）+ 分隔线 +「恢复默认字段」。
    /// **勾完不收菜单** —— 连勾几列是常事，开着才看得见勾的状态。
    private var fieldMenu: some View {
        DmMenuCard(width: 196) {
            DmMenuTitle("显示的字段")
            ForEach(TrackField.allCases) { field in
                DmMenuRow(
                    title: field.label,
                    action: { model.setVisible(field, !model.isVisible(field)) }
                ) {
                    DmCheckbox(isOn: model.isVisible(field), isDisabled: !field.canHide)
                }
            }
            DmMenuSeparator()
            DmMenuRow(title: "恢复默认字段", icon: "rotate-ccw") {
                model.resetColumns()
            }
        }
    }
}

/// 表头：每一列都可点 —— 点了按这一列排，同一列再点换方向（正序 `chevron-up` /
/// 倒序 `chevron-down`，只有当前排序列带箭头）。一列都没点时是服务端默认顺序。
/// 能隐的列还能拖 —— 按下拖过阈值就是改列序，拖动中的列画虚线框 + 主色字 +
/// 拖动手柄，落点画主色竖线。最右一格是字段配置（不可拖、也不当落点）。
private struct TrackHeader: View {
    let sort: SongSort?
    /// 列序。与行共用同一份 —— 表头拖动改的就是它。
    let columns: [TrackField]
    /// 列宽覆盖（拖右缘改的），与行共用同一份。
    let widths: [TrackField: CGFloat]
    let onSort: (TrackField) -> Void
    let onConfigure: () -> Void
    /// 拖动落点：把一列插到第 `index` 位。
    let onMove: (TrackField, Int) -> Void
    /// 拖右缘调宽：绝对宽度（clamp 在模型 `setColumnWidth` 里做）。
    let onResize: (TrackField, CGFloat) -> Void
    /// 各格的位置（窗口坐标）报出去。落点判定在本视图里自己用，报出去是给冒烟通路
    /// 定位用的 —— AI 点不了 UI，只能自己合成鼠标事件，得先知道各格在哪儿。
    let onFrames: ([TrackField: CGRect]) -> Void

    /// 正在拖的列（拖动中它画虚线框 + 主色字 + 拖动手柄图标）。
    @State private var dragging: TrackField?
    /// 拖动中指针的落点（窗口坐标 x）—— 竖线画在它对应的列边界上。
    @State private var dropX: CGFloat?
    /// 各格的位置（**窗口坐标**，与 `dropX` 同一套）。落点判定靠它 —— 列宽不是定值
    /// （标题列自适应），只能等 AppKit 那边实测报上来。
    @State private var frames: [TrackField: CGRect] = [:]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { field in
                sortCell(field)
            }
            configCell
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
    }

    @ViewBuilder
    private func sortCell(_ field: TrackField) -> some View {
        let isActive = sort?.field == field
        let isDragging = dragging == field

        HStack(spacing: DmSpace.s2) {
            Text(field.label)
                .font(.system(size: DmText.t11, weight: .bold))
                .kerning(0.33)
            if isActive {
                LucideIcon(sort?.ascending == false ? "chevron-down" : "chevron-up",
                           size: DmIcon.i10)
                    .foregroundColor(Color.dmAccent2)
            }
            if isDragging {
                // 拖动中的列挂手柄图标（SF 里没有 lucide 的 grip-vertical，
                // 取语义同族的 `line.3.horizontal`，见设计规范「图标名两套」）。
                LucideIcon("grip-vertical", size: DmIcon.i10)
                    .foregroundColor(Color.dmAccent2)
            }
        }
        .foregroundColor(isDragging ? Color.dmAccent2 : Color.dmInk3)
        .padding(.horizontal, TrackMetrics.padH)
        .padding(.vertical, DmSpace.s8)
        .modifier(ColumnWidth(field: field, override: widths[field]))
        .contentShape(Rectangle())
        // 一个格子上两个动作：点 = 排序、拖 = 改列序。用 AppKit 接管层而不是
        // SwiftUI 手势 —— 手势那条路合成事件验不到（见 `HeaderGrabber`）。
        // 🔴 接管层要从右缘让出 `hitWidth`：平台视图命中测试先于 SwiftUI 层，
        // 整格罩住时调宽把手收不到任何事件（2026-10-18 用户实抓）；对齐必须
        // 显式 .leading —— overlay 默认居中，缩窄后仍压住热区内半截（同日二抓）。
        .overlay(alignment: .leading) {
            grabber(field)
                .padding(.trailing, ColumnResizer.hitWidth)
        }
        // 调宽把手：只占右缘 7px 热区，格子中间仍归点击排序。**全列都给**
        // —— 标题列拖出的是最小宽，视口有富余时仍吸收余量。
        .overlay(alignment: .trailing) {
            ColumnResizer(width: widths[field] ?? (field.width ?? TrackMetrics.titleMinWidth)) {
                onResize(field, $0)
            }
        }
        .overlay {
            if isDragging {
                RoundedRectangle(cornerRadius: DmRadius.r4)
                    .strokeBorder(style: StrokeStyle(lineWidth: DmLine.base, dash: [3, 2]))
                    .foregroundColor(Color.dmAccent2)
            }
        }
        // 落点竖线：插在这一格之前 / 插在最后一格之后，都画在主色竖线上。
        .overlay(alignment: .leading) {
            if dropIndexIfDragging == columns.firstIndex(of: field) { dropLine }
        }
        .overlay(alignment: .trailing) {
            if dropIndexIfDragging == columns.count, field == columns.last { dropLine }
        }
        .help(field.canHide ? "点按排序 · 拖动改列序" : "点按排序")
    }

    /// 表头一格的鼠标接管层：点击排序、拖动改列序（位移判定在 AppKit 那一侧）。
    /// 位置也由它报上来（`onFrame`）—— 本格多宽、在窗口的哪儿，它自己最清楚。
    private func grabber(_ field: TrackField) -> some View {
        HeaderGrabber(
            onClick: { onSort(field) },
            onDrag: { point in
                dragging = field
                dropX = point.x
            },
            onDrop: { point in
                let index = dropIndex(at: point.x)
                dragging = nil
                dropX = nil
                onMove(field, index)
            },
            isDraggable: field.canHide,
            onFrame: { frame in
                frames[field] = frame
                onFrames(frames)
            }
        )
    }

    /// 拖动中要插到第几列之前。没在拖就是 `nil`（竖线一个都不画）。
    private var dropIndexIfDragging: Int? {
        guard dragging != nil, let dropX else { return nil }
        return dropIndex(at: dropX)
    }

    /// 落点插到第几列之前：指针在某列的左半边 → 插到它前面，右半边 → 插到它后面。
    /// 标题列不可拖、也不当落点（它是首位，最小落点是 1）。
    /// 比的是窗口坐标的 x —— 与 `dropX`、与各格报上来的位置同一套。
    private func dropIndex(at x: CGFloat) -> Int {
        for (index, field) in columns.enumerated() where field.canHide {
            guard let frame = frames[field] else { continue }
            if x < frame.midX { return index }
        }
        return columns.count
    }

    /// 落点竖线（原型 `box-shadow:-2px 0 0` 那条）。线宽取尺度档里的 `line.bold`（3）
    /// —— 1px 在这张表上太轻，压不住。
    private var dropLine: some View {
        Rectangle()
            .fill(Color.dmAccent2)
            .frame(width: DmLine.bold, height: TrackMetrics.headerHeight)
    }

    /// 字段配置（原型 `.tbl th.th-cfg`：列宽 32、按钮右贴、右留 `s6`）。
    private var configCell: some View {
        IconButton(iconName: "more-vertical", compact: true) { onConfigure() }
            .padding(.trailing, DmSpace.s6)
            .frame(width: TrackMetrics.configWidth, alignment: .trailing)
    }
}

/// 列宽：标题列自适应（保底 `titleMinWidth`），其余按列宽覆盖、没有就退回
/// `TrackField.width` 的默认值。表头与行共用 —— 两边的列必须一样宽，
/// 所以宽度只从这一份来（`override` 由模型 `effectiveWidth` 给）。
private struct ColumnWidth: ViewModifier {
    let field: TrackField
    /// 拖宽覆盖（模型 `columnWidths` 里那份）。`nil` = 用默认宽。
    var override: CGFloat?

    func body(content: Content) -> some View {
        // 自适应列（标题）：min = 覆盖 ?? 保底、max 恒 .infinity —— 覆盖是**最小宽**；
        // 固定列：min == max == 覆盖 ?? 默认宽 —— 钉死。一个 frame 调用表达两种。
        let pinned = override ?? field.width
        return content.frame(
            minWidth: field.width == nil ? (override ?? TrackMetrics.titleMinWidth) : pinned,
            maxWidth: field.width == nil ? nil : pinned,
            alignment: field.isTrailing ? .trailing : .leading
        )
    }
}

/// 一行曲目 —— **列表行（灰底轨）**，且是唯一同时承担「正在播」与「选中」
/// 两个标记的行：**正在播独占 accent 档**（`panel-2` 底 + `accent-2` 字、
/// 次要格 `accent`、标题前挂均衡器）；**选中降一档**（2026-10-13 用户拍板）——
/// 与正在播同档会看着像两首同时在播，选中改成悬停同款底（现在是 `panel-3`）、
/// 字保持默认态。选中本身留着（以后多选拖歌单要用）。悬停只给两态都没有
/// 的行抬底 —— 选中行本来就停在悬停底上。列与列宽对着原型 `colgroup`。
struct TrackRow: View {
    let song: AudioSong
    let isSelected: Bool
    var isPlaying: Bool = false
    /// 显示的列，**有序** —— 顺序即列序，与表头共用同一份。
    /// 默认全开：队列行与单视图台架那两处不关心列配置。
    var visible: [TrackField] = TrackField.allCases
    /// 列宽覆盖（拖表头右缘改的），与表头共用同一份；空 = 全按默认宽。
    var widths: [TrackField: CGFloat] = [:]
    /// 行尾空道宽。曲库表填 `TrackMetrics.configWidth`（与表头那格字段配置对齐），
    /// 没有这一格的表（队列）留 0。
    var trailingLane: CGFloat = 0
    let onSelect: () -> Void
    var onPlay: (() -> Void)?
    /// 给了评分列就可点；没给（如队列页之外的只读场合）保持只读。
    var onRate: ((Int) -> Void)?
    /// 右键（参数是指针位置，已在根视图坐标系里）。不给就不接右键。
    var onContextMenu: ((CGPoint) -> Void)?

    @State private var isHovered = false

    /// 显式 init：@State 私有属性会让成员级 init 变 private，跨文件
    /// （`tools` 台架 / 单视图核对）构造不了。
    init(
        song: AudioSong,
        isSelected: Bool,
        isPlaying: Bool = false,
        visible: [TrackField] = TrackField.allCases,
        widths: [TrackField: CGFloat] = [:],
        trailingLane: CGFloat = 0,
        onSelect: @escaping () -> Void,
        onPlay: (() -> Void)? = nil,
        onRate: ((Int) -> Void)? = nil,
        onContextMenu: ((CGPoint) -> Void)? = nil
    ) {
        self.song = song
        self.isSelected = isSelected
        self.isPlaying = isPlaying
        self.visible = visible
        self.widths = widths
        self.trailingLane = trailingLane
        self.onSelect = onSelect
        self.onPlay = onPlay
        self.onRate = onRate
        self.onContextMenu = onContextMenu
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: DmSpace.s8) {
                DmCover(album: song.album, artist: song.albumArtist, folder: song.folder, size: 28)
                if isPlaying {
                    EqualizerBars()
                }
                Text(song.title)
                    .font(.system(size: DmText.t13, weight: .medium))
                    .foregroundColor(ListRowState.primaryForeground(isSelected: isPlaying))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // 悬停给全名：列窄了内容吃进省略号，靠它看全（下同）。
                    .help(song.title)
            }
            .padding(.horizontal, TrackMetrics.padH)
            // 标题列自适应，**覆盖是最小宽**（与表头同一份）；无覆盖时保底
            // `titleMinWidth` —— 固定列合计 536，主区一挤自适应列会被压成 0、
            // 整列凭空消失（真机踩过）。标题列不可隐藏（主键列）。
            .frame(minWidth: widths[.title] ?? TrackMetrics.titleMinWidth,
                   maxWidth: .infinity, alignment: .leading)

            // 列序由模型给，行跟着表头一起换位（表头拖动改列序时两边同步）。
            ForEach(visible.filter { $0 != .title }) { field in
                cell(field)
            }

            if trailingLane > 0 {
                Color.clear.frame(width: trailingLane)
            }
        }
        .frame(height: 34)
        // 选中 = 悬停同款底（常亮）：把「悬停或选中」一起喂给 hovered，
        // 字色另喂真实的 isHovered —— 选中行不悬停时字保持默认态。
        .background(ListRowState.background(isSelected: isPlaying, hovered: (isHovered || isSelected) && !isPlaying))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2) {
            onPlay?()
        }
        // 右键捕获层压在行上：它只接右键事件，左键与悬停一律穿透（见 `RightClickCatcher`）。
        .overlay {
            if let onContextMenu {
                RightClickCatcher(onRightClick: onContextMenu)
            }
        }
    }

    /// 一格。标题列不走这里 —— 它要内嵌封面、吃自适应宽，单独画在上面。
    /// 每列的画法只此一处：加一列改 `TrackField` 与这里两处。
    @ViewBuilder
    private func cell(_ field: TrackField) -> some View {
        switch field {
        case .title:
            EmptyView()
        case .artist:
            plain(song.artist, field: .artist)
        case .album:
            plain(song.album, field: .album)
        case .genre:
            plain(song.genreTags.joined(separator: " · "), field: .genre)
        case .year:
            dim(song.yearText, field: .year)
        case .duration:
            dim(song.durationText, field: .duration)
        case .track:
            dim(song.track.map(String.init) ?? "", field: .track)
        case .rating:
            // 未评分的行**悬停才浮出空星** —— 浮出来即「这一格能点」。
            // 右留 `s8`：5 颗星 60 宽正好落进 68 的列里，右缘与表头对齐。
            RatingStars(
                rating: song.rating,
                isSelected: isPlaying,
                revealsEmpty: isHovered && onRate != nil,
                onRate: onRate
            )
            .padding(.trailing, DmSpace.s8)
            .modifier(ColumnWidth(field: .rating, override: widths[.rating]))
        }
    }

    @ViewBuilder
    private func plain(_ text: String, field: TrackField) -> some View {
        Text(text)
            .font(.system(size: DmText.t13))
            .foregroundColor(ListRowState.foreground(isSelected: isPlaying, hovered: isHovered && !isPlaying))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, TrackMetrics.padH)
            .modifier(ColumnWidth(field: field, override: widths[field]))
            .help(text)
    }

    @ViewBuilder
    private func dim(_ text: String, field: TrackField) -> some View {
        Text(text)
            .font(.system(size: DmText.t12))
            .foregroundColor(ListRowState.secondaryForeground(isSelected: isPlaying, hovered: isHovered && !isPlaying))
            .lineLimit(1)
            .monospacedDigit()
            .padding(.horizontal, TrackMetrics.padH)
            .modifier(ColumnWidth(field: field, override: widths[field]))
            .help(text)
    }
}

/// 分页懒加载的那一行：滚到底自动要下一页，也可以点。
private struct LoadMoreRow: View {
    let loaded: Int
    let isLoading: Bool
    let onLoad: () -> Void

    var body: some View {
        Button(action: onLoad) {
            HStack(spacing: DmSpace.s8) {
                LucideIcon("chevron-down", size: DmIcon.i14)
                Text(isLoading ? "正在加载…" : "已载入 \(loaded) 首，继续加载")
            }
            .font(.system(size: DmText.t12))
            .foregroundColor(Color.dmInk3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DmSpace.s12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onAppear(perform: onLoad)
    }
}

// MARK: - 实体列表（艺术家 / 专辑 / 流派）

/// 三个实体维度共用一份列表 —— 行形态与侧栏行不同轨：这里是**列表行**
/// （浅底轨），点一行就代进筛选回表。
private struct EntityList: View {
    let model: LibraryModel
    let manager: SessionManager?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                switch model.dimension {
                case .artist:
                    ForEach(model.artists) { artist in
                        EntityRow(title: artist.name, subtitle: nil) {
                            Task { await model.apply(artist.name, on: manager) }
                        }
                    }
                case .album:
                    ForEach(model.albums) { album in
                        EntityRow(title: album.name, subtitle: album.artist) {
                            Task { await model.apply(album.name, on: manager) }
                        }
                    }
                default:
                    ForEach(model.genres, id: \.self) { genre in
                        EntityRow(title: genre, subtitle: nil) {
                            Task { await model.apply(genre, on: manager) }
                        }
                    }
                }
            }
            .padding(.horizontal, DmSpace.s14)
        }
    }
}

private struct EntityRow: View {
    let title: String
    let subtitle: String?
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            Text(title)
                .font(.system(size: DmText.t13))
                .foregroundColor(ListRowState.foreground(hovered: isHovered))
                .lineLimit(1)
            Spacer(minLength: DmSpace.s8)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: DmText.t12))
                    .foregroundColor(ListRowState.secondaryForeground(isSelected: false, hovered: isHovered))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DmSpace.s8)
        .frame(height: DmControl.h32)
        .background(ListRowState.background(isSelected: false, hovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r6))
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - 提示

/// 空态 / 错误态 / 载入态共用一个块：图标 + 一句主文 + 一句说明（可选动作）。
/// 形态照原型 `.empty-lg`。
private struct LibraryNotice: View {
    let icon: String
    let title: String
    let note: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: DmSpace.s12) {
            LucideIcon(icon, size: DmIcon.i24)
                .foregroundColor(Color.dmInk3)
            Text(title)
                .font(.system(size: DmText.t15, weight: .semibold))
                .foregroundColor(Color.dmInk2)
            Text(note)
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, DmSpace.s2)
            }
        }
        .padding(DmSpace.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

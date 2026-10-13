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
            case .all: return "全部曲目"
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
    /// 显示的列。恒含 `.title`（主键列不可隐藏）—— 存的也只有可隐藏的那几列。
    private(set) var visibleColumns: Set<TrackField> = Set(TrackField.allCases)
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

    // MARK: 表视图偏好（排序与列显隐，持久化）

    private let defaults = UserDefaults.standard

    private enum PrefKey {
        static let sortField = "nas.library.sortField"
        static let sortAscending = "nas.library.sortAscending"
        static let columns = "nas.library.columns"
    }

    init() {
        sort = Self.storedSort()
        visibleColumns = Self.storedColumns()
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
    func setVisible(_ field: TrackField, _ visible: Bool) {
        guard field.canHide else { return }
        if visible { visibleColumns.insert(field) } else { visibleColumns.remove(field) }
        defaults.set(TrackField.allCases.filter { visibleColumns.contains($0) }.map(\.rawValue),
                     forKey: PrefKey.columns)
    }

    /// 恢复默认字段：八列全开。
    func resetColumns() {
        visibleColumns = Set(TrackField.allCases)
        defaults.removeObject(forKey: PrefKey.columns)
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

    /// 读回列显隐。没存过就是全开；存过的内容里无论有没有标题列，标题都在
    /// —— 主键列不可隐藏，这条不能靠存出来的数据保证。
    private static func storedColumns() -> Set<TrackField> {
        guard let raw = UserDefaults.standard.array(forKey: PrefKey.columns) as? [String] else {
            return Set(TrackField.allCases)
        }
        return Set(raw.compactMap(TrackField.init(rawValue:))).union([.title])
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
/// 这一列是**列表行（浅底轨）**：选中 `accent-soft` 底 + `accent-2` 字，
/// 与外壳侧栏的实心主色底 + 白字分轨 —— 侧栏行表达「你在哪个模块」，
/// 这一列表达「这一屏在看哪份曲目」，一屏里只有一行选中，量级与列表行同族。
private struct LibraryRail: View {
    let model: LibraryModel
    let manager: SessionManager?

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

                    // 分组标题行：与密码管理的新建分类同形 —— 低频操作不占整行。
                    // 「+ 新建歌单」跟着歌单的写入（`Playlist.create`）一起落，见 README。
                    Text("我的歌单")
                        .font(.system(size: DmText.t11, weight: .bold))
                        .kerning(0.66)
                        .foregroundColor(Color.dmInk3)
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
                .foregroundColor(ListRowState.secondaryForeground(isSelected: isSelected, hovered: isHovered))
            Text(title)
                .font(.system(size: DmText.t13))
                .foregroundColor(ListRowState.foreground(isSelected: isSelected, hovered: isHovered))
                .lineLimit(1)
            Spacer(minLength: DmSpace.s4)
            if let count {
                Text("\(count)")
                    .font(.system(size: DmText.t11))
                    .monospacedDigit()
                    .foregroundColor(ListRowState.secondaryForeground(isSelected: isSelected, hovered: isHovered))
            }
        }
        .padding(.horizontal, DmSpace.s8)
        .padding(.vertical, DmSpace.s6)
        .background(ListRowState.background(isSelected: isSelected, hovered: isHovered && !isSelected))
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

    /// 表格内容宽。视口比它宽时标题列吸收余量（铺满），比它窄时**横向滚动**
    /// —— 表头与行在同一个滚动容器里，一起滚，列不会各滚各的。
    static func contentWidth(viewport: CGFloat, visible: Set<TrackField>) -> CGFloat {
        let fixed = TrackField.allCases
            .filter { $0 != .title && visible.contains($0) }
            .reduce(CGFloat.zero) { $0 + $1.fixedWidth }
        return max(viewport, titleMinWidth + fixed + configWidth)
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
                                                      visible: model.visibleColumns)
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        TrackHeader(
                            sort: model.sort,
                            visible: model.visibleColumns,
                            onSort: { field in
                                Task { await model.toggleSort(field, on: manager) }
                            },
                            onConfigure: { model.showsFieldMenu = true }
                        )

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(model.songs) { song in
                                    TrackRow(
                                        song: song,
                                        isSelected: model.selectedSongID == song.id,
                                        isPlaying: engine?.currentSong?.id == song.id,
                                        visible: model.visibleColumns,
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
/// 最右一格是字段配置。
private struct TrackHeader: View {
    let sort: SongSort?
    let visible: Set<TrackField>
    let onSort: (TrackField) -> Void
    let onConfigure: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TrackField.allCases) { field in
                if visible.contains(field) { sortCell(field) }
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

        Button { onSort(field) } label: {
            HStack(spacing: DmSpace.s2) {
                Text(field.label)
                    .font(.system(size: DmText.t11, weight: .bold))
                    .kerning(0.33)
                if isActive {
                    LucideIcon(sort?.ascending == false ? "chevron-down" : "chevron-up",
                               size: DmIcon.i10)
                        .foregroundColor(Color.dmAccent2)
                }
            }
            .foregroundColor(Color.dmInk3)
            .padding(.horizontal, TrackMetrics.padH)
            .padding(.vertical, DmSpace.s8)
            .modifier(ColumnWidth(field: field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(field.label)排序")
    }

    /// 字段配置（原型 `.tbl th.th-cfg`：列宽 32、按钮右贴、右留 `s6`）。
    private var configCell: some View {
        IconButton(iconName: "more-vertical", compact: true) { onConfigure() }
            .padding(.trailing, DmSpace.s6)
            .frame(width: TrackMetrics.configWidth, alignment: .trailing)
    }
}

/// 列宽：标题列自适应（保底 `titleMinWidth`），其余按 `TrackField.width`。
/// 表头与行共用 —— 两边的列必须一样宽，所以宽度只从 `TrackField` 来。
private struct ColumnWidth: ViewModifier {
    let field: TrackField

    func body(content: Content) -> some View {
        if let width = field.width {
            content.frame(width: width, alignment: field.isTrailing ? .trailing : .leading)
        } else {
            content.frame(minWidth: TrackMetrics.titleMinWidth, maxWidth: .infinity,
                          alignment: field.isTrailing ? .trailing : .leading)
        }
    }
}

/// 一行曲目 —— **列表行（浅底轨）**，且是唯一同时承担「正在播」与「选中」
/// 两个标记的行：**正在播独占 accent 档**（`accent-soft` 底 + `accent-2` 字、
/// 次要格 `accent`、标题前挂均衡器）；**选中降一档**（2026-10-13 用户拍板）——
/// 与正在播同档会看着像两首同时在播，选中改成悬停同款底（`panel-2`）、
/// 字保持默认态。选中本身留着（以后多选拖歌单要用）。悬停只给两态都没有
/// 的行抬底 —— 选中行本来就停在悬停底上。列与列宽对着原型 `colgroup`。
struct TrackRow: View {
    let song: AudioSong
    let isSelected: Bool
    var isPlaying: Bool = false
    /// 显示的列。默认全开 —— 队列行与单视图台架那两处不关心列配置。
    var visible: Set<TrackField> = Set(TrackField.allCases)
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
        visible: Set<TrackField> = Set(TrackField.allCases),
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
            }
            .padding(.horizontal, TrackMetrics.padH)
            // 标题列自适应，但**保底 `titleMinWidth`** —— 固定列合计 536，主区一挤
            // 自适应列会被压成 0、整列凭空消失（真机踩过）。标题列不可隐藏（主键列）。
            .frame(minWidth: TrackMetrics.titleMinWidth, maxWidth: .infinity, alignment: .leading)

            if visible.contains(.artist) { plain(song.artist, field: .artist) }
            if visible.contains(.album) { plain(song.album, field: .album) }
            if visible.contains(.genre) {
                plain(song.genreTags.joined(separator: " · "), field: .genre)
            }
            if visible.contains(.year) { dim(song.yearText, field: .year) }

            if visible.contains(.duration) { dim(song.durationText, field: .duration) }
            if visible.contains(.track) { dim(song.track.map(String.init) ?? "", field: .track) }

            if visible.contains(.rating) {
                // 未评分的行**悬停才浮出空星** —— 浮出来即「这一格能点」。
                // 右留 `s8`：5 颗星 60 宽正好落进 68 的列里，右缘与表头对齐。
                RatingStars(
                    rating: song.rating,
                    isSelected: isPlaying,
                    revealsEmpty: isHovered && onRate != nil,
                    onRate: onRate
                )
                .padding(.trailing, DmSpace.s8)
                .modifier(ColumnWidth(field: .rating))
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

    @ViewBuilder
    private func plain(_ text: String, field: TrackField) -> some View {
        Text(text)
            .font(.system(size: DmText.t13))
            .foregroundColor(ListRowState.foreground(isSelected: isPlaying, hovered: isHovered && !isPlaying))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, TrackMetrics.padH)
            .modifier(ColumnWidth(field: field))
    }

    @ViewBuilder
    private func dim(_ text: String, field: TrackField) -> some View {
        Text(text)
            .font(.system(size: DmText.t12))
            .foregroundColor(ListRowState.secondaryForeground(isSelected: isPlaying, hovered: isHovered && !isPlaying))
            .lineLimit(1)
            .monospacedDigit()
            .padding(.horizontal, TrackMetrics.padH)
            .modifier(ColumnWidth(field: field))
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

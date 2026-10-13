import SwiftUI

// MARK: - 状态

/// 曲库页的状态：维度、筛选、搜索、分页。
///
/// 维度、筛选、搜索三者共同决定「主区显示什么」，所以先合成一个 `mode` 再分发 ——
/// 分开判断会有缝：搜到一半点维度、筛选中途清空，都能落进没覆盖的组合里。
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

    var dimension: Dimension = .all
    var searchText = ""
    private(set) var searchKeyword = ""

    private(set) var songs: [AudioSong] = []
    private(set) var total = 0
    private(set) var artists: [AudioArtist] = []
    private(set) var albums: [AudioAlbum] = []
    private(set) var genres: [String] = []
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
    }

    private var mode: Mode {
        if !searchKeyword.isEmpty { return .searched(searchKeyword) }
        if let filter { return .filtered(filter) }
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
        }
    }

    var isFilterActive: Bool { filter != nil }
    var showsTrackTable: Bool { filter != nil || !searchKeyword.isEmpty || dimension == .all }
    var hasMore: Bool { songs.count < total }
    var isEmptyContent: Bool {
        songs.isEmpty && artists.isEmpty && albums.isEmpty && genres.isEmpty
    }

    // MARK: 取数

    func loadIfNeeded(_ manager: SessionManager?) async {
        guard !hasLoaded else { return }
        await refresh(manager)
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
                let page = try await AudioLibrary.songs(manager)
                guard token == generation else { return }
                setSongs(page)
            case .filtered(let filter):
                let page = try await AudioLibrary.songs(manager, matching: filter)
                guard token == generation else { return }
                setSongs(page)
            case .searched(let keyword):
                let page = try await AudioLibrary.search(manager, keyword: keyword)
                guard token == generation else { return }
                setSongs(page)
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

    /// 滚到底再要下一页（列表行分页懒加载）。搜索结果不分页 —— 那三路各只取前
    /// `limit` 条，`songs.count` 已经等于 `total`，`hasMore` 自然为假。
    func loadMore(_ manager: SessionManager?) async {
        guard let manager, !isLoading, !isLoadingMore, hasMore else { return }
        if case .searched = mode { return }
        isLoadingMore = true
        let token = generation
        do {
            let page: AudioSongPage
            if case .filtered(let filter) = mode {
                page = try await AudioLibrary.songs(manager, matching: filter, offset: songs.count)
            } else {
                page = try await AudioLibrary.songs(manager, offset: songs.count)
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

    func select(_ dimension: Dimension, on manager: SessionManager?) async {
        self.dimension = dimension
        filter = nil
        searchKeyword = ""
        searchText = ""
        selectedSongID = nil
        clearContent()
        await refresh(manager)
    }

    /// 点艺术家 / 专辑名 / 流派 —— 回到同一张表并代入筛选（原型「曲库 · 已筛选」屏）。
    func apply(_ value: String, on manager: SessionManager?) async {
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
        searchKeyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        filter = nil
        selectedSongID = nil
        clearContent()
        await refresh(manager)
    }

    func select(song: AudioSong) {
        selectedSongID = song.id
    }

    // MARK: 内部

    private func setSongs(_ page: AudioSongPage) {
        songs = page.songs
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

/// 听歌 · 曲库：四维浏览 + 搜索 + 筛选，一张表到底。
///
/// 「点艺术家 / 专辑名」不新开版式 —— 回到同一张表、代入筛选、页头换字。
/// 这是原型「曲库 · 已筛选」那一屏的规矩，也是产品定义里「不新增专辑页 / 艺人页」那条。
struct LibraryView: View {
    @Environment(AppState.self) private var state
    @State private var model = LibraryModel()

    var body: some View {
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
        .background(Color.dmPanel)
        .task { await model.loadIfNeeded(state.sessionManager) }
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
                text: $model.searchText,
                placeholder: "搜索标题、艺术家、专辑"
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
                TrackTable(model: model, manager: state.sessionManager, engine: state.playback)
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

// MARK: - 曲目表

/// 表宽：标题列自适应，其余八列按原型 `colgroup` 的固定宽。
/// （非 private —— 队列行借用 `padH`，两边同一档列内边距。）
enum TrackColumn {
    static let artist: CGFloat = 96
    static let album: CGFloat = 96
    static let genre: CGFloat = 124
    static let year: CGFloat = 56
    static let duration: CGFloat = 48
    static let track: CGFloat = 48
    static let padH: CGFloat = 10
}

/// 表头固定——列表滚多长表头都钉在顶上，所以它放在 `ScrollView` 外面，
/// 不对着滚（原型是 CSS `sticky`）。
private struct TrackTable: View {
    let model: LibraryModel
    let manager: SessionManager?
    let engine: PlaybackEngine?

    var body: some View {
        VStack(spacing: 0) {
            TrackHeader()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.songs) { song in
                        TrackRow(
                            song: song,
                            isSelected: model.selectedSongID == song.id,
                            isPlaying: engine?.currentSong?.id == song.id
                        ) {
                            model.select(song: song)
                        } onPlay: {
                            // 双击 = 从这首起播，当前这张表就是队列（滚到底懒加载
                            // 追加进模型后，下次播放自然带上新页）。
                            model.select(song: song)
                            engine?.play(model.songs, songID: song.id)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TrackHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            cell("标题", width: nil)
            cell("艺术家", width: TrackColumn.artist)
            cell("专辑", width: TrackColumn.album)
            cell("流派", width: TrackColumn.genre)
            cell("年份", width: TrackColumn.year)
            cell("时长", width: TrackColumn.duration, alignment: .trailing)
            cell("曲序", width: TrackColumn.track, alignment: .trailing)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
    }

    @ViewBuilder
    private func cell(_ text: String, width: CGFloat?, alignment: Alignment = .leading) -> some View {
        let label = Text(text)
            .font(.system(size: DmText.t11, weight: .bold))
            .kerning(0.33)
            .foregroundColor(Color.dmInk3)
            .padding(.horizontal, TrackColumn.padH)
            .padding(.vertical, DmSpace.s8)

        if let width {
            label.frame(width: width, alignment: alignment)
        } else {
            label.frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}

/// 一行曲目 —— **列表行（浅底轨）**：选中 `accent-soft` 底 + `accent-2` 字、
/// 次要格 `accent`；悬停 `panel-2` 底 + `ink` 字。正在播的行同浅底、
/// 标题前挂均衡器（与选中靠图标区分）。列与列宽对着原型 `colgroup`。
struct TrackRow: View {
    let song: AudioSong
    let isSelected: Bool
    var isPlaying: Bool = false
    let onSelect: () -> Void
    var onPlay: (() -> Void)?

    @State private var isHovered = false

    /// 底色：选中与正在播共用浅底（同一档），悬停只在两态都没有时抬一档。
    private var showsAccentBackground: Bool { isSelected || isPlaying }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: DmSpace.s8) {
                if isPlaying {
                    EqualizerBars()
                }
                Text(song.title)
                    .font(.system(size: DmText.t13, weight: .medium))
                    .foregroundColor(ListRowState.primaryForeground(isSelected: showsAccentBackground))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, TrackColumn.padH)
            .frame(maxWidth: .infinity, alignment: .leading)

            plain(song.artist, width: TrackColumn.artist)
            plain(song.album, width: TrackColumn.album)
            plain(song.genreTags.joined(separator: " · "), width: TrackColumn.genre)
            dim(song.yearText, width: TrackColumn.year)

            dim(song.durationText, width: TrackColumn.duration, alignment: .trailing)
            dim(song.track.map(String.init) ?? "", width: TrackColumn.track, alignment: .trailing)
        }
        .frame(height: 34)
        .background(ListRowState.background(isSelected: showsAccentBackground, hovered: isHovered && !showsAccentBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2) {
            onPlay?()
        }
    }

    @ViewBuilder
    private func plain(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: DmText.t13))
            .foregroundColor(ListRowState.foreground(isSelected: showsAccentBackground, hovered: isHovered && !showsAccentBackground))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, TrackColumn.padH)
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func dim(_ text: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(text)
            .font(.system(size: DmText.t12))
            .foregroundColor(ListRowState.secondaryForeground(isSelected: showsAccentBackground, hovered: isHovered && !showsAccentBackground))
            .lineLimit(1)
            .monospacedDigit()
            .padding(.horizontal, TrackColumn.padH)
            .frame(width: width, alignment: alignment)
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

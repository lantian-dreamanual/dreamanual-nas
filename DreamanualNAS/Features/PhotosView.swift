import AppKit
import SwiftUI

/// 类型筛选：设计稿工具条左端那三档（全部 / 照片 / 视频），页面级筛选。
enum MediaKind: String, CaseIterable, Identifiable {
    case all, photo, video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .photo: return "照片"
        case .video: return "视频"
        }
    }

    func matches(_ item: PhotosAPI.Item) -> Bool {
        switch self {
        case .all: return true
        case .photo: return !item.isVideo
        case .video: return item.isVideo
        }
    }
}

/// 网格密度。**语义是列数**（7 / 5 / 4），不是最小列宽 —— 用户调它是在说
/// 「一屏想看几张」，窗口变宽时列数保持、块跟着缩放。
enum GridDensity: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var columns: Int {
        switch self {
        case .small: return 7
        case .medium: return 5
        case .large: return 4
        }
    }

    var icon: String {
        switch self {
        case .small: return "grid-3x3"
        case .medium: return "grid-2x2"
        case .large: return "square"
        }
    }

    var label: String {
        switch self {
        case .small: return "小格 · 7 列"
        case .medium: return "中格 · 5 列"
        case .large: return "大格 · 4 列"
        }
    }
}

/// 照片页（批 2 · 浏览维度）。
///
/// 结构照原型：内容区侧栏（二级导航）+ 页头 + 工具条（类型页签 · 密度 · 搜索）
/// + 网格 / 卡片屏。一屏一个维度 —— 时间轴、最近添加、相册、人物、地点、标签，
/// 以及它们的详情页。
///
/// 侧栏不列「收藏」：`Favorite` v2 的 `team_space` 还没实测（规划第六节第 5 条），
/// 按「能力不通就整条不渲染」的口径先不摆假入口。
struct PhotosView: View {
    @Environment(AppState.self) private var state

    private var library: PhotoLibrary { state.photos }
    private var shelf: PhotoShelf { state.photoShelf }
    private var selection: PhotoSelection { state.photoSelection }

    /// 搜索框的字。提交式：回车（或点清除）才发请求。
    @State private var query = ""
    /// 类型筛选（全部 / 照片 / 视频）。**页面级筛选**，只活在这一屏，
    /// 不落盘 —— 下次进照片页回到「全部」。
    @State private var kind: MediaKind = .all
    /// 网格密度（列数 7 / 5 / 4）。纯本地偏好，落 UserDefaults。
    @AppStorage("photos.gridDensity") private var densityRaw = GridDensity.medium.rawValue
    /// 人物详情的头像（页头 36 圆）。
    @State private var avatarImage: NSImage?

    private var density: GridDensity {
        GridDensity(rawValue: densityRaw) ?? .medium
    }

    private var densityBinding: Binding<GridDensity> {
        Binding(get: { density }, set: { densityRaw = $0.rawValue })
    }

    var body: some View {
        HStack(spacing: 0) {
            PhotoRail(library: library, shelf: shelf) { target in
                Task { await shelf.select(target, manager: state.sessionManager) }
            }
            main
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dmPanel)
        .task {
            await library.loadIfNeeded(state.sessionManager)
            await shelf.bootstrap(state.sessionManager)
        }
        // 选择模式的「当前这一屏」= 网格上现在显示的那批。⌘A 与组头三态都读它，
        // 所以每次条目或屏变化都同步一次。
        .onChange(of: currentItems.count) { syncScope() }
        .onChange(of: shelf.route) { syncScope() }
        .onChange(of: kind) { syncScope() }
        .onAppear { syncScope() }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if showsToolbar { toolbar }
            uploadRows
            content
                .overlay { photoDropHighlight }
            if isGridView, selection.isActive { selectionBar }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 拖入热区是整块内容区（规划第四节第 1 条）—— 页头与工具条的空白处也能放；
        // 遮罩只铺网格区，页头不跟着换底色。
        .overlay {
            FileDropCatcher(
                isTargeted: dropTarget,
                onHover: { urls in
                    state.photoDropSummary = urls.isEmpty ? nil : PhotoUpload.summary(urls: urls)
                },
                onDrop: { urls in state.uploadPhotos(urls: urls) }
            )
        }
    }

    // MARK: - 上传

    /// 拖入高亮的状态落在 `uploads` 上（与文件页同一处）—— 冒烟要能摆出来截图，
    /// 视图自己的 `@State` 外面够不着。
    private var dropTarget: Binding<Bool> {
        Binding(get: { state.uploads.dropTargeted },
                set: { state.uploads.dropTargeted = $0 })
    }

    private var uploads: UploadQueue { state.uploads }

    /// 列表上方那一行上传进度（与文件页同一个构件、同一挂法：工具条之下、内容之上）。
    @ViewBuilder
    private var uploadRows: some View {
        if let item = uploads.headline {
            DmUploadRow(
                icon: uploadIcon(item),
                title: uploadTitle(item),
                detail: uploadDetail(item),
                progress: uploadProgress(item),
                tone: uploadTone(item)
            ) {
                uploadActions(item)
            }
            .padding(.horizontal, DmSpace.s24)
            .padding(.bottom, DmSpace.s12)
        }
    }

    /// 拖入遮罩：铺网格区、虚线框内缩 `s8`（与文件页那圈提示同款）。
    ///
    /// 两行字：这一批多少张 + 落点。跨月的一批不写单一路径（那是说谎），写「按拍摄
    /// 时间归类」并给分月计数 —— 用户在松手前就知道会散到几个目录。
    @ViewBuilder
    private var photoDropHighlight: some View {
        if uploads.dropTargeted {
            let summary = state.photoDropSummary ?? PhotoUpload.Summary(count: 0, months: [])
            RoundedRectangle(cornerRadius: DmRadius.r10)
                .fill(Color.dmAccentSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: DmRadius.r10)
                        .strokeBorder(
                            Color.dmAccent2,
                            style: StrokeStyle(lineWidth: DmLine.base,
                                               dash: [DmSpace.s6, DmSpace.s4])
                        )
                )
                .overlay {
                    VStack(spacing: DmSpace.s6) {
                        Text(summary.headline)
                            .font(.system(size: DmText.t13, weight: .medium))
                            .foregroundColor(Color.dmAccent2)
                        if !summary.detail.isEmpty {
                            Text(summary.detail)
                                .font(.system(size: DmText.t11))
                                .foregroundColor(Color.dmAccent2.opacity(0.8))
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(DmSpace.s16)
                }
                .padding(DmSpace.s8)
                .allowsHitTesting(false)
        }
    }

    private func uploadIcon(_ item: UploadQueue.Item) -> String {
        if case .failed = item.state { return "circle-x" }
        return "upload"
    }

    private func uploadTone(_ item: UploadQueue.Item) -> DmUploadTone {
        if case .failed = item.state { return .danger }
        return .normal
    }

    private func uploadTitle(_ item: UploadQueue.Item) -> String {
        switch item.state {
        case .failed: return "上传失败 \(item.name)"
        case .waiting: return "等待上传 \(item.name)"
        default: return "正在上传 \(item.name)"
        }
    }

    /// 明细只讲进度（落点已经在遮罩上讲过了）。
    private func uploadDetail(_ item: UploadQueue.Item) -> String {
        var parts: [String] = []
        if case .failed(let reason) = item.state {
            parts.append(reason)
            if item.sent > 0 { parts.append("已传 \(FileEntry.byteText(item.sent)) 不会保留") }
        } else {
            if item.rate > 0 { parts.append("\(FileEntry.byteText(Int64(item.rate)))/s") }
            let total = item.expected > 0 ? item.expected : item.byteCount
            parts.append("已传 \(FileEntry.byteText(item.sent)) / \(FileEntry.byteText(total))")
            if item.rate > 0, total > item.sent {
                let seconds = Double(total - item.sent) / item.rate
                if seconds >= 60 {
                    parts.append("剩余约 \(Int((seconds / 60).rounded())) 分")
                } else if seconds >= 1 {
                    parts.append("剩余约 \(Int(seconds.rounded())) 秒")
                }
            }
        }
        if uploads.queuedCount > 0 { parts.append("队列还有 \(uploads.queuedCount) 张") }
        return parts.joined(separator: " · ")
    }

    private func uploadProgress(_ item: UploadQueue.Item) -> Double? {
        if case .failed = item.state { return nil }
        let total = item.expected > 0 ? item.expected : item.byteCount
        guard total > 0 else { return nil }
        return Double(item.sent) / Double(total)
    }

    @ViewBuilder
    private func uploadActions(_ item: UploadQueue.Item) -> some View {
        if case .failed = item.state {
            HStack(spacing: DmSpace.s8) {
                Button("重试") {
                    guard let manager = state.sessionManager else { return }
                    uploads.retry(manager: manager)
                }
                .buttonStyle(SecondaryButtonStyle())
                IconButton(iconName: "x", label: "移除") { uploads.dropFailed() }
            }
        } else {
            Button("取消") { state.cancelUploads() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    // MARK: - 选择模式

    /// 这一屏可选的条目。卡片屏（人物 / 地点 / 标签 / 相册列表）为空 —— 那些屏
    /// 没有多选。
    private var currentItems: [PhotosAPI.Item] {
        let source: [PhotosAPI.Item]
        if shelf.isSearching {
            source = shelf.searchItems
        } else {
            switch shelf.route {
            case .timeline: source = library.loadedItems
            case .recent, .person, .place, .tag, .album: source = shelf.items
            default: source = []
            }
        }
        return kindFiltered(source)
    }

    // MARK: - 类型筛选

    /// 类型筛选。**纯本地** —— 全量条目已经在内存里（`PhotoLibrary` 全量翻页取回），
    /// 按条目自带的 `type` 筛一次是微秒级，不必碰服务端的 `filter_*` 一族
    /// （那组参数没实测过，而这里根本没有必须依赖它的理由）。
    private func kindFiltered(_ items: [PhotosAPI.Item]) -> [PhotosAPI.Item] {
        guard kind != .all else { return items }
        return items.filter { kind.matches($0) }
    }

    /// 按天分组后再筛：筛空的那一天整组去掉（不留一个「0 张」的日期行）。
    private func kindFilteredGroups(
        _ groups: [(day: PhotosAPI.Day, items: [PhotosAPI.Item])]
    ) -> [(day: PhotosAPI.Day, items: [PhotosAPI.Item])] {
        guard kind != .all else { return groups }
        return groups.compactMap { group in
            let kept = group.items.filter { kind.matches($0) }
            return kept.isEmpty ? nil : (day: group.day, items: kept)
        }
    }

    /// 筛完一张不剩时的空态。设计给的是「视频」那一版的文案，照片档同构替换。
    /// 触发条件是「这一屏本来有内容、只是被筛掉了」—— 库里真没东西走另一套空态。
    private func filterEmptyNotice(total: Int) -> some View {
        PhotosNotice(icon: "filter", title: "没有匹配的\(kind.title)",
                     note: "共享空间这 \(Self.grouped(total)) 张里没有\(kind.title)文件。切回「全部」可以看到全部内容。",
                     actionTitle: "查看全部") {
            kind = .all
        }
    }

    private var isGridView: Bool {
        shelf.isSearching || (shelf.route.isGrid)
    }

    /// 正在看的相册 id（详情页右键时「添加到相册」换「移出相册」）。
    private var currentAlbumID: Int? {
        if case .album(let id) = shelf.route { return id }
        return nil
    }

    /// 正在看的人物 id（详情页右键多一条「从这个人物移除」）。
    private var currentPersonID: Int? {
        if case .person(let id) = shelf.route { return id }
        return nil
    }

    /// 选中项按当前屏的顺序排（下载 / 删除的批次顺序稳定，日志也读得懂）。
    private var selectedItems: [PhotosAPI.Item] {
        currentItems.filter { selection.contains($0.id) }
    }

    private func syncScope() {
        selection.scope = currentItems
    }

    /// 贴底多选操作条：高 48、`panel-2` 底、上方发丝，左计数右动作，动作走紧凑档。
    /// 删除排最右 —— 危险动作离手最远。
    private var selectionBar: some View {
        HStack(spacing: DmSpace.s8) {
            Text("已选 \(selection.count) 张")
                .font(.system(size: DmText.t12, weight: .medium))
                .foregroundColor(Color.dmInk2)
                .monospacedDigit()
            Spacer(minLength: DmSpace.s8)

            if let albumID = currentAlbumID {
                Button("移出相册") {
                    let items = selectedItems
                    Task { await state.removePhotos(items, from: albumID) }
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("添加到相册") {
                    state.openPhotoDialog(.addToAlbum(selectedItems))
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Button("取消") { selection.clear() }
                .buttonStyle(SecondaryButtonStyle())
            Button("删除") {
                state.openPhotoDialog(.delete(selectedItems))
            }
            .buttonStyle(DangerButtonStyle(compact: true))
            .disabled(selectedItems.isEmpty)
        }
        .padding(.horizontal, DmSpace.s24)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .background(Color.dmPanel2)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.base)
        }
    }

    // MARK: - 页头

    @ViewBuilder
    private var head: some View {
        if shelf.isSearching {
            // 搜索是一次临时的浏览：标题说「搜索结果」，副行报词与条数。侧栏
            // 高亮留在出发的那一行（搜索没有自己的行），再点一次侧栏即退出搜索。
            DmPageHead("搜索结果",
                       subtitle: searchSubtitle) { EmptyView() }
        } else {
            switch shelf.route {
            case .timeline:
                DmPageHead("时间轴", subtitle: timelineSubtitle) {
                    // 拖入是隐式入口，页头得有一枚显式的（与人物页的「刷新」同档）。
                    Button("上传照片") { state.pickAndUploadPhotos() }
                        .buttonStyle(SecondaryButtonStyle())
                    // 手动重读（与曲库、文件管理同一枚钮同一个位置）。刷新期间不换
                    // 内容、不转圈 —— 与那两页一致，只把钮按下去。侧栏那些计数一起更新，
                    // 否则每页都刷新了、左边还挂着旧数字。
                    IconButton(iconName: "refresh-cw", label: "刷新照片") {
                        Task {
                            await shelf.reload(state.sessionManager)
                            await library.load(state.sessionManager, force: true)
                        }
                    }
                    .disabled(library.isRefreshing)
                }
            case .recent:
                DmPageHead("最近添加", subtitle: recentSubtitle) { EmptyView() }
            case .people:
                DmPageHead("人物", subtitle: peopleSubtitle) {
                    Button("刷新") {
                        Task { await shelf.reload(state.sessionManager) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            case .person(let id):
                DmPageHead(shelf.person?.displayName ?? "人物",
                           subtitle: detailSubtitle(shelf.person?.itemCount),
                           onBack: { goBack() },
                           avatar: avatarImage) {
                    if let person = shelf.person {
                        // 主钮：未确认是「命名」（主行动作），已命名退居「改名」。
                        // ⋯ 与人物卡右键同一份动作（改名 / 归并到…）。
                        Button(person.isNamed ? "改名" : "命名") {
                            state.openPhotoDialog(.renamePerson(person))
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        PersonOverflowButton { point in
                            state.openPersonMenu(person, at: point)
                        }
                    }
                }
                .task(id: id) { await loadPersonAvatar() }
            case .places:
                DmPageHead("地点", subtitle: placesSubtitle) { EmptyView() }
            case .place:
                DmPageHead(shelf.place?.name ?? "地点",
                           subtitle: detailSubtitle(shelf.place?.itemCount),
                           onBack: { goBack() }) { EmptyView() }
            case .placeCity(let city):
                DmPageHead(city,
                           subtitle: detailSubtitle(shelf.items.count),
                           onBack: { goBack() }) { EmptyView() }
            case .tags:
                DmPageHead("标签", subtitle: tagsSubtitle) { EmptyView() }
            case .tag:
                DmPageHead(shelf.tag?.name ?? "标签",
                           subtitle: detailSubtitle(shelf.tag?.itemCount),
                           onBack: { goBack() }) { EmptyView() }
            case .albums:
                DmPageHead("相册", subtitle: albumsSubtitle) {
                    Button("新建相册") { state.openPhotoDialog(.newAlbum) }
                        .buttonStyle(PrimaryButtonStyle())
                }
            case .album:
                DmPageHead(shelf.album?.name ?? "相册",
                           subtitle: detailSubtitle(shelf.album?.itemCount),
                           onBack: { goBack() }) {
                    if let album = shelf.album {
                        // 页头的 ⋯ 与相册卡右键是同一份动作（改名 / 删除相册）。
                        AlbumOverflowButton { point in
                            state.openAlbumMenu(album, at: point)
                        }
                    }
                }
            }
        }
    }

    private var searchSubtitle: String {
        switch shelf.searchPhase {
        case .loading: return "正在搜索「\(shelf.keyword)」…"
        case .failed(let reason): return "「\(shelf.keyword)」· \(reason)"
        default:
            let total = shelf.searchItems.count
            return total > 0
                ? "「\(shelf.keyword)」· \(Self.grouped(total)) 张 · 共享空间"
                : "「\(shelf.keyword)」· 共享空间"
        }
    }

    /// 详情页的副行：`共享空间 · 1235 张`。
    private func detailSubtitle(_ count: Int?) -> String {
        guard let count else { return "共享空间" }
        return "共享空间 · \(Self.grouped(count)) 张"
    }

    private var timelineSubtitle: String {
        switch library.phase {
        case .loading:
            return library.loadedCount > 0
                ? "正在读取共享空间…已取 \(library.loadedCount) 张"
                : "正在读取共享空间…"
        case .idle:
            return "正在读取共享空间…"
        case .failed:
            return "共享空间"
        case .ready:
            let total = library.totalCount
            return total > 0 ? "\(Self.grouped(total)) 张 · 共享空间" : "共享空间"
        }
    }

    private var recentSubtitle: String {
        switch shelf.phase {
        case .loading: return "正在读取…"
        case .failed: return "共享空间"
        default:
            let total = shelf.recentItems.count
            // 窗口是服务端的滑动窗口（最近 30 天进库），必须写出来 —— 找不到老照片
            // 时用户要能看懂为什么（规划第二节末）。
            return total > 0
                ? "\(Self.grouped(total)) 张 · 最近 30 天添加 · 共享空间"
                : "最近 30 天添加 · 共享空间"
        }
    }

    private var peopleSubtitle: String {
        let named = shelf.people.filter { $0.isNamed }.count
        let pending = shelf.people.count - named
        guard shelf.people.count > 0 else { return "共享空间 · 人物由 NAS 自动识别" }
        return "共享空间 · \(shelf.people.count) 个人物 · \(named) 已命名 · \(pending) 未确认"
    }

    private var placesSubtitle: String {
        shelf.places.isEmpty
            ? "共享空间 · 按拍摄地点归类"
            : "共享空间 · \(shelf.places.count) 个地点 · 按市分组，可搜乡镇 / 县市 / 省"
    }

    private var tagsSubtitle: String {
        shelf.tags.isEmpty
            ? "共享空间"
            : "共享空间 · \(shelf.tags.count) 个标签 · 按张数从多到少"
    }

    private var albumsSubtitle: String {
        shelf.albums.isEmpty
            ? "共享空间"
            : "共享空间 · \(shelf.albums.count) 个相册"
    }

    /// 千位空格分组（`17 350`），与侧栏计数同一口径。
    private static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var out = ""
        for (index, char) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(" ") }
            out.append(char)
        }
        return out
    }

    // MARK: - 工具条

    /// 网格屏（含各类详情页）都带工具条：左边类型页签，右端密度三档 + 搜索。
    /// 卡片屏（人物 / 地点 / 标签 / 相册列表）没有 —— 那些屏是卡片与列表，不排网格。
    private var showsToolbar: Bool {
        shelf.route.isGrid
    }

    private var toolbar: some View {
        HStack(spacing: DmSpace.s20) {
            // 类型筛选是**页面级**筛选，走文本页签（无容器、20×3 指示条）；
            // 密度是控件，走容器分段。两者型不同，位置也不同端。
            DmTextTabs(MediaKind.allCases, selection: $kind) { $0.title }
            Spacer(minLength: 0)
            DmIconSegmented(GridDensity.allCases, selection: densityBinding,
                            icon: { $0.icon }, label: { $0.label })
            // 提交式：虽然本地筛是瞬时的，输入即筛会让网格边打字边跳，回车更稳。
            DmSearchField(
                text: $query,
                placeholder: "搜索文件名",
                onSubmit: {
                    Task {
                        await shelf.submitSearch(query, in: library.loadedItems,
                                                 manager: state.sessionManager)
                    }
                }
            )
            .frame(width: 200)
        }
        .padding(.horizontal, DmSpace.s24)
        .padding(.bottom, DmSpace.s10)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if shelf.isSearching {
            searchContent
        } else {
            switch shelf.route {
            case .timeline:
                timelineContent
            case .recent:
                shelfGrid(shelf.items, phase: shelf.phase)
            case .people:
                peopleContent
            case .places:
                placesContent
            case .tags:
                tagsContent
            case .albums:
                albumsContent
            case .person, .place, .placeCity, .tag, .album:
                shelfGrid(shelf.items, phase: shelf.phase)
            }
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        switch library.phase {
        case .idle, .loading:
            PhotosNotice(icon: "loader", title: "正在读取照片…")
        case .failed(let reason):
            PhotosNotice(icon: "circle-x", title: "无法读取照片", note: reason,
                         actionTitle: "重试") {
                Task { await library.load(state.sessionManager, force: true) }
            }
        case .ready:
            if library.days.isEmpty {
                PhotosNotice(icon: "image", title: "还没有照片",
                             note: "照片放进 NAS 的照片库后，这里会自动出现。",
                             actionTitle: "上传照片") {
                    state.pickAndUploadPhotos()
                }
            } else {
                let groups = kindFilteredGroups(library.days.map {
                    (day: $0, items: library.items[$0.id] ?? [])
                })
                if groups.isEmpty {
                    filterEmptyNotice(total: library.totalCount)
                } else {
                    PhotoDayGrid(
                        groups: groups,
                        sequence: groups.flatMap { $0.items },
                        density: density,
                        countNote: nil,
                        albumID: nil,
                        personID: nil,
                        onOpen: { item, sequence in library.openViewer(item, in: sequence) },
                        onContext: { item, point, targets in
                            state.openPhotoMenu(item, at: point, targets: targets,
                                                albumID: nil, personID: nil)
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        switch shelf.searchPhase {
        case .loading:
            PhotosNotice(icon: "loader", title: "正在搜索…")
        case .failed(let reason):
            PhotosNotice(icon: "circle-x", title: "搜索没有完成", note: reason,
                         actionTitle: "重试") {
                Task {
                    await shelf.submitSearch(shelf.keyword, in: library.loadedItems,
                                             manager: state.sessionManager)
                }
            }
        case .idle, .ready:
            if shelf.searchItems.isEmpty {
                PhotosNotice(icon: "search", title: "没有找到「\(shelf.keyword)」",
                             note: "换一个文件名里的词试试。")
            } else {
                let groups = kindFilteredGroups(shelf.groups(for: kindFiltered(shelf.searchItems)))
                if groups.isEmpty {
                    filterEmptyNotice(total: shelf.searchItems.count)
                } else {
                    PhotoDayGrid(
                        groups: groups,
                        sequence: groups.flatMap { $0.items },
                        density: density,
                        countNote: nil,
                        albumID: nil,
                        personID: nil,
                        onOpen: { item, sequence in library.openViewer(item, in: sequence) },
                        onContext: { item, point, targets in
                            state.openPhotoMenu(item, at: point, targets: targets,
                                                albumID: nil, personID: nil)
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func shelfGrid(_ items: [PhotosAPI.Item], phase: PhotoShelf.Phase) -> some View {
        switch phase {
        case .idle, .loading:
            PhotosNotice(icon: "loader", title: "正在读取…")
        case .failed(let reason):
            PhotosNotice(icon: "circle-x", title: "无法读取这一屏", note: reason,
                         actionTitle: "重试") {
                Task { await shelf.reload(state.sessionManager) }
            }
        case .ready:
            if items.isEmpty {
                PhotosNotice(icon: "image", title: "这里还没有照片")
            } else {
                let groups = kindFilteredGroups(shelf.groups(for: kindFiltered(items)))
                if groups.isEmpty {
                    filterEmptyNotice(total: items.count)
                } else {
                    PhotoDayGrid(
                        groups: groups,
                        sequence: groups.flatMap { $0.items },
                        density: density,
                        countNote: shelf.groupsByIndexed ? "进库" : nil,
                        albumID: currentAlbumID,
                        personID: currentPersonID,
                        onOpen: { item, sequence in library.openViewer(item, in: sequence) },
                        onContext: { item, point, targets in
                            state.openPhotoMenu(item, at: point, targets: targets,
                                                albumID: currentAlbumID,
                                                personID: currentPersonID)
                        }
                    )
                }
            }
        }
    }

    // MARK: - 人物

    private var peopleContent: some View {
        Group {
            if shelf.people.isEmpty {
                PhotosNotice(icon: "users", title: "还没有识别到人物",
                             note: "人物由 NAS 自动识别，识别出结果后会出现在这里。")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120),
                                                 spacing: DmSpace.s16)],
                              spacing: DmSpace.s16) {
                        ForEach(shelf.people.filter { $0.isNamed }) { person in
                            PersonCard(person: person, library: library,
                                       manager: state.sessionManager,
                                       onContext: { point in
                                           state.openPersonMenu(person, at: point)
                                       }) {
                                Task { await shelf.select(.person(person.id),
                                                          manager: state.sessionManager) }
                            }
                        }
                    }
                    .padding(.horizontal, DmSpace.s24)

                    if !shelf.people.filter({ !$0.isNamed }).isEmpty {
                        sectionTitle("未确认", count: shelf.people.filter { !$0.isNamed }.count)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120),
                                                     spacing: DmSpace.s16)],
                                  spacing: DmSpace.s16) {
                            ForEach(shelf.people.filter { !$0.isNamed }) { person in
                                PersonCard(person: person, library: library,
                                           manager: state.sessionManager,
                                           onContext: { point in
                                               state.openPersonMenu(person, at: point)
                                           }) {
                                    Task { await shelf.select(.person(person.id),
                                                              manager: state.sessionManager) }
                                }
                            }
                        }
                        .padding(.horizontal, DmSpace.s24)
                    }
                }
                .padding(.bottom, DmSpace.s24)
            }
        }
    }

    /// 卡片屏里的分组标题（人物两段）。与日期分组同一副字，只是不带张数。
    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: DmSpace.s8) {
            Text(title)
                .font(.system(size: DmText.t13, weight: .semibold))
                .foregroundColor(Color.dmInk2)
            Spacer(minLength: 0)
            Text("\(count) 个")
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(Color.dmInk3)
        }
        .padding(.horizontal, DmSpace.s24)
        .padding(.top, DmSpace.s20)
        .padding(.bottom, DmSpace.s8)
    }

    // MARK: - 地点 / 标签

    /// 地点屏：搜索框 + 按市分组。搜索词即时筛（本地 291 条），命中的是乡镇 /
    /// 县区 / 市 / 省 —— 「衢州」能把龙游县下全部乡镇带出来（`ChinaDivisions`）。
    /// 搜索态平铺结果；非搜索态按市分组，组头可点「看全部」聚合该市照片。
    private var placesContent: some View {
        Group {
            if shelf.places.isEmpty {
                PhotosNotice(icon: "circle-x", title: "还没有地点信息",
                             note: "照片带 GPS 时 NAS 会按拍摄地归类。")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        DmSearchField(text: Binding(
                            get: { shelf.placeQuery },
                            set: { shelf.setPlaceQuery($0) }
                        ), placeholder: "搜乡镇 / 县市 / 省")
                        .frame(width: 280)
                        .padding(.horizontal, DmSpace.s24)
                        .padding(.top, DmSpace.s8)
                        .padding(.bottom, DmSpace.s12)

                        if shelf.placeQuery.isEmpty {
                            placeGroups
                        } else {
                            placeSearchResults
                        }
                    }
                    .padding(.bottom, DmSpace.s24)
                }
            }
        }
    }

    @ViewBuilder
    private var placeGroups: some View {
        if shelf.placeGroups.isEmpty {
            PhotosNotice(icon: "circle-x", title: "没有地点信息",
                         note: "照片带 GPS 时 NAS 会按拍摄地归类。")
        } else {
            ForEach(shelf.placeGroups) { group in
                PlaceGroupHead(title: group.title, count: group.total) {
                    Task { await shelf.select(.placeCity(group.city),
                                              manager: state.sessionManager) }
                }
                VStack(spacing: DmSpace.s2) {
                    ForEach(group.places) { place in
                        CardListRowView(row: CardListRow(
                            id: place.id, icon: "map-pin", title: place.name,
                            count: place.itemCount
                        )) {
                            Task { await shelf.select(.place(place.id),
                                                      manager: state.sessionManager) }
                        }
                    }
                }
                .padding(.horizontal, DmSpace.s24)
            }
        }
    }

    @ViewBuilder
    private var placeSearchResults: some View {
        let hits = shelf.matchedPlaces
        if hits.isEmpty {
            PhotosNotice(icon: "search", title: "没有匹配「\(shelf.placeQuery)」的地点",
                         note: "搜的是乡镇、县市与省名，比如「衢州」「龙游」。")
        } else {
            VStack(spacing: DmSpace.s2) {
                ForEach(hits) { place in
                    CardListRowView(row: CardListRow(
                        id: place.id, icon: "map-pin", title: place.name,
                        count: place.itemCount, note: place.city
                    )) {
                        Task { await shelf.select(.place(place.id),
                                                  manager: state.sessionManager) }
                    }
                }
            }
            .padding(.horizontal, DmSpace.s24)
        }
    }

    private var tagsContent: some View {
        cardList(
            isEmpty: shelf.tags.isEmpty,
            emptyTitle: "还没有标签",
            emptyNote: "在群晖 Photos 里给照片打标签后，这里会按标签归类。",
            rows: shelf.tags.map {
                CardListRow(id: $0.id, icon: "tag", title: $0.name, count: $0.itemCount)
            },
            onSelect: { id in
                Task { await shelf.select(.tag(id), manager: state.sessionManager) }
            }
        )
    }

    private func cardList(isEmpty: Bool, emptyTitle: String, emptyNote: String,
                          rows: [CardListRow], onSelect: @escaping (Int) -> Void) -> some View {
        Group {
            if isEmpty {
                PhotosNotice(icon: "circle-x", title: emptyTitle, note: emptyNote)
            } else {
                ScrollView {
                    VStack(spacing: DmSpace.s2) {
                        ForEach(rows) { row in
                            CardListRowView(row: row) { onSelect(row.id) }
                        }
                    }
                    .padding(.horizontal, DmSpace.s24)
                    .padding(.top, DmSpace.s8)
                }
                .padding(.bottom, DmSpace.s24)
            }
        }
    }

    // MARK: - 相册

    private var albumsContent: some View {
        Group {
            if shelf.albums.isEmpty {
                PhotosNotice(icon: "images", title: "还没有相册",
                             note: "相册在群晖 Photos 的共享空间里创建。")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 220),
                                                 spacing: DmSpace.s16)],
                              spacing: DmSpace.s16) {
                        ForEach(shelf.albums) { album in
                            AlbumCard(album: album,
                                      cover: shelf.albumCovers[album.id],
                                      library: library,
                                      manager: state.sessionManager,
                                      onOpen: {
                                          Task { await shelf.select(.album(album.id),
                                                                    manager: state.sessionManager) }
                                      },
                                      onContext: { point in
                                          state.openAlbumMenu(album, at: point)
                                      })
                        }
                    }
                    .padding(.horizontal, DmSpace.s24)
                    .padding(.top, DmSpace.s8)
                }
                .padding(.bottom, DmSpace.s24)
            }
        }
    }

    // MARK: - 人物详情的头像

    private func loadPersonAvatar() async {
        avatarImage = nil
        guard let person = shelf.person else { return }
        guard let data = await library.coverImage(
            key: "p:\(person.id)", unitID: person.coverUnitID,
            cacheKey: person.coverKey, manager: state.sessionManager) else { return }
        avatarImage = NSImage(data: data)
    }

    private func goBack() {
        guard let parent = shelf.route.parent else { return }
        Task { await shelf.select(parent, manager: state.sessionManager) }
    }
}

// MARK: - 内容区侧栏

/// 照片模块的二级导航：一屏一个维度，两个分类组之间 `s8` 断开。
///
/// 与曲库的内容区侧栏同一形态（原型 `.rail` / `.rail-row`）：选中 `panel-3` 底 +
/// `ink` 字 + 600、计数转 `ink`；主色完全不进来。详情页高亮父级那一行。
private struct PhotoRail: View {
    let library: PhotoLibrary
    let shelf: PhotoShelf
    let onSelect: (PhotoShelf.Route) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("共享空间").railHead()

            ScrollView {
                VStack(alignment: .leading, spacing: DmSpace.s2) {
                    PhotoRailRow(icon: "calendar-days", title: "时间轴",
                                 count: library.totalCount,
                                 isSelected: shelf.route == .timeline) {
                        onSelect(.timeline)
                    }
                    PhotoRailRow(icon: "history", title: "最近添加",
                                 count: shelf.recentItems.count,
                                 isSelected: shelf.route == .recent) {
                        onSelect(.recent)
                    }
                    PhotoRailRow(icon: "images", title: "相册",
                                 count: shelf.albums.count,
                                 isSelected: shelf.route == .albums || isAlbumDetail) {
                        onSelect(.albums)
                    }

                    // 分类三项在服务端是两套接口（FotoTeam 与 Foto），各算各的库，
                    // 所以并进空间组内、组内隔 8px，不做顶层「智能分类」。
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: DmSpace.s8)

                    PhotoRailRow(icon: "users", title: "人物",
                                 count: shelf.people.count,
                                 isSelected: shelf.route == .people || isPersonDetail) {
                        onSelect(.people)
                    }
                    PhotoRailRow(icon: "map-pin", title: "地点",
                                 count: shelf.places.count,
                                 isSelected: shelf.route == .places || isPlaceDetail) {
                        onSelect(.places)
                    }
                    PhotoRailRow(icon: "tag", title: "标签",
                                 count: shelf.tags.count,
                                 isSelected: shelf.route == .tags || isTagDetail) {
                        onSelect(.tags)
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

    private var isPersonDetail: Bool {
        if case .person = shelf.route { return true }
        return false
    }

    private var isPlaceDetail: Bool {
        if case .place = shelf.route { return true }
        if case .placeCity = shelf.route { return true }
        return false
    }

    private var isTagDetail: Bool {
        if case .tag = shelf.route { return true }
        return false
    }

    private var isAlbumDetail: Bool {
        if case .album = shelf.route { return true }
        return false
    }
}

private extension Text {
    /// 侧栏分组标题：11 / 700 / 字距 0.06em / `ink-3`，上 14 下 8。
    func railHead() -> some View {
        self.font(.system(size: DmText.t11, weight: .bold))
            .kerning(0.66)
            .foregroundColor(Color.dmInk3)
            .padding(.horizontal, DmSpace.s16)
            .padding(.top, DmSpace.s14)
            .padding(.bottom, DmSpace.s8)
    }
}

/// 侧栏一行：图标 14 / 字 13 / 计数 11，横向 8、纵向 6 —— 照原型 `.rail-row`。
private struct PhotoRailRow: View {
    let icon: String
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon(icon, size: DmIcon.i14)
                .foregroundColor(RailRowState.secondaryForeground(isSelected: isSelected,
                                                                  hovered: isHovered))
            Text(title)
                .font(.system(size: DmText.t13))
                .foregroundColor(RailRowState.foreground(isSelected: isSelected,
                                                         hovered: isHovered))
            Spacer(minLength: DmSpace.s4)
            Text("\(count)")
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(RailRowState.secondaryForeground(isSelected: isSelected,
                                                                  hovered: isHovered))
        }
        .padding(.horizontal, DmSpace.s8)
        .padding(.vertical, DmSpace.s6)
        .background(RailRowState.background(isSelected: isSelected,
                                            hovered: isHovered && !isSelected))
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r6))
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 日期分组网格

/// 按天分组的缩略图网格。时间轴、最近添加、搜索、人物 / 地点 / 标签 / 相册详情
/// 共用这一副骨架 —— 差异只在「条目从哪来」与分组用哪个时间字段。
///
/// `sequence` 是查看器翻页的那一条线：**整屏的条目**，不是当前这一天。在这一屏
/// 点开一张，往右翻应该翻到这一屏的下一张（跨天继续），不是翻回全库。
private struct PhotoDayGrid: View {
    let groups: [(day: PhotosAPI.Day, items: [PhotosAPI.Item])]
    let sequence: [PhotosAPI.Item]
    /// 网格密度。**语义是列数**（7 / 5 / 4），不是最小列宽 —— 窗口变宽列数不变、
    /// 块跟着缩放（规范第八节「照片块」）。
    let density: GridDensity
    /// 分组头右侧的补充说明：最近添加写「进库」。
    let countNote: String?
    /// 正在看的相册（详情页右键换「移出相册」）。
    let albumID: Int?
    /// 正在看的人物（详情页右键多「从这个人物移除」）。
    let personID: Int?
    let onOpen: (PhotosAPI.Item, [PhotosAPI.Item]) -> Void
    let onContext: (PhotosAPI.Item, CGPoint, [PhotosAPI.Item]) -> Void

    @Environment(AppState.self) private var state

    private var selection: PhotoSelection { state.photoSelection }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.day.id) { group in
                        Section {
                            grid(group.items, width: geo.size.width)
                        } header: {
                            header(group.day, items: group.items)
                        }
                    }
                }
                .padding(.bottom, DmSpace.s24)
            }
        }
    }

    /// 固定列宽的列定义：可用宽减去左右 24 与外间距，再按列数等分。
    /// 不用 `.adaptive(minimum:)` —— 那样档位会随窗口漂移，标称列数与实际列数对不上。
    private func columns(width: CGFloat) -> [GridItem] {
        let count = density.columns
        let spacing = DmSpace.s6
        let usable = width - DmSpace.s24 * 2 - spacing * CGFloat(count - 1)
        let side = max(floor(usable / CGFloat(count)), 1)
        return Array(repeating: GridItem(.fixed(side), spacing: spacing), count: count)
    }

    private func grid(_ items: [PhotosAPI.Item], width: CGFloat) -> some View {
        LazyVGrid(columns: columns(width: width), spacing: DmSpace.s6) {
            ForEach(items) { item in
                PhotoCell(
                    item: item,
                    isSelected: selection.contains(item.id),
                    isSelecting: selection.isActive,
                    onTap: {
                        if selection.isActive {
                            selection.tap(item)
                        } else {
                            onOpen(item, sequence)
                        }
                    },
                    onContext: { point in
                        // 右键落在没选中过的图上 = 只对这张动手（与访达一致）；
                        // 落在已选中的图上 = 对整批动手。
                        if !selection.contains(item.id) {
                            selection.clear()
                        }
                        let targets = selection.contains(item.id) ? selectedInScreen()
                            : [item]
                        onContext(item, point, targets)
                    }
                )
            }
        }
        .padding(.horizontal, DmSpace.s24)
        // 定宽列之和可能比可用宽少不到 1px（floor 的余数），不吸满会被整行居中。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 当前屏里选中的那批（右键菜单的 targets）。
    private func selectedInScreen() -> [PhotosAPI.Item] {
        sequence.filter { selection.contains($0.id) }
    }

    /// 日期行。选择模式下最左多一枚三态全选位（占 22px、日期让位）。
    private func header(_ day: PhotosAPI.Day, items: [PhotosAPI.Item]) -> some View {
        let state = selection.state(of: items)
        return HStack(spacing: DmSpace.s8) {
            if selection.isActive {
                DmCheckbox(isOn: state.all, isIndeterminate: state.some)
                    .frame(width: 22, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { selection.toggle(group: items) }
                    .help(state.all ? "不选这一天" : "选中这一天")
            }
            Text(day.title)
                .font(.system(size: DmText.t13, weight: .semibold))
                .foregroundColor(Color.dmInk2)
            Spacer(minLength: 0)
            Text(countNote.map { "\(items.count) 张 · \($0)" } ?? "\(items.count) 张")
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(Color.dmInk3)
        }
        .padding(.horizontal, DmSpace.s24)
        .padding(.top, DmSpace.s20)
        .padding(.bottom, DmSpace.s8)
        // 吸顶时不透：底一定要铺，否则下面的缩略图会从字缝里穿过去。
        .background(Color.dmPanel)
    }
}

// MARK: - 单元格

private struct PhotoCell: View {
    let item: PhotosAPI.Item
    let isSelected: Bool
    let isSelecting: Bool
    let onTap: () -> Void
    let onContext: (CGPoint) -> Void

    @Environment(AppState.self) private var state
    @State private var image: NSImage?
    @State private var failed = false
    @State private var isHovered = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            // 图片挂 overlay：`scaledToFill` 一旦参与布局就会按自身比例把格子撑宽，
            // 把整行网格顶穿（真机踩过）—— overlay 不参与布局，格子尺寸只由这里定。
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: DmRadius.r8)
                        .fill(Color.dmPanel2)

                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else if failed {
                        LucideIcon("image-off", size: DmIcon.i16)
                            .foregroundColor(Color.dmInk3)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DmRadius.r8))
            // 悬停压暗 10%。**选中后悬停不再压暗**（产品线没有「选中 + 悬停」态），
            // 选择模式下也不压 —— 那时的点击是勾选，压暗会让人以为是要打开。
            .overlay {
                if isHovered && !isSelected && !isSelecting {
                    RoundedRectangle(cornerRadius: DmRadius.r8)
                        .fill(Color.black.opacity(0.1))
                }
            }
            // 选中：双层内描边 —— 内 2px 主色认「已选」，外 1px 半透明黑保证雪景白墙
            // 这类浅底图上边界也在（浅底轨与压暗都被图盖住，用不了）。
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: DmRadius.r8)
                        .strokeBorder(Color.dmAccentFill, lineWidth: DmLine.sel)
                    RoundedRectangle(cornerRadius: DmRadius.r8)
                        .inset(by: -1)
                        .stroke(Color.black.opacity(0.45), lineWidth: DmLine.base)
                }
            }
            .overlay(alignment: .topLeading) {
                // 选择模式下浮在照片上的勾选框：底半透明黑 + 白 45% 描边，
                // 任何明暗的图上都看得见（坐在 panel 底上的那套在这里不够）。
                if isSelecting {
                    DmCheckbox(isOn: isSelected)
                        .padding(DmSpace.s6)
                        .background(
                            RoundedRectangle(cornerRadius: DmRadius.r4)
                                .fill(Color.black.opacity(0.55))
                                .padding(DmSpace.s4)
                        )
                        .padding(DmSpace.s2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    // 视频角标：播放语义用面性（与播放键同一口径），白色压深底。
                    LucideIcon("play", size: DmIcon.i12, filled: true)
                        .foregroundColor(.white)
                        .padding(DmSpace.s4)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(DmSpace.s6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DmRadius.r8))
            .trackingHover($isHovered)
            .onTapGesture(perform: onTap)
            .overlay { RightClickCatcher(onRightClick: onContext) }
            .help(item.filename)
            .accessibilityElement()
            .accessibilityLabel(item.isVideo ? "\(item.filename)，视频" : item.filename)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "打开") { onTap() }
            .task(id: ThumbRequest(itemID: item.id, revision: state.photos.thumbRevision)) {
                if let data = await state.photos.thumbnail(for: item,
                                                           manager: state.sessionManager),
                   let loaded = NSImage(data: data) {
                    image = loaded
                    failed = false
                } else if image == nil {
                    failed = true
                }
            }
    }
}

/// 网格取图的键：条目 + 缩略图代数。
///
/// 刚上传那几张先画本机预览，服务端缩略图生成好之后 `PhotoLibrary.sweepPendingThumbs`
/// 会把图换掉并把代数加一 —— 代数进了这个键，cell 的 `.task` 才会重新跑一遍。
/// （`thumbs` 字典是 `@ObservationIgnored`，它自己变了不会通知界面。）
private struct ThumbRequest: Equatable {
    let itemID: Int
    let revision: Int
}

// MARK: - 人物卡 / 相册卡 / 列表行

/// 人物卡：88 圆头像 + 名字 + 张数。未确认的还是同一副形态，名字位显示「未确认」。
private struct PersonCard: View {
    let person: PhotosAPI.Person
    let library: PhotoLibrary
    let manager: SessionManager?
    /// 右键：参数已是根视图坐标（`RightClickCatcher` 换算过）。
    let onContext: (CGPoint) -> Void
    let onOpen: () -> Void

    @State private var image: NSImage?
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: DmSpace.s8) {
            ZStack {
                Circle().fill(Color.dmPanel2)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    LucideIcon("user", size: DmIcon.i24)
                        .foregroundColor(Color.dmInk3)
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(Circle())

            Text(person.displayName)
                .font(.system(size: DmText.t13, weight: person.isNamed ? .regular : .regular))
                .foregroundColor(person.isNamed ? Color.dmInk : Color.dmInk3)
                .lineLimit(1)

            Text("\(person.itemCount) 张")
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(Color.dmInk3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DmSpace.s8)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r8)
                .fill(isHovered ? Color.dmPanel3 : Color.clear)
        )
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: onOpen)
        .overlay { RightClickCatcher(onRightClick: onContext) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "打开") { onOpen() }
        .task(id: person.id) {
            guard image == nil else { return }
            guard let data = await library.personFaceImage(key: "p:\(person.id)",
                                                           personID: person.id,
                                                           coverUnitID: person.coverUnitID,
                                                           coverKey: person.coverKey,
                                                           manager: manager) else { return }
            image = NSImage(data: data)
        }
    }
}

/// 人物详情页头的 ⋯（与相册详情那颗同款）：菜单挂在按钮下沿。
private struct PersonOverflowButton: View {
    let onOpen: (CGPoint) -> Void

    @State private var frame: CGRect = .zero

    var body: some View {
        IconButton(iconName: "ellipsis", iconSize: DmIcon.i14, label: "人物操作") {
            onOpen(CGPoint(x: frame.minX, y: frame.maxY + DmSpace.s4))
        }
        .help("改名 / 归并到…")
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { frame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, value in frame = value }
            }
        )
    }
}

/// 相册卡：4:3 封面 + 名字 + 张数。封面取相册第一张条目（服务端列表不带封面）。
private struct AlbumCard: View {
    let album: PhotosAPI.Album
    let cover: PhotosAPI.Item?
    let library: PhotoLibrary
    let manager: SessionManager?
    let onOpen: () -> Void
    /// 右键：参数已是根视图坐标（`RightClickCatcher` 换算过）。
    let onContext: (CGPoint) -> Void

    @State private var image: NSImage?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DmSpace.s8) {
            Color.clear
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: DmRadius.r8)
                            .fill(Color.dmPanel2)
                        if let image {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            LucideIcon("images", size: DmIcon.i24)
                                .foregroundColor(Color.dmInk3)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DmRadius.r8))
                .overlay {
                    if isHovered {
                        RoundedRectangle(cornerRadius: DmRadius.r8)
                            .fill(Color.black.opacity(0.1))
                    }
                }

            Text(album.name)
                .font(.system(size: DmText.t13))
                .foregroundColor(Color.dmInk)
                .lineLimit(1)
            Text("\(album.itemCount) 张")
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(Color.dmInk3)
        }
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: onOpen)
        .overlay { RightClickCatcher(onRightClick: onContext) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // 封面是后到的（先取相册第一张条目、再取缩略图，两跳），id 里必须带上
        // 「封面到没到」，否则卡先出现、图后到，task 不会再跑一次。
        .task(id: "\(album.id):\(cover?.id ?? 0)") {
            guard image == nil, let cover else { return }
            guard let data = await library.thumbnail(for: cover, manager: manager),
                  let loaded = NSImage(data: data) else { return }
            image = loaded
        }
    }
}

/// 相册详情页头的 ⋯：把自身在窗口里的位置报给调用方，菜单挂在它下面。
///
/// 页头在 `DmPageHead` 的 trailing 槽里，按钮自己拿不到坐标 —— 用一层
/// `GeometryReader` 背景把 `.global` 框记下来（这个坐标系与右键菜单要的根视图
/// 坐标是同一套：左上原点、窗口顶起算）。
private struct AlbumOverflowButton: View {
    let onOpen: (CGPoint) -> Void

    @State private var frame: CGRect = .zero

    var body: some View {
        IconButton(iconName: "ellipsis", iconSize: DmIcon.i14, label: "相册操作") {
            onOpen(CGPoint(x: frame.minX, y: frame.maxY + DmSpace.s4))
        }
        .help("改名 / 删除相册")
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { frame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, value in frame = value }
            }
        )
    }
}

/// 地点 / 标签列表的一行。形态同列表卡（`panel-2` 底、悬停 `panel-3`），
/// 行首一枚 14 图标、行尾张数。
/// 地点屏的市分组头：市名（·省）+ 总张数 + 「看全部」。点组头进市聚合网格
/// （该市下所有地点的照片并集，`Route.placeCity`）。
private struct PlaceGroupHead: View {
    let title: String
    let count: Int
    let onSeeAll: () -> Void

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            Text(title)
                .font(.system(size: DmText.t13, weight: .semibold))
                .foregroundColor(Color.dmInk2)
            Text("\(count) 张")
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(Color.dmInk3)
            Spacer(minLength: 0)
            Button("看全部") { onSeeAll() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, DmSpace.s24)
        .padding(.top, DmSpace.s12)
        .padding(.bottom, DmSpace.s8)
    }
}

private struct CardListRow: Identifiable {
    let id: Int
    let icon: String
    let title: String
    let count: Int
    /// 次要说明（搜索态地点行右侧的市名），空串不显示。
    var note: String = ""
}

private struct CardListRowView: View {
    let row: CardListRow
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon(row.icon, size: DmIcon.i14)
                .foregroundColor(Color.dmInk3)
            Text(row.title)
                .font(.system(size: DmText.t13))
                .foregroundColor(Color.dmInk)
                .lineLimit(1)
            if !row.note.isEmpty {
                Text(row.note)
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
                    .lineLimit(1)
            }
            Spacer(minLength: DmSpace.s8)
            Text("\(row.count) 张")
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(Color.dmInk3)
        }
        .padding(.horizontal, DmSpace.s10)
        .padding(.vertical, DmSpace.s8)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r6)
                .fill(isHovered ? Color.dmPanel3 : Color.clear)
        )
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 提示

private struct PhotosNotice: View {
    let icon: String
    let title: String
    var note: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: DmSpace.s12) {
            LucideIcon(icon, size: DmIcon.i24)
                .foregroundColor(Color.dmInk3)
            Text(title)
                .font(.system(size: DmText.t15, weight: .semibold))
                .foregroundColor(Color.dmInk2)
            if let note {
                Text(note)
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk3)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(DmSpace.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

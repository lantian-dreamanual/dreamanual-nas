import Foundation
import Observation

/// 文件管理页的状态：共享夹 / 目录树 / 当前目录 / 排序 / 选中 / 分页。
///
/// 挂在 `AppState` 上而不是 `FilesView` 的 `@State` —— 与曲库同一理由：换模块、
/// 或者从曲库右键「在文件管理中显示」跳过来，都不该把这一页的浏览位置丢掉。
@MainActor
@Observable
final class FileBrowser {
    /// 树上的一行：共享夹本身、某个已展开目录的子目录，或「还有 N 个」。
    struct TreeRow: Identifiable {
        enum Kind { case share, folder, more }

        let kind: Kind
        let name: String
        /// 对 `more` 而言是**被收起的那个父目录**（点它就是展开全部）。
        let path: String
        /// 0 = 共享夹，往下每层 +1。
        let depth: Int
        /// 只给 `more` 用。
        var hidden: Int = 0

        var id: String { kind == .more ? "more\u{1}\(path)" : path }
    }

    /// 一层子目录最多先列几个，其余收进「还有 N 个」（原型 `.tree-more`）。
    /// `music` 顶层有三千多个目录，全铺出来这一列就没法看了。
    static let treeChildLimit = 8

    /// 列表一页拉多少。曲库是一页 1000 首，这里同一档 —— `/music` 顶层 3621 项
    /// 也就四页。
    static let pageSize = 1000

    private(set) var shares: [FileShare] = []
    private(set) var currentPath = ""
    private(set) var entries: [FileEntry] = []
    private(set) var total = 0
    private(set) var sort: FileSort? = FileStation.defaultSort
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    /// 点行选中。只读阶段是**单选** —— 多选的价值在批量操作，而批量操作全是写
    /// 操作（下一批）；现在放一个能勾却没出口的勾选框列就是空壳控件。
    private(set) var selectedPath: String?

    /// 已展开的目录路径。
    private(set) var expanded: Set<String> = []
    /// 目录 → 它的**子目录**（树不列文件）。拉过的层记着，展开 / 收起不再发请求。
    private(set) var children: [String: [FileEntry]] = [:]
    /// 该节点已「展开全部」。
    private(set) var expandedAll: Set<String> = []

    /// 表头各格的窗口坐标，由 `HeaderGrabber` 自报。冒烟通路合成点击要按位置落到
    /// 格子上 —— 位置不能猜（2026-10-14 踩过：猜错原点，事件落在表头下一行）。
    var headerFrames: [FileSortField: CGRect] = [:]

    private var hasLoaded = false
    private let defaults = UserDefaults.standard

    /// 服务端真正返回过的条数（**含被藏起来的系统目录**）。分页判据要用它 ——
    /// 用藏过之后的条数去比 `total`，会被那几个 `#` / `@` 顶得永远差几项、
    /// 一直以为还有下一页。
    private var fetched = 0

    /// 系统目录要藏（`接口结论.md` 第七节实测：`#recycle` 与 `@eaDir` 这一类
    /// 和普通目录混在同一层里）。它们是 DSM 自己的回收站与缩略图缓存，
    /// 在文件管理里列出来只会挡路。
    static func isSystemEntry(_ entry: FileEntry) -> Bool {
        entry.name.hasPrefix("#") || entry.name.hasPrefix("@")
    }

    private enum Keys {
        static let sortField = "nas.files.sortField"
        static let sortAscending = "nas.files.sortAscending"
    }

    init() {
        // 排序偏好跨重启保留 —— 与曲库同一口径。**列序不存**：文件表这三列是
        // 服务端认下的三个字段，顺序按固定列走，没有可拖的余地。
        if let raw = defaults.string(forKey: Keys.sortField), let field = FileSortField(rawValue: raw) {
            sort = FileSort(field: field, ascending: defaults.object(forKey: Keys.sortAscending) as? Bool ?? true)
        }
    }

    // MARK: - 装载

    /// 入口（`FilesView.task`）调用。首屏只拉共享夹清单 + 打开一个落地目录，
    /// 树的子层按展开逐级拉。
    func loadIfNeeded(_ manager: SessionManager?, username: String) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload(manager, username: username)
    }

    func reload(_ manager: SessionManager?, username: String) async {
        guard let manager else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            shares = try await FileStation.shares(manager)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard currentPath.isEmpty else {
            await loadPage(reset: true, on: manager)
            return
        }
        await open(landing(username), on: manager)
    }

    /// 落地目录：**个人目录 `/homes/<用户名>`**，拿不到用户名或不存在时退回第一个
    /// 共享夹。⚠️ 个人目录不是 `/home`（那条路径回 `code=408`）。
    private func landing(_ username: String) -> String {
        let home = username.isEmpty ? "" : "/homes/\(username)"
        if !home.isEmpty, shares.contains(where: { $0.path == "/homes" }) { return home }
        return shares.first?.path ?? "/"
    }

    /// 进入一个目录：列表重拉第一页、清掉旧的选中、把树展开到它。
    func open(_ path: String, on manager: SessionManager?) async {
        guard !path.isEmpty else { return }
        currentPath = path
        selectedPath = nil
        await revealAncestors(of: path, on: manager)
        await loadPage(reset: true, on: manager)
    }

    /// 重新拉：共享夹清单重来，树缓存清空（展开的层跟着作废），当前目录照旧重开一次。
    func refresh(_ manager: SessionManager?, username: String) async {
        guard let manager else { return }
        children.removeAll()
        expandedAll.removeAll()
        expanded.removeAll()
        guard !currentPath.isEmpty else {
            await reload(manager, username: username)
            return
        }
        await revealAncestors(of: currentPath, on: manager)
        await loadPage(reset: true, on: manager)
    }

    func loadMore(_ manager: SessionManager?) async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        await loadPage(reset: false, on: manager)
    }

    var hasMore: Bool { fetched < total }

    /// 状态栏那个总数：载完了就是手上这一份的条数（藏掉的系统目录自然不在里面），
    /// 还没载完时用服务端的 `total` 估 —— 那个数含 `#recycle` 这类被藏起来的条目。
    var displayTotal: Int { hasMore ? total : entries.count }

    // MARK: - 目录树

    /// 树的扁平行序 —— 展开状态与子层缓存都在这里合成。
    var treeRows: [TreeRow] {
        var rows: [TreeRow] = []
        for share in shares {
            rows.append(TreeRow(kind: .share, name: share.name, path: share.path, depth: 0))
            appendChildren(of: share.path, depth: 1, into: &rows)
        }
        return rows
    }

    private func appendChildren(of path: String, depth: Int, into rows: inout [TreeRow]) {
        guard expanded.contains(path), let kids = children[path] else { return }
        let dirs = kids.filter(\.isDirectory)
        let limit = expandedAll.contains(path) ? dirs.count : min(dirs.count, Self.treeChildLimit)
        for kid in dirs.prefix(limit) {
            rows.append(TreeRow(kind: .folder, name: kid.name, path: kid.path, depth: depth))
            appendChildren(of: kid.path, depth: depth + 1, into: &rows)
        }
        if dirs.count > limit {
            rows.append(TreeRow(kind: .more, name: "还有 \(dirs.count - limit) 个",
                                path: path, depth: depth, hidden: dirs.count - limit))
        }
    }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    /// 点行右侧的箭头：展开 / 收起一层。展开时那一层才发请求（逐级懒加载）。
    func toggleExpand(_ path: String, on manager: SessionManager?) async {
        if expanded.contains(path) {
            expanded.remove(path)
            return
        }
        expanded.insert(path)
        if children[path] == nil {
            children[path] = await childDirectories(of: path, on: manager)
        }
    }

    /// 点「还有 N 个」：把这层剩下的也铺出来。
    func revealAllChildren(_ path: String) {
        expandedAll.insert(path)
    }

    /// 把树展开到 `path` 那一层，让当前目录在树上有迹可循。已经拉过的层不重拉。
    private func revealAncestors(of path: String, on manager: SessionManager?) async {
        guard let manager else { return }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return }
        var current = ""
        for part in parts {
            current += "/" + part
            if current == path { break }
            expanded.insert(current)
            if children[current] == nil {
                children[current] = await childDirectories(of: current, on: manager)
            }
        }
    }

    /// 拉一层的子目录。**排序固定名称正序**（原型写明树形浏览按名称正序逐级懒加载），
    /// 与列表的排序偏好无关 —— 树上换排法没有意义。
    private func childDirectories(of path: String, on manager: SessionManager?) async -> [FileEntry] {
        guard let manager else { return [] }
        do {
            let page = try await FileStation.list(
                manager, path: path, sort: FileStation.defaultSort, limit: FileStation.treeFetchLimit
            )
            return page.entries.filter { $0.isDirectory && !Self.isSystemEntry($0) }
        } catch {
            return []
        }
    }

    // MARK: - 列表与排序

    private func loadPage(reset: Bool, on manager: SessionManager?) async {
        guard let manager else { return }
        let offset = reset ? 0 : entries.count
        if reset { isLoading = true } else { isLoadingMore = true }
        if reset { errorMessage = nil }
        defer {
            isLoading = false
            isLoadingMore = false
        }
        do {
            let page = try await FileStation.list(
                manager, path: currentPath, sort: sort,
                offset: offset, limit: Self.pageSize
            )
            // 系统目录（`#recycle` / `@eaDir` 这类）不进列表，但它们**算在 total 里**
            // —— 所以另外记一把服务端返回的条数，分页判据读它。
            let kept = page.entries.filter { !Self.isSystemEntry($0) }
            entries = reset ? kept : entries + kept
            fetched = reset ? page.entries.count : fetched + page.entries.count
            total = page.total
        } catch {
            if reset {
                errorMessage = error.localizedDescription
                entries = []
                fetched = 0
                total = 0
            }
        }
    }

    /// 点表头：同一列再点换方向，换一列从正序起。
    func toggleSort(_ field: FileSortField, on manager: SessionManager?) async {
        let ascending = (sort?.field == field) ? !(sort?.ascending ?? true) : true
        await applySort(FileSort(field: field, ascending: ascending), on: manager)
    }

    /// 直设排序（冒烟通路走这条 —— 它绕开点击，验的是数据层）。
    func applySort(_ next: FileSort?, on manager: SessionManager?) async {
        sort = next
        if let next {
            defaults.set(next.field.rawValue, forKey: Keys.sortField)
            defaults.set(next.ascending, forKey: Keys.sortAscending)
        }
        await loadPage(reset: true, on: manager)
    }

    // MARK: - 选中

    func select(_ entry: FileEntry) {
        selectedPath = entry.path
    }

    var selectedEntry: FileEntry? {
        guard let selectedPath else { return nil }
        return entries.first { $0.path == selectedPath }
    }

    // MARK: - 面包屑

    /// 当前路径的逐段拆分。返回的是原始路径片段，视图那一侧再包成可点的面包屑。
    var pathSegments: [String] {
        currentPath.split(separator: "/").map(String.init)
    }

    /// 第 `index` 段对应的完整路径（面包屑点哪一段就跳到哪）。
    func path(upTo index: Int) -> String {
        let parts = pathSegments
        guard index < parts.count else { return currentPath }
        return "/" + parts.prefix(index + 1).joined(separator: "/")
    }

    var parentPath: String? {
        let parts = pathSegments
        guard parts.count > 1 else { return nil }
        return "/" + parts.dropLast().joined(separator: "/")
    }
}

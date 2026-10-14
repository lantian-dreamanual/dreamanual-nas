import Foundation
import Observation

/// 选目标弹窗的状态（复制与移动共用）。
///
/// 挂 `AppState` 而不是视图的 `@State` —— 与文件管理页同一个理由：冒烟通路要在视图
/// 之外把弹窗摆到指定状态（打开、设搜索词、选目标），还能截图核对。
///
/// **搜索走客户端过滤已加载层**，不依赖 `FileStation.Search`。那条路 2026-10-14 实测
/// 连着 24 次全是假空（`/music` 上搜 `mp3` 连试四次也没出），驯服它留给「搜索」那一批。
/// 能搜的范围是「树里已经拉过的层」，所以打开弹窗时先把**当前目录那一层拉满** ——
/// `music` 那种三千多个兄弟目录的场景因此开箱可搜，正好是原型说的那个痛点。
///
/// 另一处与资料库树刻意不同：**选目标的树整层铺开、不截断**。浏览树截断是怕一列塞满
/// 看不见右侧列表；这里选目标必须看到全部层级名，所以整层滚动展示（原型注明）。
@MainActor
@Observable
final class DestinationPicker {
    struct Row: Identifiable {
        /// `folder` 是树上的节点，`hit` 是筛选态的平铺结果。
        enum Kind { case folder, hit }

        let kind: Kind
        let name: String
        let path: String
        let depth: Int
        /// 筛选态下每行右侧那条路径（相对共享夹，`music › 华语`）。
        var parentText: String = ""
        /// 树上这一行还展不展得开。子层没拉过就乐观给 true，拉了发现是空的就熄掉。
        var canExpand: Bool = false
        var isExpanded: Bool = false

        /// 同一路径在树与筛选态都要能出现 —— 前缀把两种行分开，`id` 不会撞。
        var id: String { "\(kind)\u{1}\(path)" }
    }

    /// 共享夹清单（由文件管理页那一份直接给，不重新拉一次）。
    private(set) var shares: [FileShare] = []
    /// 当前选中的目标目录。
    private(set) var target = ""
    /// 搜索框里的字。输入即筛选。
    var query = ""
    private(set) var isLoading = false

    private(set) var expanded: Set<String> = []
    private(set) var children: [String: [FileEntry]] = [:]

    // MARK: - 开与收

    /// 开弹窗：目标默认落在**当前所在目录**，并把树展开到它、把那一层拉满。
    ///
    /// 默认目标其实就是「来源所在的位置」—— 直接确认等于什么也没做，所以确认按钮
    /// 一开始是灰的（`FileTransfer.blockingReason` 会说为什么）。默认值的作用是
    /// **把树定位到用户现在待的地方**，旁边那几层一点就到。
    func open(currentPath: String, shares: [FileShare], on manager: SessionManager?) async {
        self.shares = shares
        target = currentPath
        query = ""
        expanded.removeAll()
        children.removeAll()
        guard !currentPath.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        await reveal(currentPath, on: manager)
    }

    func reset() {
        target = ""
        query = ""
        expanded.removeAll()
        children.removeAll()
    }

    func select(_ path: String) {
        target = path
    }

    /// 重拉某一层的子目录（在弹窗里新建了文件夹之后用）。顺带把那层展开 ——
    /// 新建的夹要能立刻看见，不然用户以为没建成。
    func reload(_ path: String, on manager: SessionManager?) async {
        children[path] = await directories(of: path, on: manager)
        expanded.insert(path)
    }

    /// 某一层**已经拉过**的子目录，没拉过给 `nil`。建文件夹时的重名判定要用 ——
    /// 不为这个再发一次请求。
    func loadedChildren(of path: String) -> [FileEntry]? { children[path] }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    /// 展开 / 收起一层。展开时才发请求（逐级懒加载）。
    func toggleExpand(_ path: String, on manager: SessionManager?) async {
        if expanded.contains(path) {
            expanded.remove(path)
            return
        }
        expanded.insert(path)
        if children[path] == nil {
            children[path] = await directories(of: path, on: manager)
        }
    }

    /// 把树展开到 `path`（含它自己），路上每一层的子目录都拉过。
    private func reveal(_ path: String, on manager: SessionManager?) async {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        var current = ""
        for part in parts {
            current += "/" + part
            expanded.insert(current)
            if children[current] == nil {
                children[current] = await directories(of: current, on: manager)
            }
        }
    }

    /// 拉一层的**子目录**。排序固定名称正序（与浏览树同一口径）。
    ///
    /// 一次拉满 5000：实测 `/music` 顶层 3621 项一次拿全，选目标这一层不翻页。
    private func directories(of path: String, on manager: SessionManager?) async -> [FileEntry] {
        guard let manager else { return [] }
        do {
            let page = try await FileStation.list(
                manager, path: path, sort: FileStation.defaultSort,
                limit: FileStation.treeFetchLimit
            )
            return page.entries.filter { $0.isDirectory && !FileBrowser.isSystemEntry($0) }
        } catch {
            return []
        }
    }

    // MARK: - 行

    /// 搜索框空着给树，有字给平铺结果。
    var rows: [Row] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? treeRows : hitRows(text)
    }

    /// 筛选态：结果来自**所有已拉过的层** + 共享夹本身。名称子串匹配、不分大小写。
    private func hitRows(_ text: String) -> [Row] {
        var corpus: [(name: String, path: String)] = shares.map { ($0.name, $0.path) }
        for kids in children.values {
            for kid in kids { corpus.append((kid.name, kid.path)) }
        }
        var seen = Set<String>()
        var out: [Row] = []
        for item in corpus {
            guard !seen.contains(item.path) else { continue }
            guard item.name.localizedCaseInsensitiveContains(text) else { continue }
            seen.insert(item.path)
            out.append(Row(
                kind: .hit, name: item.name, path: item.path, depth: 0,
                parentText: Self.shortPath(FileBrowser.parent(of: item.path))
            ))
        }
        return out.sorted { ($0.name, $0.path) < ($1.name, $1.path) }
    }

    private var treeRows: [Row] {
        var out: [Row] = []
        for share in shares {
            out.append(Row(kind: .folder, name: share.name, path: share.path, depth: 0,
                           canExpand: canExpand(share.path), isExpanded: expanded.contains(share.path)))
            append(share.path, depth: 1, into: &out)
        }
        return out
    }

    /// 子树。**整层铺，不截断** —— 选目标要看到全部层级名（原型注明与浏览树的取舍不同）。
    private func append(_ path: String, depth: Int, into out: inout [Row]) {
        guard expanded.contains(path), let kids = children[path] else { return }
        for kid in kids {
            out.append(Row(kind: .folder, name: kid.name, path: kid.path, depth: depth,
                           canExpand: canExpand(kid.path), isExpanded: expanded.contains(kid.path)))
            append(kid.path, depth: depth + 1, into: &out)
        }
    }

    private func canExpand(_ path: String) -> Bool {
        guard let kids = children[path] else { return true }
        return !kids.isEmpty
    }

    // MARK: - 文本

    /// `music › 华语 › 2024` —— 目标栏与筛选结果右侧那条路径都用它。
    static func shortPath(_ path: String) -> String {
        path.split(separator: "/").joined(separator: " › ")
    }

    var targetText: String { Self.shortPath(target) }

    /// 目标目录能不能写。来源与 `FileBrowser.currentCanWrite` 同一套：共享夹表 →
    /// 父层已拉过的那份清单（目标一定在已拉过的某一层里），都没查到就乐观给 true。
    var targetCanWrite: Bool {
        if let share = shares.first(where: { $0.path == target }) { return share.canWrite }
        let parent = FileBrowser.parent(of: target)
        if let kids = children[parent], let me = kids.first(where: { $0.path == target }) {
            return me.canWrite
        }
        return true
    }

    /// 筛选态下的一行提示。
    var hitCountText: String { "\(rows.count) 个匹配" }
}

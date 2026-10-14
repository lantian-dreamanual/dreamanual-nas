import Foundation

/// 上传队列：把「本机选了哪些东西」摊成一项一项，串着传上去。
///
/// 三件事它必须自己做，都是实测逼出来的：
///
///   1. **撞名自己先查** —— 上传的 `overwrite=false` 撞名回「成功」但内容不变
///      （静默跳过），服务端连冲突都不报；要覆盖只能自己先问过用户再带 `overwrite=true`。
///   2. **文件夹递归展开**，空目录单独建 —— 上传的 `filename` 不能带斜杠（回 `418`），
///      层级只能靠目的目录带过去，而空目录没有任何文件能带着它上去。
///   3. **进度与取消** —— 上行只有 0.31 MB/s，50 MB 要两分半，没有进度与取消就是死等。
///
/// 串行不并发：这条链路本来就窄，并发只会让每一项都变慢，还让「已传多少」对不上。
@MainActor
@Observable
final class UploadQueue {
    /// 一项待传的东西。上传文件夹时，**目录与它里面的每个文件各是一项**。
    struct Item: Identifiable, Equatable {
        let id = UUID()
        /// 本机文件（目录项指向那个目录本身，只用来取名字与建目录）。
        let localURL: URL
        /// 落地用的名字。冲突选「保留两者」时会加上序号，所以是 var。
        var name: String
        /// 目的目录（NAS 绝对路径）。文件夹上传时这里是 `…/新文件夹/子层`。
        let directory: String
        /// 是目录（只建目录，没有字节数可报）。
        let isDirectory: Bool
        /// 字节数；目录是 0。
        var byteCount: Int64
        var state: State = .waiting
        /// 已发字节（进度回调来的，含 multipart 那点段头）。
        var sent: Int64 = 0
        /// 这一条请求要发的总字节（进度回调报的）。**分母用它，不用 `byteCount`** ——
        /// 后者是文件本身的大小，比实际要发的少几百字节段头，拿它当分母会算出 100.1%。
        var expected: Int64 = 0
        /// 字节/秒，指数平滑。首个样本之前是 0 —— 那时算不出速率，界面上不写。
        var rate: Double = 0
    }

    enum State: Equatable {
        case waiting
        case uploading
        case done
        case skipped
        case failed(String)
    }

    /// 冲突三选。**与返回码无关**，是用户的选择：`替换` 带 `overwrite=true` 再传，
    /// `保留两者` 换个不撞的名字，`跳过` 这一项不传。
    enum ConflictChoice {
        case replace
        case keepBoth
        case skip
    }

    /// 待用户拍板的那一项冲突。一次只摆一条 —— 弹窗是模态的，多条排队问。
    struct ConflictPrompt: Identifiable {
        let id = UUID()
        /// 要传上去的那一份。
        let item: Item
        /// 目的目录里已经有的那一份（名字 / 大小 / 时间从 `List` 来）。
        let existing: FileEntry
        /// 选「保留两者」时这一份会叫什么 —— 弹窗要把换名的结果写出来给用户看。
        let keptName: String
        /// 这次上传里还剩几项会撞名（含当前这项）。大于 1 才给「应用于全部」。
        let remaining: Int
    }

    private(set) var items: [Item] = []
    /// 正在等用户决定的冲突；不为空时队列停在这里。
    private(set) var conflict: ConflictPrompt?
    /// 这一批里被用户跳过的项数（收尾提示要用）。
    private(set) var skippedCount = 0
    /// 这一批跑完（传完 / 失败停下 / 取消）时回调一次。界面拿它刷新列表与收尾提示。
    var onBatchEnd: (() async -> Void)?
    /// 有东西正拖在列表上方（拖入提示由 `FileDropCatcher` 报，落在这里是为了
    /// 冒烟通路能把它摆出来截图 —— 真拖拽 AI 发不出来）。
    var dropTargeted = false

    private var runTask: Task<Void, Never>?
    private var lastTick: [UUID: Date] = [:]
    /// 目的目录里已有的名字（目录 → 条目）。同一目录只拉一次 —— 上传文件夹时会问
    /// 好几次同一个目录，而每拉一次是 0.3 秒。
    private var nameCache: [String: [FileEntry]] = [:]
    /// 还没问过用户的那几项冲突，与 `conflict` 一起构成排队。
    private var pendingConflicts: [Item.ID] = []
    /// 「应用于全部」勾上后，剩下的冲突不再问、直接按这个选择走。
    private var appliedChoice: ConflictChoice?

    // MARK: - 对外状态

    /// 正在传的那一项（没有就是 nil）。
    var current: Item? { items.first { $0.state == .uploading } }

    /// 列表上方那一行要显示的东西：先看有没有失败的，再看有没有在传的。
    var headline: Item? {
        items.first { if case .failed = $0.state { return true } else { return false } }
            ?? items.first { $0.state == .uploading || $0.state == .waiting }
    }

    /// 还排在后面没动的项数（不含正在传的那一项）。
    var queuedCount: Int {
        guard let current else { return items.filter { $0.state == .waiting }.count }
        return items.filter { $0.state == .waiting && $0.id != current.id }.count
    }

    var isBusy: Bool { items.contains { $0.state == .uploading } || conflict != nil }

    /// 这一批还剩几项要落地（没传完、没跳过、没失败的）。
    private var unfinished: [Item] {
        items.filter { $0.state == .waiting || $0.state == .uploading }
    }

    // MARK: - 入口

    /// 准备一批上传：摊平、查撞名，有冲突就先摆弹窗，没有就直接开传。
    ///
    /// - Parameters:
    ///   - target: 目的目录（界面上是「当前所在目录」）。
    ///   - knownEntries: 目的目录当前这一层已有的条目，**必须是把整层都装全了的那一份**
    ///     （界面上一页只有 1000 项，目录更大时给 nil —— 拿半页当全部会漏掉撞名）。
    ///     给 nil 时自己拉满一层。
    func prepare(
        urls: [URL],
        target: String,
        knownEntries: [FileEntry]? = nil,
        manager: SessionManager
    ) async {
        guard !urls.isEmpty else { return }
        cancel()
        items = []
        skippedCount = 0
        appliedChoice = nil
        nameCache = [:]
        pendingConflicts = []

        items = Self.plan(urls: urls, target: target)
        guard !items.isEmpty else { return }

        // 目的目录里已有的名字：先按当前这一层拉一次，其余目录在查到时按需拉。
        if let knownEntries {
            nameCache[target] = knownEntries
        } else if nameCache[target] == nil {
            nameCache[target] = (try? await FileStation.list(
                manager, path: target, sort: FileStation.defaultSort, limit: 5000
            ).entries) ?? []
        }
        await scanConflicts(manager: manager)
        if let first = pendingConflicts.first {
            present(first)
            return
        }
        start(manager: manager)
    }

    /// 用户拍了冲突怎么处理。`applyToAll` 时后面不再问。
    func resolve(_ choice: ConflictChoice, applyToAll: Bool, manager: SessionManager) async {
        guard let prompt = conflict else { return }
        if applyToAll { appliedChoice = choice }
        apply(choice, to: prompt.item.id)
        conflict = nil
        pendingConflicts.removeAll { $0 == prompt.item.id }

        await scanConflicts(manager: manager)
        if let next = pendingConflicts.first, appliedChoice == nil {
            present(next)
            return
        }
        start(manager: manager)
    }

    /// 取消这一批：正在传的那一条断掉，剩下的不再传。
    func cancel() {
        let wasRunning = runTask != nil
        runTask?.cancel()
        runTask = nil
        for index in items.indices where items[index].state == .waiting || items[index].state == .uploading {
            items[index].state = .skipped
        }
        conflict = nil
        pendingConflicts = []
        // 停在冲突弹窗上、根本没在传的时候，收尾回调得自己发一次。
        if !wasRunning { notifyBatchEnd() }
    }

    /// 把失败那一项之后的东西接着传（失败时队列停下，不是整批作废）。
    func retry(manager: SessionManager) {
        for index in items.indices {
            if case .failed = items[index].state {
                items[index].state = .waiting
                items[index].sent = 0
                items[index].rate = 0
            }
        }
        start(manager: manager)
    }

    /// 收掉已经结束的行（传完的、跳过的）。失败的那条留着给用户重试或移除。
    func dismissFinished() {
        items.removeAll { $0.state == .done || $0.state == .skipped }
    }

    /// 把失败的那一项从队列里摘掉，后面的接着走。
    func dropFailed() {
        items.removeAll { if case .failed = $0.state { return true } else { return false } }
    }

    // MARK: - 摊平

    /// 把用户挑的东西摊成一项一项：目录按层排在前（空的也能建出来），文件跟在后面。
    ///
    /// 目录**每一个都显式建**，不靠上传时顺手建：`CreateFolder` 撞名回「成功」但什么
    /// 也不做，正好当幂等用 —— 顺序也就无所谓，只按层深浅排一下让日志好看。
    static func plan(urls: [URL], target: String) -> [Item] {
        let fm = FileManager.default
        var directories: [Item] = []
        var files: [Item] = []

        /// 一个要建的目录：`directory` 是它的父层，`name` 是它自己的名字。
        func walk(_ url: URL, parent: String) {
            let name = url.lastPathComponent
            let own = parent.hasSuffix("/") ? parent + name : parent + "/" + name
            directories.append(Item(localURL: url, name: name, directory: parent,
                                    isDirectory: true, byteCount: 0))
            let children = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    walk(child, parent: own)
                } else {
                    let size = Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    files.append(Item(localURL: child, name: child.lastPathComponent,
                                      directory: own, isDirectory: false, byteCount: size))
                }
            }
        }

        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                walk(url, parent: target)
            } else {
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                files.append(Item(localURL: url, name: url.lastPathComponent,
                                  directory: target, isDirectory: false, byteCount: size))
            }
        }
        return directories + files
    }

    // MARK: - 撞名

    /// 把每一项与目的目录里已有的名字对一遍（**逐字比较**，改大小写在服务端合法），
    /// 记下要问用户的那些；没撞名的顺手记进缓存，让「同一批里两项同名」也撞得出来。
    private func scanConflicts(manager: SessionManager) async {
        for item in items where item.state == .waiting {
            // 目录撞名一律合并 —— 服务端就是这个行为，文件管理器也都这么干。
            if item.isDirectory { continue }
            if let choice = appliedChoice {
                apply(choice, to: item.id)
                continue
            }
            let siblings = await siblings(of: item, manager: manager)
            if siblings.contains(where: { $0.name == item.name }) {
                if !pendingConflicts.contains(item.id) { pendingConflicts.append(item.id) }
            } else {
                nameCache[item.directory, default: []].append(syntheticEntry(for: item))
            }
        }
    }

    private func present(_ id: Item.ID) {
        guard let item = items.first(where: { $0.id == id }) else {
            pendingConflicts.removeAll { $0 == id }
            return
        }
        let siblings = nameCache[item.directory] ?? []
        let existing = siblings.first { $0.name == item.name } ?? syntheticEntry(for: item)
        conflict = ConflictPrompt(
            item: item,
            existing: existing,
            keptName: Self.availableName(for: item.name, taken: Set(siblings.map(\.name))),
            remaining: max(pendingConflicts.count, 1)
        )
    }

    /// 目的目录里已有的条目，没拉过就拉一次（拉不到当空 —— 目录还没建起来时正是这样）。
    private func siblings(of item: Item, manager: SessionManager) async -> [FileEntry] {
        if let cached = nameCache[item.directory] { return cached }
        let entries = (try? await FileStation.list(
            manager, path: item.directory, sort: FileStation.defaultSort, limit: 5000
        ).entries) ?? []
        nameCache[item.directory] = entries
        return entries
    }

    /// 给「同一批里先到的那一项」造一个占位条目，好让它也参与撞名比较。
    private func syntheticEntry(for item: Item) -> FileEntry {
        FileEntry(
            name: item.name,
            path: item.directory + "/" + item.name,
            isDirectory: item.isDirectory,
            size: item.isDirectory ? nil : item.byteCount,
            modified: nil,
            type: (item.name as NSString).pathExtension.uppercased(),
            owner: "",
            canWrite: true
        )
    }

    private func apply(_ choice: ConflictChoice, to id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch choice {
        case .replace:
            // 替换：名字不动，服务端那边 `overwrite=true` 会盖掉。
            nameCache[items[index].directory, default: []].removeAll { $0.name == items[index].name }
            nameCache[items[index].directory, default: []].append(syntheticEntry(for: items[index]))
        case .keepBoth:
            let existing = nameCache[items[index].directory] ?? []
            let taken = Set(existing.map(\.name))
            let fresh = Self.availableName(for: items[index].name, taken: taken)
            items[index].name = fresh
            nameCache[items[index].directory, default: []].append(syntheticEntry(for: items[index]))
        case .skip:
            items[index].state = .skipped
            skippedCount += 1
        }
    }

    /// 「保留两者」用的新名字：`夜航.mp3` → `夜航 2.mp3` → `夜航 3.mp3`…（原型口径）。
    /// 目录不带扩展名，序号缀在整名后面。
    static func availableName(for name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            if !taken.contains(candidate) { return candidate }
            index += 1
        }
    }

    // MARK: - 传

    private func start(manager: SessionManager) {
        guard runTask == nil, !unfinished.isEmpty else { return }
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(manager: manager)
        }
    }

    private func notifyBatchEnd() {
        guard let handler = onBatchEnd else { return }
        Task { await handler() }
    }

    private func run(manager: SessionManager) async {
        defer {
            runTask = nil
            notifyBatchEnd()
        }
        for index in items.indices {
            // 循环里每一步都重新取状态：用户可能刚取消或跳过。
            guard !Task.isCancelled else { return }
            guard items[index].state == .waiting else { continue }
            let item = items[index]
            items[index].state = .uploading
            do {
                if item.isDirectory {
                    // 重名回「成功」但什么也不做 —— 正好当幂等用，不预查。
                    try await FileStation.createFolder(
                        manager, path: item.directory, name: item.name, forceParent: true
                    )
                } else {
                    let id = item.id
                    try await FileStation.upload(
                        manager, fileURL: item.localURL, name: item.name, to: item.directory
                    ) { sent, total in
                        // 进度回调在 URLSession 的代理队列上，`note` 在主线程 —— 跳一下。
                        // 这里强引用 self：闭包随这一条请求活着，请求结束就释放，
                        // 不构成队列自身的循环引用。
                        Task { @MainActor [self] in
                            self.note(sent: sent, total: total, for: id)
                        }
                    }
                }
                if let at = items.firstIndex(where: { $0.id == item.id }) {
                    items[at].state = .done
                }
            } catch {
                let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                if let at = items.firstIndex(where: { $0.id == item.id }) {
                    if cancelled {
                        items[at].state = .skipped
                    } else {
                        items[at].state = .failed(Self.reason(for: error))
                        items[at].rate = 0
                    }
                }
                // 取消就整批收；断了就停在这里、后面的留着 —— 网络没恢复的话后面只会
                // 一个个失败，那比停下来更吵。
                if cancelled { return }
                return
            }
        }
    }

    /// 进度回调。节流到 4 次/秒 —— 回调本身来得比界面需要密得多。
    private func note(sent: Int64, total: Int64, for id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        let previous = lastTick[id]
        if let previous, now.timeIntervalSince(previous) < 0.25, sent != total { return }
        lastTick[id] = now

        let delta = sent - items[index].sent
        if let previous, delta > 0 {
            let elapsed = now.timeIntervalSince(previous)
            if elapsed > 0 {
                let instant = Double(delta) / elapsed
                items[index].rate = items[index].rate == 0
                    ? instant
                    : items[index].rate * 0.7 + instant * 0.3
            }
        }
        items[index].sent = sent
        items[index].expected = total
    }

    static func reason(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络断了，已传的部分不会保留"
            case .timedOut:
                return "服务端没应答（超时）"
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

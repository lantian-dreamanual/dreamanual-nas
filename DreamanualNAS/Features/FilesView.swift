import AppKit
import SwiftUI

/// 文件管理。
///
/// 形态照原型 `design/界面原型.html` 的文件管理屏：左侧目录树（共享夹是导航第一层、
/// 逐级懒加载、子层过长只列前几项）+ 右侧（页头与面包屑 / 工具条 / 上传行 / 表 / 状态栏）。
///
/// 已落地：浏览、排序、分页、缩略图、下载、从曲库「在文件管理中显示」跳过来，
/// 写操作（多选勾选列 / 新建文件夹 / 重命名 / 删除 / 上传 / 复制 / 移动），
/// 以及搜索（工具条右端那个框，走服务端）与按需算目录大小。
struct FilesView: View {
    @Environment(AppState.self) private var state

    /// 状态挂在 `AppState` 上，不是本视图的 `@State` —— 与曲库同一理由：换模块、
    /// 从曲库跳过来，都不该把浏览位置丢掉。
    private var model: FileBrowser { state.files }
    private var uploads: UploadQueue { state.uploads }
    private var search: FileSearch { state.search }

    /// 拖入高亮的开关。状态落在 `uploads` 上而不是本视图 —— 冒烟通路要能把它摆出来，
    /// 视图自己的 `@State` 外面够不着。
    private var dropTarget: Binding<Bool> {
        Binding(get: { uploads.dropTargeted }, set: { uploads.dropTargeted = $0 })
    }

    var body: some View {
        HStack(spacing: 0) {
            FileTreePanel(model: model, manager: state.sessionManager)
            main
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 主内容区取 `panel`（第一节落位口径；内容区侧栏与主区同底，分界靠那根发丝）。
        .background(Color.dmPanel)
        .task { await model.loadIfNeeded(state.sessionManager, username: state.username) }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            DmPageHead("文件管理", crumbs: crumbs) {
                IconButton(iconName: "refresh-cw") {
                    Task { await model.refresh(state.sessionManager, username: state.username) }
                }
            }

            toolbar

            if !writable {
                DmBanner(icon: "triangle-alert", text: "当前目录不可写，新建、上传、改名与删除已停用")
            }

            uploadRows

            content

            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 面包屑：路径逐段拆开，最后一段是当前所在（不可点）。原型 `.crumb`。
    private var crumbs: [DmCrumb] {
        let parts = model.pathSegments
        return parts.enumerated().map { index, part in
            // 最后一段不带动作 —— 它就是当前所在，点了没有去处。
            index == parts.count - 1
                ? DmCrumb(part)
                : DmCrumb(part, action: { jump(to: model.path(upTo: index)) })
        }
    }

    private func jump(to path: String) {
        Task { await model.open(path, on: state.sessionManager) }
    }

    /// 当前目录可写。不可写时三个写操作按钮全体灰掉 —— 判据与那条提醒条同一个
    /// （`perm.acl.write`）。
    private var writable: Bool { model.currentCanWrite }

    /// 浏览态（没在搜索）。搜索态下列表被结果整块替掉，而工具条那些动作按的是
    /// **浏览列表里那份选中集合** —— 它此刻看不见，所以一律灰掉：点一行结果跳过去，
    /// 在浏览态里再操作。
    private var browse: Bool { !search.isActive }

    /// 工具条：新建文件夹 / 上传 / 下载 / 复制到… / 移动到… / 重命名 / 删除 —— 已接线的
    /// 动作（原型那一排与顺序一致）。
    ///
    /// 复制与移动**各占一个入口**，不做「复制 / 粘贴 / 剪切」三件套：剪贴板状态要用户
    /// 记着「粘到哪、粘没粘过」，两个入口各弹一次选目标就都省了（原型注明）。
    private var toolbar: some View {
        HStack(spacing: DmSpace.s8) {
            action("新建文件夹", icon: "folder-plus", enabled: browse && writable) {
                state.openFileDialog(.newFolder(in: model.currentPath))
            }
            action("上传", icon: "upload", enabled: browse && writable) {
                state.pickAndUpload()
            }
            action("下载", icon: "download",
                   enabled: browse && model.singleSelection?.isDirectory == false) {
                guard let entry = model.singleSelection else { return }
                Task { await state.download(file: entry) }
            }
            action("复制到…", icon: "copy",
                   enabled: browse && !model.selection.isEmpty) {
                state.beginTransfer(.copy)
            }
            action("移动到…", icon: "folder-input",
                   enabled: browse && writable && !model.selection.isEmpty) {
                state.beginTransfer(.move)
            }
            action("重命名", icon: "pencil",
                   enabled: browse && writable && model.singleSelection != nil) {
                guard let entry = model.singleSelection else { return }
                state.openFileDialog(.rename(entry))
            }
            action("删除", icon: "trash",
                   enabled: browse && writable && !model.selection.isEmpty) {
                state.openFileDialog(.delete(model.selectedEntries))
            }

            Spacer(minLength: 0)

            // 搜索框在工具条**右端**（原型 `.toolbar .right`，宽 200）。
            //
            // 🔴 这一条是**提交式**（回车才搜），不是曲库那种输入即筛：服务端搜一次要
            // 2–9 秒、还会随机返回假空让你重试，输入即搜会把每个键都变成一次全库遍历。
            // 点清除钮也是走 `onSubmit`（组件内部清完字就回调），空串在 `FileSearch.run`
            // 里当「退出搜索」处理。
            DmSearchField(
                text: Binding(get: { search.query }, set: { search.query = $0 }),
                placeholder: "搜索文件",
                onSubmit: { Task { await state.submitFileSearch() } }
            )
            .frame(width: FilesMetrics.searchWidth)
        }
        .padding(.horizontal, DmSpace.s24)
        .padding(.bottom, DmSpace.s12)
    }

    /// 工具条上的一个动作（原型 `.btn.btn-sec.btn-xs`：高 28 / 字 12 / 图标 12）。
    private func action(_ title: String, icon: String, enabled: Bool,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: DmSpace.s6) {
                LucideIcon(icon, size: DmIcon.i12)
                Text(title)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(!enabled)
    }

    /// 列表上方那一行上传进度（原型 `.up-row`，常驻不藏弹窗）。
    ///
    /// 只画**当前这一条**：正在传的，或失败了停在那儿的。传完的与主动取消的
    /// 在批次结束时收掉（`AppState.finishUploadBatch`）。
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

    private func uploadIcon(_ item: UploadQueue.Item) -> String {
        if case .failed = item.state { return "circle-x" }
        return item.isDirectory ? "folder-plus" : "upload"
    }

    private func uploadTone(_ item: UploadQueue.Item) -> DmUploadTone {
        if case .failed = item.state { return .danger }
        return .normal
    }

    private func uploadTitle(_ item: UploadQueue.Item) -> String {
        switch item.state {
        case .failed: return "上传失败 \(item.name)"
        case .waiting: return "等待上传 \(item.name)"
        default: return item.isDirectory ? "正在新建 \(item.name)" : "正在上传 \(item.name)"
        }
    }

    /// 明细：速率 · 已传 / 总量 · 剩余，末尾挂一句队列里还剩几项。
    ///
    /// 分母用**这一条请求要发的字节数**（`expected`，含 multipart 段头）而不是文件
    /// 本身的大小 —— 后者会算出 100.1% 这种数。速率与剩余时间在首个样本到达前不写。
    private func uploadDetail(_ item: UploadQueue.Item) -> String {
        var parts: [String] = []
        if case .failed(let reason) = item.state {
            parts.append(reason)
            if item.sent > 0 {
                parts.append("已传 \(FileEntry.byteText(item.sent)) 不会保留")
            }
        } else if !item.isDirectory {
            if item.rate > 0 {
                parts.append("\(FileEntry.byteText(Int64(item.rate)))/s")
            }
            parts.append("已传 \(FileEntry.byteText(item.sent)) / \(FileEntry.byteText(totalBytes(item)))")
            if let left = remainingText(item) { parts.append(left) }
        }
        if uploads.queuedCount > 0 {
            parts.append("队列还有 \(uploads.queuedCount) 项")
        }
        return parts.joined(separator: " · ")
    }

    /// 分母：进度回调报过就用它，还没报过先拿文件本身的大小撑一下显示。
    private func totalBytes(_ item: UploadQueue.Item) -> Int64 {
        item.expected > 0 ? item.expected : item.byteCount
    }

    private func remainingText(_ item: UploadQueue.Item) -> String? {
        let total = totalBytes(item)
        guard item.rate > 0, total > item.sent else { return nil }
        let seconds = Double(total - item.sent) / item.rate
        guard seconds >= 1 else { return nil }
        if seconds < 60 { return "剩余约 \(Int(seconds.rounded())) 秒" }
        return "剩余约 \(Int((seconds / 60).rounded())) 分"
    }

    private func uploadProgress(_ item: UploadQueue.Item) -> Double? {
        if case .failed = item.state { return nil }
        let total = totalBytes(item)
        guard !item.isDirectory, total > 0 else { return nil }
        return Double(item.sent) / Double(total)
    }

    /// 行右侧的动作：传着的时候是「取消」，失败之后是「重试」与「移除」。
    @ViewBuilder
    private func uploadActions(_ item: UploadQueue.Item) -> some View {
        if case .failed = item.state {
            HStack(spacing: DmSpace.s8) {
                Button("重试") {
                    guard let manager = state.sessionManager else { return }
                    uploads.retry(manager: manager)
                }
                .buttonStyle(SecondaryButtonStyle())
                IconButton(iconName: "x") {
                    uploads.dropFailed()
                }
            }
        } else {
            Button("取消") { state.cancelUploads() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private var content: some View {
        if search.isActive {
            searchContent
        } else if let message = model.errorMessage {
            FilesNotice(
                icon: "triangle-alert",
                title: "读不到这个目录",
                note: message,
                actionTitle: "重试"
            ) {
                Task { await model.refresh(state.sessionManager, username: state.username) }
            }
        } else if model.isLoading && model.entries.isEmpty {
            FilesNotice(icon: "loader", title: "正在载入…", note: "列一层目录，一页 \(FileBrowser.pageSize) 项")
        } else if model.entries.isEmpty {
            FilesNotice(icon: "folder", title: "这个目录是空的", note: model.currentPath)
        } else {
            FilesTable(
                model: model,
                manager: state.sessionManager,
                onSelect: { entry, mode in model.select(entry, mode: mode) },
                onOpen: { entry in
                    guard entry.isDirectory else { return }
                    Task { await model.open(entry.path, on: state.sessionManager) }
                },
                onContext: { entry, point in state.openFileMenu(for: entry, at: point) }
            )
            .overlay { dropHighlight }
            .overlay {
                FileDropCatcher(isTargeted: dropTarget) { urls in state.upload(urls: urls) }
            }
        }
    }

    /// 搜索态：进度行 / 空结果 / 结果列表三选一（列表被结果整块替掉）。
    ///
    /// 「正在重试」是一等状态、不是错误 —— 服务端会随机返回假空（应答里连 `total`
    /// 都没有），原型把这一行画成与上传行同款的一条，这里照它落。
    @ViewBuilder
    private var searchContent: some View {
        if search.isRunning {
            searchRow(icon: "loader", title: "正在搜索…", detail: search.progressNote,
                      tone: .normal, actionTitle: "停止") {
                Task { await state.cancelFileSearch() }
            }
        } else if search.phase == .failed {
            searchRow(icon: "triangle-alert", title: "没能搜成",
                      detail: search.errorMessage ?? "", tone: .danger, actionTitle: "重试") {
                Task { await state.submitFileSearch() }
            }
        } else if search.hits.isEmpty {
            FilesNotice(
                icon: "search",
                title: "没有匹配的项",
                note: "在「\(search.folder)」里找「\(search.query)」"
            )
        } else {
            SearchHitList(search: search, manager: state.sessionManager) { hit in
                Task { await state.openSearchHit(hit) }
            }
        }
    }

    /// 搜索进度 / 失败那一行（与上传行同款，`DmUploadRow`）。
    private func searchRow(icon: String, title: String, detail: String,
                           tone: DmUploadTone, actionTitle: String,
                           action: @escaping () -> Void) -> some View {
        DmUploadRow(icon: icon, title: title, detail: detail, tone: tone) {
            Button(actionTitle, action: action)
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, DmSpace.s24)
        .padding(.bottom, DmSpace.s12)
    }

    /// 拖入时的那一圈提示：主色虚线描边 + `accent-soft` 底（与树上拖动目标的形态同款）。
    /// 整块不允许命中 —— 它只报状态，点击照旧落到下面的行上。
    @ViewBuilder
    private var dropHighlight: some View {
        if uploads.dropTargeted {
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
                .overlay(
                    Text("松手即传到「\(model.currentPath)」")
                        .font(.system(size: DmText.t13, weight: .medium))
                        .foregroundColor(Color.dmAccent2)
                )
                .padding(DmSpace.s8)
                .allowsHitTesting(false)
        }
    }

    /// 状态栏（原型 `.statusbar`）：上沿发丝、左右 `s24`、上下 `s8`、字 11 / `ink-3`。
    /// 搜索态报结果条数，浏览态报条数与选中合计。
    private var statusBar: some View {
        HStack(spacing: DmSpace.s12) {
            if search.isActive {
                Text(search.resultNote)
            } else if model.selection.isEmpty {
                Text("共 \(model.displayTotal) 项")
            } else {
                Text("已选中 \(model.selection.count) 项\(byteSuffix)")
            }
            Spacer(minLength: 0)
            Text("\(model.shares.count) 个共享夹")
        }
        .font(.system(size: DmText.t11))
        .monospacedDigit()
        .foregroundColor(Color.dmInk3)
        .padding(.horizontal, DmSpace.s24)
        .padding(.vertical, DmSpace.s8)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
    }

    /// 合计大小后缀。三条都可能出现，各自写清楚：
    ///   · 算出来的合计（文件按列表自带的 `size`，算过的目录按 `DirSize` 的数）；
    ///   · 「正在计算…」—— `DirSize` 没有 `progress` 字段，给不出百分比；
    ///   · 「N 个文件夹未计」—— 目录体积**不预先算**（按需触发），没算过的那几个不能
    ///     装作计进去了。只选了目录时这里就是全部 —— 写「0 B」等于说这些目录是空的。
    private var byteSuffix: String {
        var parts: [String] = []
        let bytes = model.selectionBytes
        if bytes > 0 { parts.append(FileEntry.byteText(bytes)) }
        if model.isMeasuring {
            parts.append("正在计算…")
        } else if model.unmeasuredDirectoryCount > 0 {
            parts.append("\(model.unmeasuredDirectoryCount) 个文件夹未计")
        }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }
}

// MARK: - 目录树

/// 共享夹是第一层，逐级懒加载（每展开一层才拉一层，按名称正序）。
/// 含子目录的行在右侧给箭头：点箭头展开 / 收起，点行本身是进入该目录，两件事分开。
private struct FileTreePanel: View {
    let model: FileBrowser
    let manager: SessionManager?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("共享文件夹")
                .font(.system(size: DmText.t11, weight: .bold))
                .kerning(0.66)
                .foregroundColor(Color.dmInk3)
                .padding(.horizontal, DmSpace.s16)
                .padding(.top, DmSpace.s14)
                .padding(.bottom, DmSpace.s8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DmSpace.s2) {
                    ForEach(model.treeRows) { row in
                        FileTreeRow(row: row, model: model, manager: manager)
                    }
                }
                .padding(.horizontal, DmSpace.s8)
                .padding(.bottom, DmSpace.s12)
            }
        }
        .frame(width: FilesMetrics.treeWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // 与内容区侧栏同一处理：同底、靠一根发丝分界（`LibraryRail` 那条）。
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.dmLine).frame(width: DmLine.hairline)
        }
    }
}

private struct FileTreeRow: View {
    let row: FileBrowser.TreeRow
    let model: FileBrowser
    let manager: SessionManager?

    @State private var isHovered = false

    /// 当前目录所在的那一行走**列表行（浅底轨）**：`accent-soft` + `accent-2`。
    private var isCurrent: Bool { row.kind != .more && model.currentPath == row.path }

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            if row.kind != .more {
                LucideIcon(icon, size: DmIcon.i14)
                    .foregroundColor(ListRowState.secondaryForeground(isSelected: isCurrent, hovered: isHovered))
            }
            Text(row.name)
                .font(.system(size: DmText.t13))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DmSpace.s4)
            if row.kind != .more {
                toggle
            }
        }
        .padding(.horizontal, DmSpace.s8)
        .padding(.vertical, DmSpace.s6)
        // 缩进按层数长（原型 `.ind` = 20 / `.ind2` = 32，即基础 8 + 每层 12）。
        .padding(.leading, CGFloat(row.depth) * DmSpace.s12)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r6))
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: activate)
        .help(row.kind == .more ? "展开剩下的目录" : row.path)
    }

    private var icon: String {
        switch row.kind {
        case .share: return row.path == "/homes" ? "house" : "server"
        case .folder: return model.isExpanded(row.path) ? "folder-open" : "folder"
        case .more: return "chevron-down"
        }
    }

    private var textColor: Color {
        // 「还有 N 个」是一行说明，不是目录 —— 它走中性档，不参与选中轨道。
        guard row.kind != .more else { return isHovered ? Color.dmInk : Color.dmInk3 }
        return ListRowState.foreground(isSelected: isCurrent, hovered: isHovered)
    }

    private var background: Color {
        guard row.kind != .more else { return Color.clear }
        return ListRowState.background(isSelected: isCurrent, hovered: isHovered && !isCurrent)
    }

    /// 展开箭头（原型 `.tgl`：18×18、`r-4`、悬停浮一层底）。与点行分开 ——
    /// 它是自己的命中区，点了不会顺带进入该目录。
    private var toggle: some View {
        Button {
            Task { await model.toggleExpand(row.path, on: manager) }
        } label: {
            LucideIcon("chevron-right", size: DmIcon.i12)
                .foregroundColor(isHovered ? Color.dmInk2 : Color.dmInk3)
                .rotationEffect(.degrees(model.isExpanded(row.path) ? 90 : 0))
                .frame(width: FilesMetrics.toggleSide, height: FilesMetrics.toggleSide)
                .background(
                    RoundedRectangle(cornerRadius: DmRadius.r4)
                        .fill(isHovered ? Color.dmPanel3 : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func activate() {
        switch row.kind {
        case .more:
            model.revealAllChildren(row.path)
        case .share, .folder:
            Task { await model.open(row.path, on: manager) }
        }
    }
}

// MARK: - 表

/// 表的排版参数。列宽与「哪一列右对齐」都跟着 `FileSortField` —— 列的定义只此一处，
/// 表头与行同取一档（两边各自写死数字就会错位）。
enum FilesMetrics {
    static let padH: CGFloat = 10
    /// 表头行高：cell 上下 `s8` + 11 字 + 底下一根发丝（与曲库表同一档）。
    static let headerHeight: CGFloat = 30
    /// 行高（原型 `.tbl td` 上下 `s8` + 13 字）。
    static let rowHeight: CGFloat = 34
    /// 名称列自适应、**保底 180** —— 主区一挤自适应列会被压没，整列凭空消失。
    static let nameMinWidth: CGFloat = 180
    /// 目录树宽（原型 `.tree{width:240px}`）。
    static let treeWidth: CGFloat = 240
    /// 树上展开箭头那一格（原型 `.tgl` 18×18）。
    static let toggleSide: CGFloat = 18
    /// 名称列左侧那个图形格（缩略图或图标，原型 `.tbl td.tc`）。
    static let glyphSide: CGFloat = 28
    /// 勾选列宽（原型 `colgroup` 首列 32、`td.cbc` 且右侧不留白）。
    static let checkWidth: CGFloat = 32
    /// 搜索框宽（原型 `.toolbar .right` 里 `.searchbox{width:200px}`）。
    /// 与选目标弹窗那个不同档：那个在弹窗里占满一行，这个挤在工具条右端。
    static let searchWidth: CGFloat = 200
    /// 固定列拖宽后的下限。再窄右对齐的数字格就贴边了。
    static let minColumnWidth: CGFloat = 60

    /// 内容宽 = `max(视口, 勾选列 + 名称保底 + 固定列之和)`；视口更宽时名称列吸收余量。
    /// 固定列宽优先取拖宽覆盖（`widths`），没有就用 `FileSortField` 的默认值。
    static func contentWidth(viewport: CGFloat, widths: [FileSortField: CGFloat] = [:]) -> CGFloat {
        var fixed = CGFloat.zero
        for field in FileSortField.allCases {
            fixed += widths[field] ?? (field.width ?? 0)
        }
        return max(viewport, checkWidth + nameMinWidth + fixed)
    }
}

/// 列的宽度与对齐：名称列自适应、`size` 列右对齐（数值列）。
/// 一个 `frame` 调用同时表达两种（固定列的 min == max，就钉死成那个宽）。
/// 宽度优先取拖宽覆盖（`override`），没有就退回 `FileSortField.width` 默认值。
private struct FileColumnWidth: ViewModifier {
    let field: FileSortField
    /// 拖宽覆盖（模型 `columnWidths` 里那份）。`nil` = 用默认宽。
    var override: CGFloat?

    func body(content: Content) -> some View {
        let fixed = override ?? field.width
        return content.frame(
            minWidth: fixed ?? FilesMetrics.nameMinWidth,
            maxWidth: fixed ?? .infinity,
            alignment: field.isNumeric ? .trailing : .leading
        )
    }
}

private struct FilesTable: View {
    let model: FileBrowser
    let manager: SessionManager?
    let onSelect: (FileEntry, FileBrowser.SelectMode) -> Void
    let onOpen: (FileEntry) -> Void
    /// 行上按右键：把「哪一行」与根视图坐标交上去，菜单由根视图摆。
    let onContext: (FileEntry, CGPoint) -> Void

    /// 行上的选法看**当前按住的修饰键**：Shift 范围选、Cmd 加选、都没有就是单选。
    ///
    /// SwiftUI 的手势回调里拿不到修饰键，读一次全局状态即可 —— 那就是用户按下那一刻
    /// 的状态。这条只影响真鼠标点击；冒烟通路走 `select=` 指令，直接给模式。
    static func mode() -> FileBrowser.SelectMode {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) { return .range }
        if flags.contains(.command) { return .toggle }
        return .replace
    }

    var body: some View {
        // 视口窄于内容时横向滚动（表头与行在同一个滚动容器里，一起滚）。
        GeometryReader { geo in
            let width = FilesMetrics.contentWidth(viewport: geo.size.width,
                                                  widths: model.columnWidths)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    header

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.entries) { entry in
                                FileRow(
                                    entry: entry,
                                    // 目录的大小要问 `DirSize`（按需算的那一份），
                                    // 所以这一格的文案从模型拿 —— 文件是列表自带的 `size`。
                                    sizeText: model.sizeText(for: entry),
                                    isSelected: model.isSelected(entry.path),
                                    isChecked: model.isSelected(entry.path),
                                    manager: manager,
                                    columnWidths: model.columnWidths
                                ) {
                                    onSelect(entry, Self.mode())
                                } onToggleCheck: {
                                    model.toggle(entry)
                                } onOpen: {
                                    onOpen(entry)
                                } onContext: { point in
                                    onContext(entry, point)
                                }
                            }
                            if model.hasMore {
                                FileLoadMoreRow(
                                    loaded: model.entries.count,
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
    }

    /// 表头：最左是**全选位**（半选表示选了一部分），其余点一格 = 按这一列排，
    /// 同一格再点换方向；只有当前列带箭头（`accent-2`）。
    ///
    /// 排序的点击走 AppKit 接管层 `HeaderGrabber`（`isDraggable: false`）—— 合成鼠标
    /// 事件进不了 SwiftUI 的手势系统，走这一层冒烟通路才验得动「点表头 → 排序」；
    /// 各格位置也由它自报（合成点击要按位置落到格子上）。
    private var header: some View {
        HStack(spacing: 0) {
            checkAllCell
            ForEach(FileSortField.allCases) { field in
                headerCell(field)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
    }

    /// 表头全选位。`isOn` 与半选互斥 —— 两个都给时 `DmCheckbox` 只认半选。
    private var checkAllCell: some View {
        Button {
            model.toggleSelectAll()
        } label: {
            DmCheckbox(isOn: model.isAllSelected, isIndeterminate: model.isPartiallySelected)
                .padding(.leading, FilesMetrics.padH)
                .frame(width: FilesMetrics.checkWidth, height: FilesMetrics.headerHeight,
                       alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.isAllSelected ? "取消全选" : "全选这一页")
    }

    private func headerCell(_ field: FileSortField) -> some View {
        let isActive = model.sort?.field == field
        return HStack(spacing: DmSpace.s2) {
            Text(field.label)
                .font(.system(size: DmText.t11, weight: .bold))
                .kerning(0.33)
            if isActive {
                LucideIcon(model.sort?.ascending == false ? "chevron-down" : "chevron-up",
                           size: DmIcon.i10)
                    .foregroundColor(Color.dmAccent2)
            }
        }
        .foregroundColor(Color.dmInk3)
        .lineLimit(1)
        .padding(.horizontal, FilesMetrics.padH)
        .frame(height: FilesMetrics.headerHeight)
        .modifier(FileColumnWidth(field: field, override: model.columnWidths[field]))
        .contentShape(Rectangle())
        .overlay {
            HeaderGrabber(
                onClick: { Task { await model.toggleSort(field, on: manager) } },
                onDrag: { _ in },
                onDrop: { _ in },
                isDraggable: false,
                onFrame: { model.headerFrames[field] = $0 }
            )
            // 🔴 固定列要把接管层从右缘让出 `hitWidth`：平台视图命中测试
            // 先于 SwiftUI 层，整格罩住时调宽把手收不到事件（2026-10-18
            // 用户实抓）。名称列自适应、没有把手，不用让。
            .padding(.trailing, field.width != nil ? ColumnResizer.hitWidth : 0)
        }
        // 调宽把手：只占右缘 7px 热区，格子中间仍归点击排序。与曲库表
        // 同一套（`ColumnResizer`）。
        .overlay(alignment: .trailing) {
            if field.width != nil {
                ColumnResizer(width: model.effectiveWidth(field)) {
                    model.setColumnWidth($0, for: field)
                }
            }
        }
        // 名称列右缘的常驻分隔线：固定列的那根由把手画，这里补上同一根。
        .overlay(alignment: .trailing) {
            if field.width == nil {
                Rectangle()
                    .fill(Color.dmLine2)
                    .frame(width: DmLine.base)
            }
        }
        .help("点按按这一列排序")
    }
}

struct FileRow: View {
    let entry: FileEntry
    /// 大小那一格的文案。**不由 `entry.sizeText` 直接给** —— 目录的体积是算出来的
    /// （`FileBrowser.sizeText(for:)`），文件才是列表自带的那一份。
    let sizeText: String
    let isSelected: Bool
    /// 勾选框状态。与 `isSelected` 目前同源（选中即勾上），分开写是为了让「选中」
    /// 与「勾上」两件事各自可改 —— 表头全选、Cmd 加选都只动其中一侧时不必两边一起动。
    let isChecked: Bool
    let manager: SessionManager?
    /// 列宽覆盖（拖表头右缘改的），与表头共用同一份；空 = 全按默认宽。
    var columnWidths: [FileSortField: CGFloat] = [:]
    let onSelect: () -> Void
    let onToggleCheck: () -> Void
    let onOpen: () -> Void
    /// 右键。位置是**根视图坐标**（左上原点）—— 菜单挂在根上按它摆。
    let onContext: (CGPoint) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggleCheck) {
                DmCheckbox(isOn: isChecked)
                    .padding(.leading, FilesMetrics.padH)
                    .frame(width: FilesMetrics.checkWidth, height: FilesMetrics.rowHeight,
                           alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: DmSpace.s8) {
                FileGlyph(entry: entry, manager: manager)
                Text(entry.name)
                    .font(.system(size: DmText.t13, weight: .medium))
                    .foregroundColor(ListRowState.primaryForeground(isSelected: isSelected))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // 名称被省略号吃掉时悬停看全名。
                    .help(entry.name)
            }
            .padding(.horizontal, FilesMetrics.padH)
            .modifier(FileColumnWidth(field: .name))

            // 大小格吃参数不吃 `entry.sizeText` —— 目录的体积在 `sizes` 缓存里，
            // 条目本身永远没有（`List` 不给目录字节数）。
            cell(sizeText, field: .size)
            cell(entry.modifiedText, field: .mtime)
        }
        .frame(height: FilesMetrics.rowHeight)
        .background(ListRowState.background(isSelected: isSelected, hovered: isHovered && !isSelected))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2, perform: onOpen)
        // 右键：位置交给根视图摆菜单 —— 菜单要浮在整个窗口之上，画在行里会被后面的行
        // 盖住、也会被滚动区裁掉（与歌曲右键同一条理由）。这一层只接右键，其余事件穿透。
        .overlay {
            RightClickCatcher(onRightClick: onContext)
        }
    }

    /// 一格（大小 / 修改时间）：字 12、`ink-3`；数值列右对齐、等宽数字。
    private func cell(_ text: String, field: FileSortField) -> some View {
        Text(text)
            .font(.system(size: DmText.t12))
            .foregroundColor(ListRowState.secondaryForeground(isSelected: isSelected, hovered: isHovered))
            .lineLimit(1)
            .monospacedDigit()
            .padding(.horizontal, FilesMetrics.padH)
            .modifier(FileColumnWidth(field: field, override: columnWidths[field]))
            .help(text)
    }
}

/// 名称列左侧那一格图形：图片与视频走 28 的缩略图（取不到退回图标），其余按
/// `additional.type` 给类型图标。**固定 28 宽**，各行名称因此对齐。
///
/// 不做成 private：删除确认弹窗列清单时也要按同一套分派给图标，两处各写一份
/// 迟早分岔（类型不止一种，压同一个图形等于没分）。
struct FileGlyph: View {
    let entry: FileEntry
    let manager: SessionManager?

    @State private var image: Data?

    var body: some View {
        ZStack {
            if entry.hasThumbnail {
                RoundedRectangle(cornerRadius: DmRadius.r8).fill(Color.dmPanel2)
                if let image, let nsImage = NSImage(data: image) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    glyph
                }
            } else {
                glyph
            }
        }
        .frame(width: FilesMetrics.glyphSide, height: FilesMetrics.glyphSide)
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r8))
        .task(id: entry.path) {
            guard entry.hasThumbnail, image == nil, let manager else { return }
            image = await ThumbStore.shared.thumbnail(manager: manager, path: entry.path)
        }
    }

    private var glyph: some View {
        LucideIcon(Self.icon(of: entry), size: DmIcon.i16)
            .foregroundColor(entry.isDirectory ? Color.dmInk2 : Color.dmInk3)
    }

    /// 类型图标按 `additional.type` 分派，不从文件名切扩展名。
    static func icon(of entry: FileEntry) -> String {
        switch entry.kind {
        case .folder: return "folder"
        case .image: return "file-image"
        case .video: return "file-video"
        case .audio: return "file-audio"
        case .archive: return "file-archive"
        case .text: return "file-text"
        case .other: return "file"
        }
    }
}

/// 搜索结果列表。
///
/// 与浏览表**不是同一张表**：搜索结果只有 `name` / `path` / `isdir` 三个字段
/// （`additional` 不认），给不出大小与时间，也就没什么可排的。所以这里走**平铺结果行**
/// —— 名称 + 右侧「所在位置」，形态与选目标弹窗里那些命中行同款（那一处也是
/// 「名字 + 它在哪里」）。分页沿用同一行「已载入 N 项，继续载入」。
///
/// **行不可多选**：搜索是「找到它」那一步，点一行就跳回浏览态到它所在的位置，
/// 复制 / 移动 / 删除在那边做（那边才有选中集合）。
private struct SearchHitList: View {
    let search: FileSearch
    let manager: SessionManager?
    let onOpen: (FileSearchHit) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(search.hits) { hit in
                    SearchHitRow(hit: hit) { onOpen(hit) }
                }
                if search.hasMore {
                    FileLoadMoreRow(
                        loaded: search.hits.count,
                        isLoading: search.isLoadingMore
                    ) {
                        Task { await search.loadMore(on: manager) }
                    }
                }
            }
        }
    }
}

/// 搜索结果的一行：图形格（28，与表行同宽所以名字对齐）+ 名称 + 右侧所在位置。
///
/// 🔴 图标只分「目录 / 文件」两档：搜索结果里**没有 `additional.type`**，而类型图标
/// 是按它分派的（不从文件名切扩展名 —— 大小写与多后缀都会判错）。所以文件一律给
/// 通用 `file`，不猜它是不是音频。
private struct SearchHitRow: View {
    let hit: FileSearchHit
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon(hit.isDirectory ? "folder" : "file", size: DmIcon.i16)
                .foregroundColor(hit.isDirectory ? Color.dmInk2 : Color.dmInk3)
                .frame(width: FilesMetrics.glyphSide, height: FilesMetrics.glyphSide)

            Text(hit.name)
                .font(.system(size: DmText.t13, weight: .medium))
                .foregroundColor(ListRowState.primaryForeground(isSelected: false))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: DmSpace.s12)

            // 「在哪儿」这一格：同名的文件到处都是，结果行不写位置等于没找到。
            Text(DestinationPicker.shortPath(hit.parent))
                .font(.system(size: DmText.t12))
                .foregroundColor(ListRowState.secondaryForeground(isSelected: false, hovered: isHovered))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, FilesMetrics.padH)
        .frame(height: FilesMetrics.rowHeight)
        .background(ListRowState.background(isSelected: false, hovered: isHovered))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: onOpen)
    }
}

/// 分页那一行：滚到底自动要下一页，也可以点。
private struct FileLoadMoreRow: View {    let loaded: Int
    let isLoading: Bool
    let onLoad: () -> Void

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon(isLoading ? "loader" : "chevron-down", size: DmIcon.i12)
                .foregroundColor(Color.dmInk3)
            Text(isLoading ? "正在载入…" : "已载入 \(loaded) 项，继续载入")
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FilesMetrics.padH)
        .frame(height: FilesMetrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onLoad)
        .onAppear(perform: onLoad)
    }
}

/// 空态 / 载入 / 错误三种静场（与曲库页的 `LibraryNotice` 同一形态）。
private struct FilesNotice: View {
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

// MARK: - 写操作弹窗

/// 文件写操作的三张弹窗：新建文件夹 / 重命名 / 删除确认。
///
/// 挂在根视图（`RootView` 的 `.dmModal`）而不是这一页的局部浮层：遮罩要盖住整个窗口
/// （连播放条一起）—— 原型的 `.mask{position:absolute;inset:0}` 也是这个意思。
/// 请求挂在 `AppState.fileDialog` 上，所以冒烟通路能在视图之外把它摆出来截图。
struct FileDialogCard: View {
    @Environment(AppState.self) private var state
    let dialog: AppState.FileDialog

    /// 输入框里的名字。新建给默认名；重命名给**主干**（不含扩展名，macOS 惯例）。
    @State private var name: String
    /// 本地先判出来的问题。有值时确认钮灰着，也不发请求。
    @State private var problem: String?

    @FocusState private var isFocused: Bool

    init(dialog: AppState.FileDialog) {
        self.dialog = dialog
        _name = State(initialValue: Self.initialName(dialog))
    }

    var body: some View {
        switch dialog {
        case .newFolder(let directory):
            nameDialog(title: "新建文件夹", confirm: "创建", in: directory)
        case .rename(let entry):
            nameDialog(title: "重命名", confirm: "重命名",
                       in: state.files.currentPath, entry: entry)
        case .delete(let entries):
            deleteDialog(entries)
        }
    }

    // MARK: - 单输入框那两张

    /// 新建文件夹与重命名共用：位置行 + 名称字段 + 提示行。**输入框里只有主干**，
    /// 扩展名以静态文本跟在框后 —— 改名时最常见的手误就是把 `.mp3` 一起删掉。
    private func nameDialog(title: String, confirm: String,
                            in directory: String, entry: FileEntry? = nil) -> some View {
        DmModalCard(title: title, onClose: { state.closeFileDialog() }) {
            locationRow(directory)

            VStack(alignment: .leading, spacing: DmSpace.s6) {
                FormLabel("名称")
                HStack(spacing: DmSpace.s6) {
                    TextField("", text: $name)
                        .focused($isFocused)
                        .formField(on: .panel)
                    if let entry {
                        let suffix = Self.extensionSuffix(of: entry)
                        if !suffix.isEmpty {
                            Text(suffix)
                                .font(.system(size: DmText.t13))
                                .foregroundColor(Color.dmInk3)
                        }
                    }
                }
                hintRow(problem ?? "不能包含 \\ / : * ? \" < > | 这些字符。", isBad: problem != nil)
            }
        } foot: {
            Button("取消") { state.closeFileDialog() }
                .buttonStyle(SecondaryButtonStyle())
            Button(confirm, action: submit)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(problem != nil)
        }
        // 初值先过一遍校验（重命名时初值可能与目录里另一项同名），再把光标放进框里。
        .onAppear {
            validate(name)
            isFocused = true
        }
        .onChange(of: name) { validate(name) }
    }

    /// 弹窗里那行「位置」（原型 `.mv-path`）：`music › 华语 › 2024`。
    /// 路径从尾部截断 —— 用户要确认的是「在哪个目录」，末尾那一段最要紧。
    private func locationRow(_ directory: String) -> some View {
        HStack(spacing: DmSpace.s8) {
            Text("位置")
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
            Text(DestinationPicker.shortPath(directory))
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
    }

    /// 输入框下面那行提示（原型 `.hint`）：常态讲字符规则，有问题时换成人话并转 danger。
    private func hintRow(_ text: String, isBad: Bool) -> some View {
        HStack(spacing: DmSpace.s6) {
            LucideIcon(isBad ? "triangle-alert" : "info", size: DmIcon.i12)
                .foregroundColor(isBad ? Color.dmDangerInk : Color.dmInk3)
            Text(text)
                .font(.system(size: DmText.t11))
                .foregroundColor(isBad ? Color.dmDangerInk : Color.dmInk3)
            Spacer(minLength: 0)
        }
    }

    private func submit() {
        switch dialog {
        case .newFolder:
            Task { await state.createFolder(named: name) }
        case .rename(let entry):
            Task { await state.rename(entry, to: Self.fullName(name, of: entry)) }
        case .delete:
            break
        }
    }

    /// 本地先判：空名、非法字符、重名。**重命名时排除自己那条** —— 实测只改大小写
    /// 是合法的（`same6.txt` → `Same6.TXT`），把「与我同名」当重名会把这种改名拦掉。
    private func validate(_ text: String) {
        switch dialog {
        case .newFolder(let directory):
            problem = AppState.nameProblem(text, among: entries(in: directory))
        case .rename(let entry):
            problem = AppState.nameProblem(Self.fullName(text, of: entry),
                                           among: state.files.entries, excluding: entry)
        case .delete:
            problem = nil
        }
    }

    /// 建文件夹那一层的清单，用来判重名。建在当前浏览目录时就是列表里那份；
    /// 建在选目标弹窗里那层时，用弹窗**已经拉过**的那一份，不为这个再发一次请求
    /// （没拉过就给空 —— 少一次本地拦，服务端那条路还有 `exists` 兜着）。
    private func entries(in directory: String) -> [FileEntry] {
        if directory == state.files.currentPath { return state.files.entries }
        return state.transfers.picker.loadedChildren(of: directory) ?? []
    }

    // MARK: - 删除确认

    private func deleteDialog(_ entries: [FileEntry]) -> some View {
        DmModalCard(title: Self.deleteTitle(entries), onClose: { state.closeFileDialog() }) {
            DmDangerNote(text: "删除后不进回收站，无法恢复。文件夹里的内容会一并删除。")
            DmPickList {
                ForEach(entries) { entry in
                    DmPickRow(
                        icon: FileGlyph.icon(of: entry),
                        title: entry.name,
                        note: Self.pickNote(of: entry)
                    )
                }
            }
        } foot: {
            Button("取消") { state.closeFileDialog() }
                .buttonStyle(SecondaryButtonStyle())
            Button("删除") {
                Task { await state.delete(entries) }
            }
            .buttonStyle(DangerButtonStyle())
        }
    }

    // MARK: - 名字这一套

    /// 输入框的初值。新建给「新建文件夹」（原型同款）；重命名给主干。
    static func initialName(_ dialog: AppState.FileDialog) -> String {
        switch dialog {
        case .newFolder: return "新建文件夹"
        case .rename(let entry): return stem(of: entry)
        case .delete: return ""
        }
    }
    /// 去掉扩展名的主干。**目录不切** —— 专辑目录常写成 `2018.2019` 这种，
    /// 拿 `pathExtension` 一切就剩「2018」，改名会改掉一半。
    static func stem(of entry: FileEntry) -> String {
        guard !entry.isDirectory else { return entry.name }
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? entry.name : (entry.name as NSString).deletingPathExtension
    }

    /// 主干拼回扩展名 —— 提交时用。目录原样返回。
    static func fullName(_ stem: String, of entry: FileEntry) -> String {
        guard !entry.isDirectory else { return stem }
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// 跟在输入框后面的扩展名（含点）。目录与非扩展名文件给空串。
    static func extensionSuffix(of entry: FileEntry) -> String {
        guard !entry.isDirectory else { return "" }
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? "" : ".\(ext)"
    }

    /// 删除确认的标题：单项报名字，多项报个数。
    static func deleteTitle(_ entries: [FileEntry]) -> String {
        guard entries.count != 1 else { return "删除「\(entries[0].name)」？" }
        return "删除 \(entries.count) 个项目？"
    }

    /// 清单每行右侧那一段。目录不给体积 —— 那要 `DirSize`（下一批），
    /// 现在写「0 B」等于说这个目录是空的。
    static func pickNote(of entry: FileEntry) -> String {
        entry.isDirectory ? "文件夹" : entry.sizeText
    }
}

/// 上传撞名的三选弹窗（原型「同名冲突」那张）。
///
/// 为什么必须先问：上传的 `overwrite=false` 撞名**回「成功」但内容不变**（静默跳过），
/// 服务端连冲突都不报；`overwrite=true` 才是真覆盖。所以「传上去会怎样」只能由这里
/// 问清楚，再拿用户的选择去组请求。
///
/// 对照块给出「来源 / 目标已有」两份的大小与时间 —— 用户要判断的正是这两份哪个更新。
struct FileConflictCard: View {
    @Environment(AppState.self) private var state
    let prompt: UploadQueue.ConflictPrompt

    @State private var choice: UploadQueue.ConflictChoice = .replace
    @State private var applyToAll = false

    var body: some View {
        DmModalCard(
            title: "已有同名项目",
            onClose: { state.cancelUploads() },
            content: {
                DmCompare(
                    left: DmCompareColumn(title: "来源", lines: [prompt.item.name, sourceDetail]),
                    right: DmCompareColumn(title: "目标已有", lines: [prompt.existing.name, existingDetail])
                )

                VStack(spacing: DmSpace.s6) {
                    option(.replace, title: "替换",
                           note: "用来源覆盖目标，目标那一份不可恢复")
                    option(.keepBoth, title: "保留两者",
                           note: "这一份传上去叫「\(prompt.keptName)」，两份都保留")
                    option(.skip, title: "跳过",
                           note: "这一项不传，其余继续")
                }
            },
            foot: {
                Button("取消") { state.cancelUploads() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("应用") {
                    state.resolveUploadConflict(choice, applyToAll: applyToAll)
                }
                .buttonStyle(PrimaryButtonStyle())
            },
            // 「应用于全部」只在这一批还有别的冲突时出现（原型：它是作用域开关，
            // 不是第四种处理，单选场景不给 —— 少一个要读的控件）。
            lead: prompt.remaining > 1 ? AnyView(applyAllBox) : nil
        )
    }

    private var applyAllBox: some View {
        HStack(spacing: DmSpace.s8) {
            DmCheckbox(isOn: applyToAll)
            Text("应用于全部 \(prompt.remaining) 项")
                .font(.system(size: DmText.t13))
                .foregroundColor(Color.dmInk2)
        }
        .contentShape(Rectangle())
        .onTapGesture { applyToAll.toggle() }
    }

    private func option(_ value: UploadQueue.ConflictChoice, title: String, note: String) -> some View {
        DmOptionRow(title: title, note: note, isOn: choice == value) {
            choice = value
        }
    }

    /// 本机那一份的大小与修改时间。
    private var sourceDetail: String {
        let size = FileEntry.byteText(prompt.item.byteCount)
        guard let date = (try? prompt.item.localURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return size }
        return "\(size) · \(FileEntry.stamp.string(from: date))"
    }

    /// 服务端那一份的同两项（从 `List` 的 `additional` 来；取不到就少写一段）。
    private var existingDetail: String {
        let size = prompt.existing.size.map { FileEntry.byteText($0) } ?? "—"
        guard let modified = prompt.existing.modified else { return size }
        return "\(size) · \(FileEntry.stamp.string(from: modified))"
    }
}

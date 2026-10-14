import AppKit
import SwiftUI

/// 文件管理（只读）。
///
/// 形态照原型 `design/界面原型.html` 的文件管理屏：左侧目录树（共享夹是导航第一层、
/// 逐级懒加载、子层过长只列前几项）+ 右侧（页头与面包屑 / 工具条 / 表 / 状态栏）。
///
/// 这一批是**只读**：浏览、排序、分页、缩略图、下载、从曲库「在文件管理中显示」跳过来。
/// 写操作（新建 / 上传 / 改名 / 复制 / 移动 / 删除）、搜索（任务式、带重试）与
/// 勾选框那列多选留给下一批 —— 多选的价值在批量操作，而批量操作全是写操作，
/// 现在铺一列能勾却没出口的勾选框就是空壳控件。
struct FilesView: View {
    @Environment(AppState.self) private var state

    /// 状态挂在 `AppState` 上，不是本视图的 `@State` —— 与曲库同一理由：换模块、
    /// 从曲库跳过来，都不该把浏览位置丢掉。
    private var model: FileBrowser { state.files }

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

    /// 工具条：原型那一排写操作（新建 / 上传 / 复制到… / 移动到…）全是写操作，
    /// 本批只留「下载」一个真能用的入口，右端写明这一批的范围。
    private var toolbar: some View {
        HStack(spacing: DmSpace.s8) {
            Button("下载") {
                guard let entry = model.selectedEntry else { return }
                Task { await state.download(file: entry) }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.selectedEntry?.isDirectory != false)

            Spacer(minLength: 0)

            Text("只读 · 写操作与搜索在下一批")
                .font(.system(size: DmText.t11))
                .foregroundColor(Color.dmInk3)
        }
        .padding(.horizontal, DmSpace.s24)
        .padding(.bottom, DmSpace.s12)
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.errorMessage {
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
            FilesTable(model: model, manager: state.sessionManager) { entry in
                model.select(entry)
            } onOpen: { entry in
                guard entry.isDirectory else { return }
                Task { await model.open(entry.path, on: state.sessionManager) }
            }
        }
    }

    /// 状态栏（原型 `.statusbar`）：上沿发丝、左右 `s24`、上下 `s8`、字 11 / `ink-3`。
    private var statusBar: some View {
        HStack(spacing: DmSpace.s12) {
            if let entry = model.selectedEntry {
                Text("已选中 1 项 · \(entry.sizeText.isEmpty ? "—" : entry.sizeText)")
            } else {
                Text("共 \(model.displayTotal) 项")
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

    /// 内容宽 = `max(视口, 名称保底 + 固定列之和)`；视口更宽时名称列吸收余量。
    static func contentWidth(viewport: CGFloat) -> CGFloat {
        let fixed = FileSortField.allCases.reduce(CGFloat.zero) { $0 + ($1.width ?? 0) }
        return max(viewport, nameMinWidth + fixed)
    }
}

/// 列的宽度与对齐：名称列自适应、`size` 列右对齐（数值列）。
/// 一个 `frame` 调用同时表达两种（固定列的 min == max，就钉死成那个宽）。
private struct FileColumnWidth: ViewModifier {
    let field: FileSortField

    func body(content: Content) -> some View {
        let fixed = field.width
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
    let onSelect: (FileEntry) -> Void
    let onOpen: (FileEntry) -> Void

    var body: some View {
        // 视口窄于内容时横向滚动（表头与行在同一个滚动容器里，一起滚）。
        GeometryReader { geo in
            let width = FilesMetrics.contentWidth(viewport: geo.size.width)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    header

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.entries) { entry in
                                FileRow(
                                    entry: entry,
                                    isSelected: model.selectedPath == entry.path,
                                    manager: manager
                                ) {
                                    onSelect(entry)
                                } onOpen: {
                                    onOpen(entry)
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

    /// 表头：点一格 = 按这一列排，同一格再点换方向；**只有当前列**带箭头（`accent-2`）。
    /// 点击走 AppKit 接管层 `HeaderGrabber`（`isDraggable: false`）—— 合成鼠标事件
    /// 进不了 SwiftUI 的手势系统，走这一层冒烟通路才验得动「点表头 → 排序」；
    /// 各格位置也由它自报（合成点击要按位置落到格子上）。
    private var header: some View {
        HStack(spacing: 0) {
            ForEach(FileSortField.allCases) { field in
                headerCell(field)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
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
        .modifier(FileColumnWidth(field: field))
        .contentShape(Rectangle())
        .overlay {
            HeaderGrabber(
                onClick: { Task { await model.toggleSort(field, on: manager) } },
                onDrag: { _ in },
                onDrop: { _ in },
                isDraggable: false,
                onFrame: { model.headerFrames[field] = $0 }
            )
        }
        .help("点按按这一列排序")
    }
}

struct FileRow: View {
    let entry: FileEntry
    let isSelected: Bool
    let manager: SessionManager?
    let onSelect: () -> Void
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: DmSpace.s8) {
                FileGlyph(entry: entry, manager: manager)
                Text(entry.name)
                    .font(.system(size: DmText.t13, weight: .medium))
                    .foregroundColor(ListRowState.primaryForeground(isSelected: isSelected))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, FilesMetrics.padH)
            .modifier(FileColumnWidth(field: .name))

            cell(entry.sizeText, field: .size)
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
    }

    /// 一格（大小 / 修改时间）：字 12、`ink-3`；数值列右对齐、等宽数字。
    private func cell(_ text: String, field: FileSortField) -> some View {
        Text(text)
            .font(.system(size: DmText.t12))
            .foregroundColor(ListRowState.secondaryForeground(isSelected: isSelected, hovered: isHovered))
            .lineLimit(1)
            .monospacedDigit()
            .padding(.horizontal, FilesMetrics.padH)
            .modifier(FileColumnWidth(field: field))
    }
}

/// 名称列左侧那一格图形：图片与视频走 28 的缩略图（取不到退回图标），其余按
/// `additional.type` 给类型图标。**固定 28 宽**，各行名称因此对齐。
private struct FileGlyph: View {
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
    private static func icon(of entry: FileEntry) -> String {
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

/// 分页那一行：滚到底自动要下一页，也可以点。
private struct FileLoadMoreRow: View {
    let loaded: Int
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

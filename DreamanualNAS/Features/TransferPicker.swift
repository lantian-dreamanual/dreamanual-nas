import SwiftUI

/// 选目标弹窗（复制 / 移动共用）。形态照原型「弹窗 · 移动/复制到」屏：
/// 470 标准三段，body 是「搜索框 → 目标路径行 → 列表」，脚部左侧一个「新建文件夹」。
///
/// 与写操作那几张弹窗共用 `DmModalCard`（标题、脚部、关法全部同构），只有 content
/// 与脚部内容不同。列表两种形态：搜索框空着给**树**（逐级懒加载、整层铺开不截断），
/// 有字给**平铺结果**（每行右侧带相对共享夹的路径）。
struct TransferPickerCard: View {
    @Environment(AppState.self) private var state

    private var transfer: FileTransfer { state.transfers }
    private var picker: DestinationPicker { state.transfers.picker }

    /// 列表固定高（原型 `.mv-list` 288）。里面的树可能有三千多行，靠 LazyVStack 按需建。
    private static let listHeight: CGFloat = 288

    var body: some View {
        DmModalCard(
            title: transfer.mode?.title ?? "复制到…",
            onClose: { state.cancelTransfer() },
            content: { body_ },
            foot: { foot_ },
            lead: AnyView(newFolderButton)
        )
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 0) {
            DmSearchField(
                text: Binding(get: { picker.query }, set: { picker.query = $0 }),
                placeholder: "文件夹名，如 2024"
            )
            .padding(.bottom, DmSpace.s12)

            targetRow

            list
        }
    }

    /// 目标路径行：随选中的行实时变（原型 `.mv-path`）。
    private var targetRow: some View {
        HStack(spacing: DmSpace.s8) {
            Text("目标")
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
            Text(picker.targetText)
                .font(.system(size: DmText.t12, weight: .medium))
                .foregroundColor(Color.dmInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.bottom, DmSpace.s8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DmSpace.s2) {
                if picker.rows.isEmpty {
                    Text(picker.query.isEmpty ? "还没有可选的目录" : "没有匹配的文件夹")
                        .font(.system(size: DmText.t12))
                        .foregroundColor(Color.dmInk3)
                        .padding(.horizontal, DmSpace.s8)
                        .padding(.vertical, DmSpace.s6)
                } else {
                    ForEach(picker.rows) { row in
                        PickerRowView(row: row, picker: picker, manager: state.sessionManager)
                    }
                }
            }
            .padding(DmSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.listHeight)
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r8)
                .strokeBorder(Color.dmLine, lineWidth: DmLine.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r8))
        .padding(.bottom, DmSpace.s6)
    }

    /// 脚部：左「新建文件夹」，右「取消 / 确认」。禁用的原因就写在按钮左边 ——
    /// 灰着不给理由，用户只会以为坏了。
    private var foot_: some View {
        HStack(spacing: DmSpace.s8) {
            if let reason = transfer.blockingReason {
                Text(reason)
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
                    .lineLimit(1)
            }
            Button("取消") { state.cancelTransfer() }
                .buttonStyle(SecondaryButtonStyle())
            Button(transfer.mode?.confirmTitle ?? "继续") {
                Task { await state.confirmTransfer() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!transfer.canConfirm)
        }
    }

    private var newFolderButton: some View {
        Button {
            state.openFileDialog(.newFolder(in: picker.target))
        } label: {
            HStack(spacing: DmSpace.s6) {
                LucideIcon("folder-plus", size: DmIcon.i14)
                Text("新建文件夹")
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(picker.target.isEmpty)
    }
}

/// 选目标列表里的一行 —— 树节点与筛选结果共用（原型 `.tree-row` / `.mv-hit`）。
///
/// 选中走**列表行那条轨道**（灰底 `panel-2` + `accent-2`），与表行、浏览树一致。
private struct PickerRowView: View {
    let row: DestinationPicker.Row
    let picker: DestinationPicker
    let manager: SessionManager?

    @State private var isHovered = false

    private var isOn: Bool { picker.target == row.path }

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon(icon, size: DmIcon.i14)
                .foregroundColor(ListRowState.secondaryForeground(isSelected: isOn, hovered: isHovered))
            Text(row.name)
                .font(.system(size: DmText.t13))
                .foregroundColor(ListRowState.foreground(isSelected: isOn, hovered: isHovered))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DmSpace.s4)
            if row.kind == .hit {
                // 平铺结果里同名的一堆长得一样，得靠右边这条路径分清是哪一个。
                if !row.parentText.isEmpty {
                    Text(row.parentText)
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                        .lineLimit(1)
                }
            } else if row.canExpand {
                toggle
            }
        }
        .padding(.horizontal, DmSpace.s8)
        .padding(.vertical, DmSpace.s6)
        // 缩进与浏览树同一档（基础 8 + 每层 12）。
        .padding(.leading, CGFloat(row.depth) * DmSpace.s12)
        .background(ListRowState.background(isSelected: isOn, hovered: isHovered && !isOn))
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r6))
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture { picker.select(row.path) }
        .help(row.path)
    }

    private var icon: String {
        row.kind == .hit || row.isExpanded ? "folder-open" : "folder"
    }

    /// 展开箭头。点它只展开、不改目标 —— 两件事分开，与浏览树同一条规矩。
    private var toggle: some View {
        Button {
            Task { await picker.toggleExpand(row.path, on: manager) }
        } label: {
            LucideIcon("chevron-right", size: DmIcon.i12)
                .foregroundColor(row.isExpanded ? Color.dmInk2 : Color.dmInk3)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .frame(width: FilesMetrics.toggleSide, height: FilesMetrics.toggleSide)
                .background(
                    RoundedRectangle(cornerRadius: DmRadius.r4)
                        .fill(isHovered ? Color.dmPanel3 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.isExpanded ? "收起" : "展开")
    }
}

/// 复制 / 移动的撞名弹窗。
///
/// 与上传那个三选不同：**这里只有「替换 / 跳过」两选**。接口不能给新来的一份改名
/// （`CopyMove` 的 `name` / `new_name` / `rename_to` 全被忽略，2026-10-14 实测），
/// 「保留两者」那条路只剩「给目标处已有的那一项改名」—— 那会把「2」贴到用户原来的
/// 文件上，与上传那批的约定正好相反，不做。这一点在弹窗里直接对用户讲清楚。
///
/// 整批一次问，不逐项问：撞名的往往是一整批同名格式的文件，逐项点是折磨。
struct TransferConflictCard: View {
    @Environment(AppState.self) private var state
    @State private var choice: FileTransfer.ConflictChoice = .replace

    private var conflict: FileTransfer.Conflict? { state.transfers.conflict }

    var body: some View {
        DmModalCard(
            title: "已有同名项目",
            onClose: { state.transfers.clearConflict() },
            content: { body_ },
            foot: { foot_ }
        )
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: DmSpace.s12) {
            if let conflict {
                DmCompare(
                    left: DmCompareColumn(title: "要\(conflict.mode.verb)", lines: names(conflict.clashes)),
                    right: DmCompareColumn(title: "目标“\(DestinationPicker.shortPath(conflict.destination))”已有",
                                           lines: names(conflict.clashes))
                )
                DmOptionRow(
                    title: "替换",
                    note: conflict.clashes.contains(where: \.isDirectory)
                        ? "文件会被覆盖；同名的文件夹会合并，选哪个都一样。"
                        : "目标位置的文件会被覆盖。",
                    isOn: choice == .replace
                ) { choice = .replace }
                DmOptionRow(
                    title: "跳过",
                    note: conflict.clean.isEmpty
                        ? "这 \(conflict.clashes.count) 项全部不动。"
                        : "这 \(conflict.clashes.count) 项不动，其余 \(conflict.clean.count) 项照常\(conflict.mode.verb)。",
                    isOn: choice == .skip
                ) { choice = .skip }
                DmDangerNote(text: "要两份都保留，先给目标位置的那一份重命名，再来一次。")
            }
        }
    }

    private var foot_: some View {
        HStack(spacing: DmSpace.s8) {
            Button("取消") { state.transfers.clearConflict() }
                .buttonStyle(SecondaryButtonStyle())
            // 主按钮的样式不跟着单选走 —— 不管选哪一条，这一步都是「往下走」。
            Button(choice == .replace ? "替换并\(verb)" : "跳过这 \(count) 项") {
                let picked = choice
                Task { await state.resolveTransfer(picked) }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var verb: String { conflict?.mode.verb ?? "复制" }
    private var count: Int { conflict?.clashes.count ?? 0 }
    private func names(_ entries: [FileEntry]) -> [String] {
        let shown = entries.prefix(3).map(\.name)
        if entries.count <= 3 { return shown }
        return shown + ["等 \(entries.count) 项"]
    }
}

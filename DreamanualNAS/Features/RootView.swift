import SwiftUI

/// 外壳：侧栏（三个模块 + 设置）+ 主区 + 底部常驻播放条。/// 布局与设计原型一致：侧栏 220 固定宽，主区自适应，播放条通栏、切到任何模块都不中断。
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Group {
            if state.isConnected {
                VStack(spacing: 0) {
                    // 沉浸模式收掉侧栏（原型 `.win[data-mode="immersive"] .sider{display:none}`），
                    // 播放条两态都在 —— 沉浸只是换掉上半屏，播放不中断。
                    if state.showsImmersive {
                        ImmersiveView()
                            .transition(.opacity)
                    } else {
                        HStack(spacing: 0) {
                            SidebarView()
                            Rectangle()
                                .fill(Color.dmLine)
                                .frame(width: DmLine.hairline)
                            MainAreaView()
                        }
                        .frame(maxHeight: .infinity)
                    }
                    PlayerBarView(engine: state.playback)
                }
                .background(Color.dmBg)
                .animation(.easeOut(duration: DmMotion.base), value: state.showsImmersive)
            } else {
                ConnectView()
            }
        }
        // 内容延伸进顶部安全区：hiddenTitleBar 后系统安全区（约 28pt）依然存在，
        // 不 ignore 的话侧栏会从安全区下才开始，顶部露出一条窗口底色的深带，
        // 且与品牌区的 DmLayout.titlebar padding 叠成双重让位 —— 侧栏顶上多出
        // 一块空白（2026-10-12 用户截图）。与视频下载根部同一条处理。
        .ignoresSafeArea(.container, edges: .top)
        // 歌曲右键菜单：挂根上（不是行里）—— 行在滚动区里，菜单画在行里会被
        // 后面的行盖住、也会被滚动区裁掉。锚点给的是根视图坐标，这里就是根。
        .overlay { songMenuLayer }
        // 文件列表的右键菜单同一归属、同一套摆位。
        .overlay { fileMenuLayer }
        // 提示条挂在根上：曲库表与播放条两处评分入口都落到同一条上。
        .dmToast($state.toast)
        // 选目标弹窗（复制 / 移动共用）与它的撞名弹窗。**挂在写操作弹窗之前** ——
        // 层序靠后 = 压在上面，而「新建文件夹」是从选目标弹窗里开的，它得盖住弹窗
        // 自己（「确定」弹窗也一样）。
        .dmModal(
            isPresented: state.showsTransferPicker,
            onDismiss: { state.cancelTransfer() }
        ) {
            TransferPickerCard()
        }
        // 复制 / 移动撞名：整批一次问（替换 / 跳过）。收掉它等于退回选目标挑别的目录。
        .dmModal(
            isPresented: state.showsTransferConflict,
            onDismiss: { state.transfers.clearConflict() }
        ) {
            TransferConflictCard()
        }
        // 写操作弹窗（新建文件夹 / 重命名 / 删除确认）挂在根上 —— 遮罩要盖住整个窗口，
        // 连播放条一起。挂在最后，它会盖住上面的菜单层与提示条。
        .dmModal(
            isPresented: state.fileDialog != nil,
            onDismiss: { state.closeFileDialog() }
        ) {
            if let dialog = state.fileDialog {
                FileDialogCard(dialog: dialog)
            }
        }
        // 上传撞名的三选弹窗。与写操作弹窗同一挂法、同一层序 —— 两者不会同时出现
        // （撞名是在开传之前问的，写操作弹窗是别的动作摆的）。
        .dmModal(
            isPresented: state.uploads.conflict != nil,
            onDismiss: { state.cancelUploads() }
        ) {
            if let prompt = state.uploads.conflict {
                FileConflictCard(prompt: prompt)
            }
        }
    }

    /// 右键菜单层：一层透明遮罩接住「点别处关闭」，菜单卡按指针位置摆，
    /// 越界时收回窗口内。
    @ViewBuilder
    private var songMenuLayer: some View {
        GeometryReader { geo in
            if let request = state.songMenu {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { state.closeSongMenu() }

                    DmMenuCard(width: SongMenu.width) {
                        DmMenuRow(title: "播放", icon: "play") {
                            state.closeSongMenu()
                            state.playFromMenu(request)
                        }
                        DmMenuRow(title: "下一首播放", icon: "list-start") {
                            state.closeSongMenu()
                            state.playNext(request.song)
                        }
                        // 评分那一行：星星自己接点击，行本身不做事。原型 `.mi` 里的
                        // 内嵌星（`.rate{margin-left:auto}`）。
                        DmMenuRow(title: "评分", icon: "star", action: {}) {
                            RatingStars(
                                rating: request.song.rating,
                                isSelected: false,
                                revealsEmpty: true,
                                onRate: { stars in
                                    Task { await state.rate(request.song.id, to: stars) }
                                }
                            )
                        }
                        DmMenuSeparator()
                        DmMenuRow(title: "下载", icon: "download") {
                            state.closeSongMenu()
                            Task { await state.download(request.song) }
                        }
                        DmMenuRow(title: "在文件管理中显示", icon: "folder-open") {
                            Task { await state.revealInFiles(request.song) }
                        }
                    }
                    .offset(x: SongMenu.anchor(request.point, in: geo.size).x,
                            y: SongMenu.anchor(request.point, in: geo.size).y)
                }
            }
        }
    }

    /// 文件列表的右键菜单层：与歌曲菜单同构（一层透明遮罩接「点别处关闭」，菜单卡按
    /// 指针摆、越界收回窗口内）。
    ///
    /// 项按**选中集合**出：单选的文件多一条「下载」、单选的目录多一条「计算大小」
    /// （正在算时换成「取消计算」、算过换成「重新计算大小」）；单选多一条「重命名」。
    /// 「复制到…」「移动到…」按选中集合生效，所以单选多选都在（原型「目录行 / 文件行」
    /// 那一版就是这几项）。移动要来源目录可写，不可写时那一条不出现（与工具条同一个
    /// 判据）；复制不挑来源。
    @ViewBuilder
    private var fileMenuLayer: some View {
        GeometryReader { geo in
            if let request = state.fileMenu {
                let spot = FileMenu.spot(request.point, in: geo.size, entries: request.entries)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { state.closeFileMenu() }

                    DmMenuCard(width: FileMenu.width) {
                        if request.entries.count == 1, let entry = request.entries.first,
                           !entry.isDirectory {
                            DmMenuRow(title: "下载", icon: "download") {
                                state.closeFileMenu()
                                Task { await state.download(file: entry) }
                            }
                        }
                        DmMenuRow(title: "复制到…", icon: "copy") {
                            state.closeFileMenu()
                            state.beginTransfer(.copy)
                        }
                        if state.files.currentCanWrite {
                            DmMenuRow(title: "移动到…", icon: "folder-input") {
                                state.closeFileMenu()
                                state.beginTransfer(.move)
                            }
                        }
                        DmMenuSeparator()
                        if request.entries.count == 1, let entry = request.entries.first {
                            DmMenuRow(title: "重命名", icon: "pencil") {
                                state.closeFileMenu()
                                state.openFileDialog(.rename(entry))
                            }
                            // 目录的体积只能问 `DirSize`（慢、且要重试），所以恒是
                            // 用户点了才算；这一行按状态换字：没算过 / 正在算 / 算过了。
                            if entry.isDirectory {
                                if state.files.isMeasuring {
                                    DmMenuRow(title: "取消计算", icon: "circle-x") {
                                        state.closeFileMenu()
                                        state.cancelFileMeasure()
                                    }
                                } else {
                                    let measured = state.files.sizes[entry.path] != nil
                                    DmMenuRow(title: measured ? "重新计算大小" : "计算大小", icon: "ruler") {
                                        state.closeFileMenu()
                                        Task { await state.measureFileSelection() }
                                    }
                                }
                            }
                        }
                        DmMenuRow(title: FileMenu.deleteTitle(request.entries), icon: "trash") {
                            state.closeFileMenu()
                            state.openFileDialog(.delete(request.entries))
                        }
                    }
                    .offset(x: spot.x, y: spot.y)
                }
            }
        }
    }
}

/// 歌曲右键菜单的摆位。菜单卡宽固定（原型 `.menu` 的 `min-width:160`，这里给
/// 196 —— 带内嵌星那一行要放得下），高按项数估：每项 30 + 分隔线 9 + 内边距 8。
enum SongMenu {
    static let width: CGFloat = 196
    static let itemHeight: CGFloat = 30
    /// 项数（播放 / 下一首播放 / 评分 / 下载 / 在文件管理中显示）。
    static let itemCount = 5
    private static let inset: CGFloat = 8

    /// 指针位置 → 菜单左上角，越界时收回窗口内（同访达 / 原型那层绝对定位的意思）。
    static func anchor(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let height = itemHeight * CGFloat(itemCount) + 9 + 8
        return CGPoint(
            x: min(max(inset, point.x), max(inset, size.width - width - inset)),
            y: min(max(inset, point.y), max(inset, size.height - height - inset))
        )
    }
}

/// 文件列表右键菜单的摆位与行数。宽与项高与歌曲菜单同档。
///
/// 行数要按实际出的项算：**复制到… / 移动到… / 删除**三条恒在；单选再多**两条**
/// ——「重命名」，以及按类型二选一的「下载」（文件）或「计算大小 / 取消计算 /
/// 重新计算大小」（目录）。所以单选恒是 5 行、多选 3 行，不再分文件与目录。
/// 高估了，菜单会被窗口底边顶回来一截；低估了会被切掉底。
enum FileMenu {
    static let width: CGFloat = 196
    static let itemHeight: CGFloat = 30
    /// 分隔线占位（含上下各 `s4`）。
    private static let separator: CGFloat = 9
    private static let inset: CGFloat = 8

    /// 菜单里有几行（不含分隔线）。
    ///
    /// 「移动到…」在目录不可写时不出现 —— 这一条按**乐观**计（多算一行只是往上挪
    /// 几个点），省得为一个边角把判据传两遍。
    static func rowCount(_ entries: [FileEntry]) -> Int {
        entries.count == 1 ? 5 : 3
    }

    /// 删除那一项的文案：多项带个数（原型「删除（3 个）」）。
    static func deleteTitle(_ entries: [FileEntry]) -> String {
        entries.count == 1 ? "删除" : "删除（\(entries.count) 个）"
    }

    /// 指针位置 → 菜单左上角，越界时收回窗口内。
    static func spot(_ point: CGPoint, in size: CGSize, entries: [FileEntry]) -> CGPoint {
        let height = itemHeight * CGFloat(rowCount(entries)) + separator + inset
        return CGPoint(
            x: min(max(inset, point.x), max(inset, size.width - width - inset)),
            y: min(max(inset, point.y), max(inset, size.height - height - inset))
        )
    }
}

// ============ 侧栏 ============

private struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        WindowActiveReader { windowActive in
            VStack(alignment: .leading, spacing: 0) {
                brand

                VStack(spacing: DmSpace.s2) {
                    ForEach(AppState.Module.allCases) { module in
                        NavRow(
                            title: module.title,
                            icon: module.icon,
                            isSelected: state.module == module,
                            windowActive: windowActive
                        ) {
                            state.select(module)
                        }
                    }
                }
                .padding(.horizontal, DmSpace.s8)
                .padding(.top, DmSpace.s10)

                Spacer(minLength: 0)
                connectionFooter
            }
            // 整块下移 `DmLayout.titlebar` 给悬浮的红绿灯让位，底色仍铺到窗口最上沿
            // —— 与视频下载 `SidebarView`、密码管理 `.sider` 同构。
            .padding(.top, DmLayout.titlebar)
            .frame(width: 220)
            // 侧栏比主内容区浅一档（Finder 式层级，第一节「侧栏单独一支」）。
            .background(Color.dmPanel2)
        }
    }

    /// 品牌区：标记 26·`r-8`、名称 13/semibold、内边距 16/14/12、底部 `line-2` 分隔。
    /// 规格抄密码管理 `.brand` ↔ 视频下载 `brandHeader`。
    private var brand: some View {
        HStack(spacing: DmSpace.s8) {
            DmBrandMark(size: 26)
            Text("Dreamanual NAS 助手")
                .font(.system(size: DmText.t13, weight: .semibold))
                .kerning(-0.13)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(Color.dmInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.top, DmSpace.s16)
        .padding(.bottom, DmSpace.s12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine2).frame(height: DmLine.base)
        }
    }

    /// 底栏：顶部 `line-2` 分隔、内边距 8/16/10（与品牌区的上下留白同款）。
    private var connectionFooter: some View {
        VStack(alignment: .leading, spacing: DmSpace.s4) {
            HStack(spacing: DmSpace.s6) {
                Circle()
                    .fill(Color.dmOk)
                    .frame(width: 6, height: 6)
                Text("已连接")
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
            }
            Text(state.endpointLabel)
                .font(.system(size: DmText.t11))
                .foregroundColor(Color.dmInk3)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DmSpace.s16)
        .padding(.top, DmSpace.s8)
        .padding(.bottom, DmSpace.s10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.dmLine2).frame(height: DmLine.base)
        }
    }
}

/// 手写侧栏行：选中走实心主色底 + 白字（大面积轨道，`SelectState`），悬停 `panel-3`，
/// 失焦底掉 `accent-soft`、字不动。
/// 规格与视频下载 `SidebarRow` ↔ 密码管理 `.cat` 逐项一致：图标 16、字号 13、
/// 横向 8、行高钉控件档 32、圆角 8、行距 2、选中标签 semibold（第七节「侧栏行」）。
private struct NavRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let windowActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let look = SelectState.of(isSelected: isSelected, hovered: isHovered, windowActive: windowActive)
        HStack(spacing: DmSpace.s8) {
            LucideIcon(icon, size: DmIcon.i16)
                .foregroundColor(look.foreground)
            Text(title)
                .font(.system(size: DmText.t13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(look.foreground)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DmSpace.s8)
        .frame(height: DmControl.h32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r8).fill(look.background)
        )
        .contentShape(RoundedRectangle(cornerRadius: DmRadius.r8))
        .trackingHover($isHovered)
        .onTapGesture(perform: action)
    }
}

// ============ 主区 ============

private struct MainAreaView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.module == .music, state.showsQueue, let engine = state.playback {
                QueueView(engine: engine)
            } else if state.module == .music {
                LibraryView()
            } else if state.module == .files {
                // 文件管理自带页头（标题 + 面包屑），不走外面这一条。
                FilesView()
            } else if state.module == .status {
                // 系统状态自带页头（标题 + 固件与开机时长 + 链路徽章），不走外面这一条。
                StatusView()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    DmPageHead(state.module.title)

                    SettingsPane()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 主内容区取 `panel`（第一节落位口径：主区 panel、卡片 panel-2、悬停 panel-3）。
        .background(Color.dmPanel)
    }
}

private struct SettingsPane: View {
    @Environment(AppState.self) private var state

    @State private var heartbeatText = "刚启动"

    var body: some View {
        VStack(alignment: .leading, spacing: DmSpace.s14) {
            VStack(alignment: .leading, spacing: DmSpace.s8) {
                FormLabel("连接")
                Text(state.endpointLabel)
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk2)
                Text("每 4 分钟一次心跳；会话失效自动重登并重放当前请求。")
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
                Button("断开连接") {
                    Task { await state.disconnect() }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(DmSpace.s14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dmCard()
        }
        .padding(.horizontal, DmSpace.s24)
    }
}

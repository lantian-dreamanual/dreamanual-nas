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
    /// 项按**选中集合**出：单选才给「重命名」（文件再多一条「下载」），多选只有「删除」。
    /// 多文件下载要一次挑目录再逐个落盘，那是上传那一批的事 —— 现在给个只能下一个的
    /// 「下载（3 个文件）」反而误导。
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
                        if request.entries.count == 1, let entry = request.entries.first {
                            if !entry.isDirectory {
                                DmMenuRow(title: "下载", icon: "download") {
                                    state.closeFileMenu()
                                    Task { await state.download(file: entry) }
                                }
                            }
                            DmMenuRow(title: "重命名", icon: "pencil") {
                                state.closeFileMenu()
                                state.openFileDialog(.rename(entry))
                            }
                            DmMenuSeparator()
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
/// 行数要按实际出的项算 —— 只有**单选**才给「重命名」（文件再多一条「下载」），
/// 多选时只有一条「删除」。高估了，菜单会被窗口底边顶回来一截；低估了会被切掉底。
enum FileMenu {
    static let width: CGFloat = 196
    static let itemHeight: CGFloat = 30
    /// 分隔线占位（含上下各 `s4`）。
    private static let separator: CGFloat = 9
    private static let inset: CGFloat = 8

    /// 菜单里有几行（不含分隔线）。
    static func rowCount(_ entries: [FileEntry]) -> Int {
        guard entries.count == 1 else { return 1 }
        // 目录不给「下载」—— 单个目录只能改名与删除。
        return entries[0].isDirectory ? 2 : 3
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
                VStack(alignment: .leading, spacing: 0) {
                    DmPageHead(state.module.title)

                    ModulePlaceholder(
                        icon: "gauge",
                        title: "系统状态",
                        note: "关机与重启、读写开关机计划",
                        next: ["状态卡片（CPU / 内存 / 存储 / 温度）", "关机与重启", "开关机计划"]
                    )
                }
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

/// 尚未实现的模块占位：写清「这里会有什么」，不写假的进度状态。
private struct ModulePlaceholder: View {
    let icon: String
    let title: String
    let note: String
    let next: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DmSpace.s14) {
            HStack(spacing: DmSpace.s8) {
                LucideIcon(icon, size: DmIcon.i16)
                    .foregroundColor(Color.dmAccent)
                Text(title)
                    .font(.system(size: DmText.t13, weight: .medium))
                    .foregroundColor(Color.dmInk)
            }
            Text(note)
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
            VStack(alignment: .leading, spacing: DmSpace.s6) {
                ForEach(next, id: \.self) { item in
                    HStack(alignment: .top, spacing: DmSpace.s8) {
                        Circle()
                            .fill(Color.dmInk3)
                            .frame(width: 4, height: 4)
                            .padding(.top, DmSpace.s6)
                        Text(item)
                            .font(.system(size: DmText.t12))
                            .foregroundColor(Color.dmInk2)
                    }
                }
            }
            Text("这一屏还没接数据 —— 地基（连接 / 双会话 / 保活 / 外壳）已通。")
                .font(.system(size: DmText.t11))
                .foregroundColor(Color.dmInk3)
        }
        .padding(DmSpace.s14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dmCard()
        .padding(.horizontal, DmSpace.s24)
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

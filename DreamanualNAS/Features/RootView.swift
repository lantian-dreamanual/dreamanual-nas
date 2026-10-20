import AppKit
import SwiftUI

/// 外壳：侧栏（三个模块 + 设置）+ 主区，播放条挂在主区那一列的底部。
///
/// 播放条**只属听歌**（2026-10-18 定）：它原来通栏挂在窗口底，等于把单模块的功能
/// 当成了全局设施 —— 文件管理与系统状态各让出 70pt，换来的却是自己用不上的音量条。
/// 挪进主区之后侧栏通高、连接状态落到窗口最底，非听歌模块由侧栏底部的迷你卡接手。
/// 沉浸模式是整窗覆盖层（从底部滑上来），盖住侧栏与主区，层内自带一条铺满整窗的
/// 播放条 —— 普通模式那条只有主区宽，宽度差就用「同一组件的另一个实例」补。
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Group {
            if state.isConnected {
                ZStack(alignment: .bottom) {
                    shell
                    // 沉浸层（第 5 稿）：进 280ms 减速收住、退 200ms 加速离开。
                    // 进比出慢是覆盖层的惯例 —— 展开值得等，退回要立刻。
                    // 两条曲线写在各自动画上（不等父级 `.animation`），否则进出只能
                    // 共用一条时长。
                    if state.musicPresentation == .immersive {
                        ImmersiveView()
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom)
                                    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: DmMotion.slow)),
                                removal: .move(edge: .bottom)
                                    .animation(.timingCurve(0.4, 0, 1, 1, duration: DmMotion.base))
                            ))
                            // 层压在壳之上：侧栏与主区留在原位被盖住，不做淡出。
                            .zIndex(1)
                    }
                    // 照片查看器：与沉浸屏同一套整窗覆盖层、同一条进出曲线。
                    // 层序压在最上 —— 两者不会同时出现，但查看器从网格里点开时，
                    // 它是比沉浸屏更「当前」的一层。
                    if state.photos.viewingID != nil {
                        PhotoViewerView()
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom)
                                    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: DmMotion.slow)),
                                removal: .move(edge: .bottom)
                                    .animation(.timingCurve(0.4, 0, 1, 1, duration: DmMotion.base))
                            ))
                            .zIndex(2)
                    }
                }
                .background(Color.dmBg)
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
        // 照片块的右键菜单也一样（打开 / 在文件夹中显示 / 下载原图 / 添加到相册 / 删除）。
        .overlay { photoMenuLayer }
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
        // 照片的写操作弹窗（新建相册 / 相册改名 / 删除确认 / 选相册）。同一挂法 ——
        // 遮罩要盖住整个窗口，连侧栏与播放条一起。
        .dmModal(
            isPresented: state.photoDialog != nil,
            onDismiss: { state.closePhotoDialog() }
        ) {
            if let dialog = state.photoDialog {
                PhotoDialogCard(dialog: dialog)
            }
        }
        // 新建歌单弹窗。从右键菜单的二级面板与侧栏「+ 新建」两处进来，
        // 都发生时菜单已经收掉了 —— 与写操作弹窗同一挂法即可。
        .dmModal(
            isPresented: state.libraryDialog != nil,
            onDismiss: { state.closeLibraryDialog() }
        ) {
            if state.libraryDialog != nil {
                PlaylistDialogCard()
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
        // 编辑歌曲信息（歌曲右键菜单）。同样盖在最上层 —— 它是从菜单层里开的。
        .dmModal(
            isPresented: state.tagEditor != nil,
            onDismiss: { state.closeTagEditor() }
        ) {
            TagEditorCard()
        }
        // 新增 / 编辑开关机计划（计划卡页脚 / 空表静场 / 行右键菜单）。
        // 与写操作弹窗同一挂法、同一层序。编辑模式预填那一条的现状；
        // 下标失效（写回刚把它删了）时按新增开。`.id` 挂在模式上 ——
        // add ↔ edit 换模式时弹窗要整个重造，@State 才会按新模式的初值重来。
        .dmModal(
            isPresented: state.showsPowerEditor,
            onDismiss: { state.closePowerEditor() }
        ) {
            Group {
                switch state.powerEditor {
                case .edit(let index):
                    if let task = powerScheduleTask(at: index) {
                        PowerAddCard(mode: .edit(index: index, task: task))
                    } else {
                        PowerAddCard(mode: .add)
                    }
                default:
                    PowerAddCard(mode: .add)
                }
            }
            .id(state.powerEditor)
        }
        // 关机 / 重启的确认弹窗（电源卡两颗按钮）。指令在确认框里发；
        // 换动作前必先关弹窗，@State 不用挂身份。
        .dmModal(
            isPresented: state.powerConfirm != nil,
            onDismiss: { state.closePowerConfirm() }
        ) {
            PowerConfirmCard()
        }
        // 计划行右键菜单（编辑 / 删除）：与歌曲 / 文件菜单同一归属、同一套摆位。
        .overlay { powerRowMenuLayer }
    }

    /// 常规壳：侧栏 + 主区 + 主区底部的播放条（只在听歌模块）。
    private var shell: some View {
        HStack(spacing: 0) {
            SidebarView()
            Rectangle()
                .fill(Color.dmLine)
                .frame(width: DmLine.hairline)
            VStack(spacing: 0) {
                MainAreaView()
                if state.module == .music {
                    PlayerBarView(engine: state.playback)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 计划表第 `index` 条（弹窗编辑模式预填用）。
    private func powerScheduleTask(at index: Int) -> PowerTask? {
        let tasks = state.powerSchedule.tasks
        return tasks.indices.contains(index) ? tasks[index] : nil
    }

    /// 计划行右键菜单层：与歌曲菜单同构（透明遮罩接「点别处关闭」，菜单卡按
    /// 指针摆、越界收回窗口内）。两条：编辑、删除 —— 都当场写 NAS。
    @ViewBuilder
    private var powerRowMenuLayer: some View {
        GeometryReader { geo in
            if let request = state.powerRowMenu {
                let spot = PowerRowMenu.spot(request.point, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { state.closePowerRowMenu() }

                    DmMenuCard(width: PowerRowMenu.width) {
                        DmMenuRow(title: "编辑", icon: "pencil") {
                            state.closePowerRowMenu()
                            state.openPowerEdit(request.index)
                        }
                        DmMenuRow(title: "删除", icon: "trash") {
                            state.closePowerRowMenu()
                            state.powerSchedule.remove(request.index, on: state.sessionManager)
                            Task {
                                await state.powerSchedule.waitWritesSettled()
                                if let note = state.powerSchedule.failureNote {
                                    state.showToast(note, .err)
                                }
                            }
                        }
                    }
                    .offset(x: spot.x, y: spot.y)
                }
            }
        }
        // 与歌曲菜单同一条规矩：geo 原点钉窗口顶（见 songMenuLayer 的注）。
        .ignoresSafeArea()
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
                        if request.phase == .root {
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
                            DmMenuRow(title: "添加到歌单", icon: "list-plus") {
                                state.showPlaylistPickerInMenu()
                            }
                            // 队列表右键独有的一条：从队列移除（播放不中断，
                            // 正在播的那首播完自动落新表的下一首）。
                            if request.fromQueue {
                                DmMenuRow(title: "从队列移除", icon: "x") {
                                    state.closeSongMenu()
                                    state.removeFromQueue(request)
                                }
                            }
                            DmMenuSeparator()
                            DmMenuRow(title: "下载", icon: "download") {
                                state.closeSongMenu()
                                Task { await state.download(request.song) }
                            }
                            DmMenuRow(title: "在文件管理中显示", icon: "folder-open") {
                                Task { await state.revealInFiles(request.song) }
                            }
                            DmMenuRow(title: "编辑歌曲信息", icon: "pencil") {
                                state.closeSongMenu()
                                state.openTagEditor(request.song)
                            }
                        } else {
                            // 二级面板：原地换成歌单列表。开头一条「新建歌单…」——
                            // 没有合适的歌单时不必先收菜单、去侧栏建再重新右键一遍。
                            DmMenuRow(title: "新建歌单…", icon: "plus") {
                                state.closeSongMenu()
                                state.openLibraryDialog(.newPlaylist)
                            }
                            DmMenuSeparator()
                            ForEach(state.library.playlists) { playlist in
                                DmMenuRow(title: playlist.name, icon: "list-music") {
                                    Task { await state.addSongToPlaylist(request.song, to: playlist) }
                                }
                            }
                        }
                    }
                    .offset(x: SongMenu.anchor(request.point, in: geo.size,
                                               phase: request.phase,
                                               playlistCount: state.library.playlists.count,
                                               fromQueue: request.fromQueue).x,
                            y: SongMenu.anchor(request.point, in: geo.size,
                                               phase: request.phase,
                                               playlistCount: state.library.playlists.count,
                                               fromQueue: request.fromQueue).y)
                }
            }
        }
        // geo 原点必须钉在窗口顶：右键捕获层报的是窗口坐标（contentView 原点），
        // 这层若被安全区垫下去，菜单整体就往下坠一个标题栏的高度（2026-10-15
        // 用户报「右键菜单漂移到很远」，实测坠 32pt）。
        .ignoresSafeArea()
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
        // 与歌曲菜单同一条规矩：geo 原点钉窗口顶（见 songMenuLayer 的注）。
        .ignoresSafeArea()
    }

    /// 照片块的右键菜单层：与上面两层同构。
    ///
    /// 项按**这一批**出：多选时「在文件夹中显示」与「下载原图」置灰（两个都只对
    /// 单张成立），「添加到相册」与「删除」对整批生效；在相册详情里右键时
    /// 「添加到相册」换成「移出相册」（只移出容器、不删图）。
    @ViewBuilder
    private var photoMenuLayer: some View {
        GeometryReader { geo in
            if let request = state.photoMenu {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { state.closePhotoMenu() }

                    DmMenuCard(width: PhotoMenu.width) {
                        switch request.target {
                        case .album(let album):
                            // 相册卡 / 详情页头的 ⋯：两条动作，与右键同一份。
                            DmMenuRow(title: "改名", icon: "pencil") {
                                state.closePhotoMenu()
                                state.openPhotoDialog(.renameAlbum(album))
                            }
                            DmMenuSeparator()
                            DmMenuRow(title: "删除相册", icon: "trash") {
                                state.closePhotoMenu()
                                state.openPhotoDialog(.deleteAlbum(album))
                            }
                        case .person(let person):
                            // 人物卡 / 详情页头的 ⋯：改名（命名）与归并。
                            // 隐藏不做 —— `set` 的 show 参数服务端不认（2026-10-21 实测）。
                            DmMenuRow(title: person.isNamed ? "改名" : "命名", icon: "pencil") {
                                state.closePhotoMenu()
                                state.openPhotoDialog(.renamePerson(person))
                            }
                            DmMenuSeparator()
                            DmMenuRow(title: "归并到…", icon: "users") {
                                state.closePhotoMenu()
                                state.openPhotoDialog(.mergePerson(person))
                            }
                        case .items(let item, let targets, let albumID):
                            if request.phase == .root {
                                itemRows(item: item, targets: targets, albumID: albumID)
                            } else {
                                albumPickerRows(targets: targets)
                            }
                        }
                    }
                    .offset(x: PhotoMenu.spot(request, in: geo.size,
                                              albums: state.photoShelf.albums.count).x,
                            y: PhotoMenu.spot(request, in: geo.size,
                                              albums: state.photoShelf.albums.count).y)
                }
            }
        }
        // 与歌曲菜单同一条规矩：geo 原点钉窗口顶。
        .ignoresSafeArea()
    }

    /// 照片 / 视频块的根级五项。
    @ViewBuilder
    private func itemRows(item: PhotosAPI.Item, targets: [PhotosAPI.Item],
                          albumID: Int?) -> some View {
        let single = targets.count == 1
        DmMenuRow(title: "打开", icon: "image") {
            state.closePhotoMenu()
            state.photos.openViewer(item, in: targets)
        }
        DmMenuRow(title: "在文件夹中显示", icon: "folder-open") {
            state.closePhotoMenu()
            Task { await state.revealInFiles(item) }
        }
        .disabled(!single)
        DmMenuSeparator()
        DmMenuRow(title: single ? "下载原图" : "下载原图（仅单选）",
                  icon: "download") {
            state.closePhotoMenu()
            Task { await state.savePhotoOriginal(item) }
        }
        .disabled(!single)
        if let albumID {
            DmMenuRow(title: "移出相册", icon: "images") {
                state.closePhotoMenu()
                Task { await state.removePhotos(targets, from: albumID) }
            }
        } else {
            DmMenuRow(title: "添加到相册", icon: "images") {
                state.showAlbumPickerInPhotoMenu()
            }
        }
        DmMenuSeparator()
        DmMenuRow(title: PhotoMenu.deleteTitle(targets), icon: "trash") {
            state.closePhotoMenu()
            state.openPhotoDialog(.delete(targets))
        }
    }

    /// 二级：原地换成相册列表（与歌曲菜单的歌单选择同一做法）。
    @ViewBuilder
    private func albumPickerRows(targets: [PhotosAPI.Item]) -> some View {
        DmMenuRow(title: "新建相册…", icon: "plus") {
            state.closePhotoMenu()
            state.openPhotoDialog(.newAlbum)
        }
        DmMenuSeparator()
        ForEach(state.photoShelf.albums) { album in
            DmMenuRow(title: album.name, icon: "images") {
                state.closePhotoMenu()
                Task { await state.addPhotos(targets, to: album.id) }
            }
        }
    }
}

/// 歌曲右键菜单的摆位。菜单卡宽固定（原型 `.menu` 的 `min-width:160`，这里给
/// 196 —— 带内嵌星那一行要放得下），高按项数估：每项 30 + 分隔线 9 + 内边距 8。
/// 高度跟着**当前这一级**走：根级 7 行，二级面板 = 新建 + 分隔 + 歌单行们。
enum SongMenu {
    static let width: CGFloat = 196
    static let itemHeight: CGFloat = 30
    private static let inset: CGFloat = 8

    /// 当前菜单里有几行（不含分隔线）。根级：播放 / 下一首播放 / 评分 / 添加到歌单 /
    /// （队列来源多一条「从队列移除」）/ 下载 / 在文件管理中显示 / 编辑歌曲信息。
    static func rowCount(
        phase: AppState.SongMenuRequest.Phase,
        playlistCount: Int,
        fromQueue: Bool = false
    ) -> Int {
        switch phase {
        case .root: return fromQueue ? 8 : 7
        case .playlistPicker: return 1 + max(playlistCount, 0)
        }
    }

    /// 指针位置 → 菜单左上角，越界时收回窗口内（同访达 / 原型那层绝对定位的意思）。
    static func anchor(
        _ point: CGPoint,
        in size: CGSize,
        phase: AppState.SongMenuRequest.Phase = .root,
        playlistCount: Int = 0,
        fromQueue: Bool = false
    ) -> CGPoint {
        let lines = CGFloat(rowCount(phase: phase, playlistCount: playlistCount, fromQueue: fromQueue))
        let separators = phase == .root ? CGFloat(1) : CGFloat(1)
        let height = itemHeight * lines + 9 * separators + 8
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

/// 照片右键菜单的摆位与行数。宽与项高与歌曲 / 文件菜单同档。
///
/// 根级：打开 / 在文件夹中显示 / 下载原图 / 添加到相册（相册详情里是「移出相册」）
/// / 删除，恒 5 行、2 条分隔线；二级面板是「新建相册…」+ 每个相册一行。
enum PhotoMenu {
    static let width: CGFloat = 196
    static let itemHeight: CGFloat = 30
    private static let inset: CGFloat = 8

    static func rowCount(_ request: AppState.PhotoMenuRequest, albums: Int) -> Int {
        switch request.target {
        // 相册卡 / 人物卡与各自详情页头的 ⋯：两条动作（一条分隔线）。
        case .album, .person: return 2
        case .items:
            switch request.phase {
            case .root: return 5
            case .albumPicker: return 1 + max(albums, 0)
            }
        }
    }

    static func deleteTitle(_ targets: [PhotosAPI.Item]) -> String {
        targets.count == 1 ? "删除" : "删除（\(targets.count) 张）"
    }

    /// 指针位置 → 菜单左上角，越界时收回窗口内。
    static func spot(_ request: AppState.PhotoMenuRequest, in size: CGSize,
                     albums: Int) -> CGPoint {
        let lines = CGFloat(rowCount(request, albums: albums))
        let isRoot: Bool
        switch request.target {
        case .album, .person: isRoot = true
        case .items: isRoot = request.phase == .root
        }
        let separators = CGFloat(isRoot ? (isSingleAction(request) ? 1 : 2) : 1)
        let height = itemHeight * lines + 9 * separators + inset
        return CGPoint(
            x: min(max(inset, request.point.x), max(inset, size.width - width - inset)),
            y: min(max(inset, request.point.y), max(inset, size.height - height - inset))
        )
    }

    /// 两行动作的菜单（相册 / 人物）只有一条分隔线；照片块那张是五行两条。
    private static func isSingleAction(_ request: AppState.PhotoMenuRequest) -> Bool {
        switch request.target {
        case .album, .person: return true
        case .items: return false
        }
    }
}

/// 新建歌单弹窗：一张名称输入框。重名在 `createPlaylist` 里先拦（本地清单上对），
/// 这里只拦空名。默认名与文件管理「新建文件夹」同思路 —— 给一个能直接改的名字。
struct PlaylistDialogCard: View {
    @Environment(AppState.self) private var state

    @State private var name = "新建歌单"
    @FocusState private var isFocused: Bool

    var body: some View {
        DmModalCard(title: "新建歌单", onClose: { state.closeLibraryDialog() }) {
            VStack(alignment: .leading, spacing: DmSpace.s6) {
                FormLabel("名称")
                TextField("", text: $name)
                    .focused($isFocused)
                    .formField(on: .panel)
                HStack(spacing: DmSpace.s6) {
                    LucideIcon("info", size: DmIcon.i12)
                        .foregroundColor(Color.dmInk3)
                    Text("同名歌单会被拒绝创建。新歌单建在个人歌单里。")
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                    Spacer(minLength: 0)
                }
            }
        } foot: {
            Button("取消") { state.closeLibraryDialog() }
                .buttonStyle(SecondaryButtonStyle())
            Button("创建") {
                Task { await state.createPlaylist(named: name) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { isFocused = true }
    }
}

/// 计划行右键菜单的摆位。两条（编辑 / 删除），宽与歌曲 / 文件菜单同档。
enum PowerRowMenu {    static let width: CGFloat = 160
    static let itemHeight: CGFloat = 30
    private static let inset: CGFloat = 8

    /// 指针位置 → 菜单左上角，越界时收回窗口内。
    static func spot(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let height = itemHeight * 2 + 8
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

                // 迷你卡（2026-10-18 定）：只在非听歌模块、且有正在播的歌时出现。
                // **两个热区**：按钮切播放 / 暂停、留在当前页；卡片其余位置回听歌模块。
                // 暂停时仍显示（按钮变播放），清空队列或断线才消失 —— 它是状态不是通知，
                // 不设关闭钮（可关闭会让人以为「关掉＝停止播放」）。
                if state.module != .music,
                   let engine = state.playback,
                   engine.currentSong != nil {
                    MiniPlayerView(engine: engine) {
                        // 「接着刚才」：上次在队列就回队列，不强制回曲库首页。
                        state.resumeMusic()
                    }
                    .padding(.horizontal, DmSpace.s8)
                    .padding(.bottom, DmSpace.s6)
                }

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
            } else if state.module == .photos {
                // 照片页自带页头（标题 + 张数），不走外面这一条。
                PhotosView()
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
    /// 检查更新的状态（版本号 / 结果 / 是否有新版）。`@State` 挂在这一页上：
    /// 结果只在「关于」组里出现，换模块再回来重查一次也无妨。
    @State private var updates = UpdateChecker()
    /// 官网行的悬停态：整行单动作，悬停整行抬 panel-3、行尾外链图标提亮。
    @State private var siteHovered = false
    /// 赞赏行的悬停态（与官网行同一形态）。
    @State private var donateHovered = false

    var body: some View {
        @Bindable var state = state
        ScrollView {
            VStack(alignment: .leading, spacing: DmSpace.s24) {
                // ===== 连接 =====
                DmSettingsGroup(title: "连接") {
                    // 服务器 / 线路合并成一行：`endpointLabel` 本来就是「线路 + 地址」
                    // 拼的，分开写等于把同一件事说两遍（2026-10-17 用户定）。
                    DmSettingsRow("服务器") {
                        Text(state.endpointLabel.isEmpty ? "—" : state.endpointLabel)
                            .font(.system(size: DmText.t13))
                            .foregroundColor(Color.dmInk2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    DmSettingsRow("账号") {
                        Text(state.username.isEmpty ? "—" : state.username)
                            .font(.system(size: DmText.t13))
                            .foregroundColor(Color.dmInk2)
                    }
                    // 说明挂在地址行下面，只讲这一行的事：格式、优先级、什么时候生效。
                    // 解析不了时同一位置换成警告 —— 不然用户以为填的是直连，重连却
                    // 退回 QuickConnect，而界面上一个字都不提。
                    DmSettingsRow("直连地址",
                                  note: directAddressNote,
                                  noteIsWarning: isDirectAddressInvalid) {
                        TextField("留空则使用 QuickConnect", text: $state.directAddress)
                            .formFieldRow()
                            .frame(width: 240)
                    }
                    // 动作行右对齐到控件列：上面三行都是「标签在左、值贴右边缘」，
                    // 动作行若从卡片左边缘起头，第四行就跟前三行断了栅格。
                    // 断开连接是这里唯一不可逆的动作，排在最右端、离重连最远。
                    HStack(spacing: DmSpace.s8) {
                        Spacer(minLength: 0)
                        // 两颗同档次按钮（与电源卡同一口径）：卡面上不抢层级，
                        // 真要破坏性操作的语义留给它自己的后果提示。
                        Button("重新连接") {
                            Task { await state.reconnect() }
                        }
                        .buttonStyle(SecondaryButtonStyle(on: .card))
                        Button("断开连接") {
                            Task { await state.disconnect() }
                        }
                        .buttonStyle(SecondaryButtonStyle(on: .card))
                    }
                    .padding(.horizontal, DmSpace.s14)
                    .padding(.vertical, DmSpace.s12)
                }

                // ===== 关于 =====
                DmSettingsGroup(title: "关于") {
                    DmSettingsRow("版本") {
                        Text(versionText)
                            .font(.system(size: DmText.t13))
                            .monospacedDigit()
                            .foregroundColor(Color.dmInk2)
                    }
                    DmSettingsRow("连接方式") {
                        Text("群晖 DSM 接口直连")
                            .font(.system(size: DmText.t13))
                            .foregroundColor(Color.dmInk2)
                    }
                    // 检查更新：状态字贴在按钮左边，查完当场给结果 —— 不弹窗、不占
                    // 另一块版面（与投资监控设置页同一个做法）。
                    DmSettingsRow("检查更新") {
                        HStack(spacing: DmSpace.s8) {
                            if updates.status != .idle {
                                Text(updates.status.text)
                                    .font(.system(size: DmText.t11))
                                    .foregroundColor(updateStatusColor)
                            }
                            Button(updates.status == .newVersion ? "前往下载" : "立即检查") {
                                if updates.status == .newVersion, let url = updates.downloadURL {
                                    NSWorkspace.shared.open(url)
                                } else {
                                    Task { await updates.check() }
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle(on: .card))
                            .disabled(updates.isChecking)
                        }
                    }
                    // 官网整行可点（与下面的赞赏行同一形态）：指应用自己在官网上的
                    // 页面，不甩到主站首页 —— 主站首页是作品集，指着它等于让用户
                    // 自己再找一遍。完整网址收进悬停提示，行尾外链图标（三端同款）
                    // 表示「点整行会跳出去」。
                    Button {
                        if let url = URL(string: "https://dreamanual.com/works/nas.html") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: DmSpace.s6) {
                            Text("官网")
                                .font(.system(size: DmText.t13))
                                .foregroundColor(Color.dmInk)
                            Spacer(minLength: 0)
                            LucideIcon("square-arrow-out-up-right", size: DmIcon.i14)
                                .foregroundColor(siteHovered ? Color.dmAccent2 : Color.dmInk3)
                        }
                        .padding(.horizontal, DmSpace.s14)
                        .padding(.vertical, DmSpace.s12)
                        .background(
                            RoundedRectangle(cornerRadius: DmRadius.r6)
                                .fill(siteHovered ? Color.dmPanel3 : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .trackingHover($siteHovered)
                    .help("在浏览器中打开应用页面（dreamanual.com/works/nas.html）")
                    // 赞赏整行可点：不占标签右格，读上去是「一行入口」而不是「一个设置项」。
                    // 悬停与官网行同一形态：整行抬 panel-3，行内强调元素统一 accent-2
                    // （sky-400 压 panel-3 = 4.76 过 AA，不必再提 300 档）——
                    // 一行之内只允许一个悬停档，否则图标与文字深浅不一。
                    Button {
                        if let url = URL(string: "https://afdian.com/a/wuyifa001") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: DmSpace.s6) {
                            LucideIcon("coffee", size: DmIcon.i14)
                                .foregroundColor(Color.dmAccent2)
                            Text("请我喝杯咖啡")
                                .font(.system(size: DmText.t13))
                                .foregroundColor(Color.dmAccent2)
                            Spacer(minLength: 0)
                            LucideIcon("square-arrow-out-up-right", size: DmIcon.i14)
                                .foregroundColor(donateHovered ? Color.dmAccent2 : Color.dmInk3)
                        }
                        .padding(.horizontal, DmSpace.s14)
                        .padding(.vertical, DmSpace.s12)
                        .background(
                            RoundedRectangle(cornerRadius: DmRadius.r6)
                                .fill(donateHovered ? Color.dmPanel3 : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .trackingHover($donateHovered)
                }
            }
            // 内容宽与居中：对齐视频下载 / 密码管理的设置页（720 块内左对齐、
            // 左右 30、顶部 20、底部 40）—— 都是布局值，由窗口结构决定，不进尺度档。
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
            .padding(.top, DmSpace.s20)
            .padding(.bottom, 40)
        }
    }

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// 检查结果的状态色：成功取 `ok-ink`、发现新版取 `accent-2`、失败取
    /// `danger-ink` —— 都是浅档，压 `panel-2` 卡面时读得清。
    private var updateStatusColor: Color {
        switch updates.status {
        case .upToDate: return Color.dmOkInk
        case .newVersion: return Color.dmAccent2
        case .failed: return Color.dmDangerInk
        default: return Color.dmInk2
        }
    }

    /// 直连地址解析不了（端口不是数字、段数不对等）—— 重连会退回 QuickConnect。
    /// 留空不算错：那本来就是「走 QuickConnect」。
    private var isDirectAddressInvalid: Bool {
        !state.directAddress.isEmpty && DirectAddress.parse(state.directAddress) == nil
    }

    private var directAddressNote: String {
        if isDirectAddressInvalid {
            return "地址格式不对，重连时会改用 QuickConnect。请按“主机”或“主机:端口”填写，端口用数字。"
        }
        return "局域网或 Tailscale 地址，填了优先于 QuickConnect；改完点“重新连接”生效。"
    }
}

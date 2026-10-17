import AppKit
import Foundation
import Network
import Observation

/// 连接状态机 + 外壳需要的全部全局状态。
///
/// 这一版只做到「连上、两个会话都在、心跳活着」；曲库 / 文件 / 系统三个模块
/// 的取数各自在后面批次接 `SessionManager.call(...)`。
@MainActor
@Observable
final class AppState {
    enum Module: String, CaseIterable, Identifiable {
        case music, files, status, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .music: return "听歌"
            case .files: return "文件管理"
            case .status: return "系统状态"
            case .settings: return "设置"
            }
        }

        var icon: String {
            switch self {
            case .music: return "headphones"
            case .files: return "folder"
            case .status: return "gauge"
            case .settings: return "settings"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case resolving
        case loggingIn
        case connected
        case failed(String)

        var isBusy: Bool { self == .resolving || self == .loggingIn }

        var label: String {
            switch self {
            case .idle: return "未连接"
            case .resolving: return "正在解析端点…"
            case .loggingIn: return "正在登录…"
            case .connected: return "已连接"
            case let .failed(message): return message
            }
        }
    }

    /// 走的是哪条路：`direct` = 直连地址（局域网 / Tailscale 覆盖），
    /// `relay` = QuickConnect 中继。
    enum LinkMode {
        case direct, relay

        var label: String {
            switch self {
            case .direct: return "直连"
            case .relay: return "中继"
            }
        }
    }

    /// 连接页分段选的方式。判定连什么只认它，与表单里另一个字段是否
    /// 有值无关 —— 直连地址残留着的时候切去 QuickConnect，也得真走中继。
    enum ConnectMethod {
        case quickconnect, direct
    }

    // MARK: - 连接表单（持久化，口令除外）

    var qcID: String { didSet { defaults.set(qcID, forKey: Keys.qcID) } }
    var directAddress: String { didSet { defaults.set(directAddress, forKey: Keys.direct) } }
    var username: String { didSet { defaults.set(username, forKey: Keys.username) } }

    // MARK: - 运行状态

    private(set) var phase: Phase = .idle
    /// 最近一次 `connect` 抛的错（成功即清）。自动连的重试判据靠它分型：
    /// 口令被拒一族不再重试，其余（网络没就绪、中继抖一下）值得再试。
    private(set) var lastConnectError: (any Error)?
    /// 端点描述，连上之后显示在侧栏底部（走中继还是直连、主机端口、区域）。
    private(set) var endpointLabel = ""
    /// 链路的形态（状态页页头那颗徽章用）。
    ///
    /// 单独成一个枚举而不是去 `endpointLabel` 里认字符串：链路是**行为差别**，
    /// 不只是文案差别 —— 实测同一批请求，局域网直连的 `DirSize` 成功率
    /// 4/10、QuickConnect 中继 2/10（`接口结论.md` 第十节），页头上看得见才有用。
    private(set) var linkMode: LinkMode?
    private(set) var module: Module = .music
    private(set) var sessionManager: SessionManager?
    /// 播放引擎：连上之后创建，断开即卸。曲库页与播放条都读它。
    private(set) var playback: PlaybackEngine?
    /// 曲库页的状态（数据源 / 维度 / 筛选 / 分页）。
    ///
    /// 归属放在这里而不是 `LibraryView` 的 `@State`：沉浸模式会把曲库页从层级上
    /// 换下来，状态跟着视图走的话，进出一次沉浸模式曲库就退回「全部曲目」+
    /// 重新拉一千首。换个模块再回来同理 —— 视图是临时的，这份状态不是。
    let library = LibraryModel()
    /// 文件管理页的状态（共享夹 / 目录树 / 当前目录 / 排序 / 选中 / 分页）。
    /// 与曲库同一归属：换模块、从曲库跳过来都不该把浏览位置丢掉。
    let files = FileBrowser()
    /// 上传队列（进度 / 取消 / 撞名三选都在里面）。与文件页同一归属 —— 传着东西
    /// 切去听歌再切回来，进度得还在。
    let uploads = UploadQueue()
    /// 复制 / 移动的批次状态（模式 / 来源 / 撞名判定）+ 选目标弹窗。归属同上。
    let transfers = FileTransfer()
    /// 文件管理页的搜索状态（关键词 / 重试次数 / 结果 / 分页）。归属同上 ——
    /// 换模块再回来，结果还在；冒烟通路也要能在视图之外把它摆到各个状态。
    let search = FileSearch()
    /// 系统状态页的快照（机器信息 / 负载 / 容量 / 健康标志四块，各自可选）。
    /// 归属同上：换模块回来不该重新转一次圈。
    let status = SystemStatusModel()
    /// 开关机计划（服务端那一份 + 界面上在编的那一份）。归属同上 —— 换模块再回来，
    /// 改到一半的开关还在，别让人重拨一遍。
    let powerSchedule = PowerScheduleModel()
    /// 播放队列占主区（原型「队列」屏）—— 从播放条的队列按钮进出，
    /// 侧栏没有队列这一项。
    private(set) var showsQueue = false
    /// 沉浸模式（原型「沉浸模式」屏）：收掉侧栏、播放条保留。从播放条的封面 /
    /// 歌名进出，Esc 或右上角关闭钮退出。
    private(set) var showsImmersive = false
    private(set) var lastConnectedAt: Date?

    /// 窗口底部那条短提示。放全局是因为触发点不止一处 —— 曲库表与播放条
    /// 各有评分入口，两侧都该落到同一条提示上。
    var toast: ToastMessage?

    private let defaults = UserDefaults.standard
    private let resolver = QuickConnectResolver()

    private enum Keys {
        static let qcID = "nas.qcID"
        static let direct = "nas.directAddress"
        static let username = "nas.username"
        static let method = "nas.connectMethod"
    }

    /// 上一次成功连接用的方式。凭据的端点键跟着它走，启动自动连也按它
    /// 恢复 —— 不看 `directAddress` 是否残留（老数据的兜底判定留在
    /// `endpointKey` 里，存量用户升级后凭据条目不变）。
    private var lastMethod: ConnectMethod?

    init() {
        qcID = defaults.string(forKey: Keys.qcID) ?? ""
        directAddress = defaults.string(forKey: Keys.direct) ?? ""
        username = defaults.string(forKey: Keys.username) ?? ""
        lastMethod = Self.method(from: defaults.string(forKey: Keys.method))
    }

    private static func method(from raw: String?) -> ConnectMethod? {
        switch raw {
        case "quickconnect": return .quickconnect
        case "direct": return .direct
        default: return nil
        }
    }

    private static func raw(of method: ConnectMethod) -> String {
        switch method {
        case .quickconnect: return "quickconnect"
        case .direct: return "direct"
        }
    }

    /// 自动连 / 重启等待这些「看不见界面」的连接该按哪条路走：
    /// 上次成功的方式；没有记录（升级前）退回旧判定 —— 直连地址填了就算直连。
    private var resumeMethod: ConnectMethod {
        lastMethod ?? (DirectAddress.parse(directAddress) != nil ? .direct : .quickconnect)
    }
    var isConnected: Bool { phase == .connected }

    func select(_ module: Module) {
        self.module = module
        showsQueue = false
        showsImmersive = false
    }

    /// 播放条的队列按钮：主区在曲库 ↔ 队列之间切。
    func toggleQueue() {
        showsImmersive = false
        if module != .music {
            select(.music)
            showsQueue = true
            return
        }
        showsQueue.toggle()
    }

    // MARK: - 沉浸模式

    /// 播放条的封面 / 歌名进出沉浸模式。只有队列里有歌才进得去 ——
    /// 没有正在播的歌，那一屏没有内容可铺。
    func toggleImmersive() {
        guard playback?.hasQueue == true else { return }
        showsImmersive.toggle()
    }

    func closeImmersive() {
        showsImmersive = false
    }

    /// 沉浸模式里点歌手名：回曲库、代入该歌手的筛选（原型那一屏的说明行）。
    func showSongs(byArtist name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        showsImmersive = false
        showsQueue = false
        module = .music
        await library.apply(trimmed, in: .artist, on: sessionManager)
    }

    // MARK: - 提示

    func showToast(_ text: String, _ kind: DmToast.Kind) {
        toast = ToastMessage(text, kind)
    }

    // MARK: - 评分

    /// 评分（0–5，0 = 清除）。写的是 Audio Station 的评分字段，**写完回读校验**
    /// —— `Song.setrating` 对一个不存在的 id 也回 `success`，成功标志不可信。
    /// 落地了才改界面，返回落地值；没落地就落一条失败提示、返回 `nil`。
    ///
    /// 队列里同一首一并同步：播放条读的是队列里的那一份。
    @discardableResult
    func rate(_ songID: String, to stars: Int) async -> Int? {
        guard let manager = sessionManager else { return nil }
        do {
            let applied = try await AudioLibrary.setRating(manager, songID: songID, rating: stars)
            playback?.applyRating(songID: songID, rating: applied)
            showToast(applied == 0 ? "已清除评分" : "已评 \(applied) 星", .ok)
            return applied
        } catch {
            showToast(error.localizedDescription, .err)
            return nil
        }
    }

    // MARK: - 歌曲右键菜单

    /// 歌曲右键菜单的锚点与目标。挂全局而不是行里：菜单要浮在**整个窗口**之上，
    /// 而画在行里会被后面的行盖住、也会被滚动区裁掉（原型 `.menu` 也是绝对定位）。
    private(set) var songMenu: SongMenuRequest?

    struct SongMenuRequest: Identifiable {
        let id = UUID()
        let song: AudioSong
        /// 根视图坐标（左上原点）。
        let point: CGPoint
        /// 点开菜单时那一屏的曲目 —— 菜单里的「播放」拿它当队列（与双击同义）。
        let queue: [AudioSong]
    }

    func openSongMenu(_ song: AudioSong, at point: CGPoint, queue: [AudioSong]) {
        // TODO(诊断): 右键漂移排查，定位完拆。歌名进日志 —— 菜单是谁的一眼可对。
        rcDebugLog("菜单打开「\(song.artist) - \(song.title)」· 请求点 (\(Int(point.x)),\(Int(point.y)))")
        songMenu = SongMenuRequest(song: song, point: point, queue: queue)
    }

    func closeSongMenu() {
        songMenu = nil
    }

    /// 菜单「播放」：这一屏整体成为队列，从这首起播（同双击）。
    func playFromMenu(_ request: SongMenuRequest) {
        playback?.play(request.queue, songID: request.song.id)
    }

    /// 菜单「下一首播放」：只把这一首插到当前播放位置后面，队列其余不动。
    func playNext(_ song: AudioSong) {
        guard let engine = playback else { return }
        engine.insertNext(song)
        showToast("「\(song.title)」已排到下一首", .ok)
    }

    // MARK: - 编辑歌曲信息

    /// 标签编辑弹窗的状态。`info` 与 `loadError` 二者先后到 —— 读回了才能编辑。
    private(set) var tagEditor: TagEditorState?

    struct TagEditorState: Identifiable {
        let id = UUID()
        let song: AudioSong
        /// NAS 读回来的现值（表单初值）。还在读时是 nil。
        var info: SongTagInfo?
        /// 读 / 写失败的原因（读写共用一槽：都占卡片中部那条提示位）。
        var errorMessage: String?
        /// 写入进行中（确认钮转圈、防重复提交）。
        var isSaving = false
    }

    /// 菜单「编辑歌曲信息」：开弹窗并去 NAS 读现值（标签编辑接口，见 `TagEditor`）。
    func openTagEditor(_ song: AudioSong) {
        guard let manager = sessionManager else { return }
        tagEditor = TagEditorState(song: song)
        Task {
            do {
                let info = try await TagEditor.load(manager, path: song.path)
                if tagEditor?.song.id == song.id { tagEditor?.info = info }
            } catch {
                if tagEditor?.song.id == song.id {
                    tagEditor?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func closeTagEditor() {
        tagEditor = nil
    }

    // MARK: - 立刻关机 / 重启

    /// 关机 / 重启的确认弹窗（挂在根视图的 `.dmModal`，与写操作弹窗同层）。
    /// 两颗都要二次确认（原型 data-note：确认框里列出影响）。
    enum PowerConfirm: Equatable {
        case shutdown
        case reboot
    }

    private(set) var powerConfirm: PowerConfirm?

    func openPowerConfirm(_ kind: PowerConfirm) {
        powerConfirm = kind
    }

    func closePowerConfirm() {
        powerConfirm = nil
    }

    private var powerConfirmBusy = false

    /// 确认框里点下去：发指令、本地断开；重启再起一条专用等待重连。
    ///
    /// 🔴 这条指令**没有回读**（`SystemPowerAPI` 头注释）—— 应答 success 只证明
    /// NAS 收到了，不证明它已经（或将会）照做；所以成功与否的后续判据不在界面，
    /// 而在链路监控（NAS 掉了面板转离线）与重启等待重连（回来了自动补连）。
    func confirmPower(_ kind: PowerConfirm) async {
        guard let manager = sessionManager, !powerConfirmBusy else { return }
        powerConfirmBusy = true
        defer { powerConfirmBusy = false }
        do {
            try await SystemPowerAPI.power(kind == .shutdown ? .shutdown : .reboot,
                                           on: manager)
        } catch {
            NSLog("[power] %@ 指令失败：%@",
                  kind == .shutdown ? "关机" : "重启", String(describing: error))
            showToast("指令没发出去 —— \(error.localizedDescription)", .err)
            return
        }
        let endpoint = endpointKey
        let user = trimmedUsername
        powerConfirm = nil
        // 会话马上就没用了：本地先断干净（停保活、清快照），面板转离线。
        await disconnect()
        if kind == .shutdown {
            showToast("关机指令已发出，NAS 正在下电", .ok)
        } else {
            showToast("重启指令已发出，NAS 回来就自动重连", .ok)
            startRebootReconnect(endpoint: endpoint, user: user)
        }
    }

    private var rebootReconnectTask: Task<Void, Never>?

    /// 重启后的专用等待重连。NAS 下电到回来约 2 分钟，常规自动连五把
    /// （0/5/15/30/60 秒）撑不过这个窗口 —— 这条每 20 秒探一把、最多 5 分钟；
    /// 到点收手留给手动。用户中途自己动手（连 / 断）时随 `cancelAutoConnect`
    /// 一起取消，不跟人抢方向盘。
    func startRebootReconnect(endpoint: String, user: String) {
        rebootReconnectTask?.cancel()
        rebootReconnectTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...15 {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if Task.isCancelled { return }
                if self.isConnected || self.phase.isBusy { return }
                let saved = await Task.detached(priority: .utility) {
                    CredentialStore.load(endpointID: endpoint, username: user)
                }.value
                guard let password = saved else {
                    NSLog("[connect] 重启等待：拿不到凭据，收手")
                    return
                }
                NSLog("[connect] 重启等待第 %d 把", attempt)
                await self.connect(password: password, method: self.resumeMethod)
                if self.isConnected {
                    NSLog("[connect] 重启完成，已自动重连")
                    return
                }
            }
            NSLog("[connect] 重启等待超时（5 分钟），等手动重连")
        }
    }

    // MARK: - 新增 / 编辑开关机计划

    /// 新增 / 编辑计划任务的弹窗（挂在根视图的 `.dmModal`，与写操作弹窗同层）。
    /// 🔴 **显式模式，不用可选下标**：新增没有「第几条」可指，可选下标会把
    /// 新增态表示成 nil、与「弹窗没开」混同 —— 点「新增任务」就什么都不发生
    /// （真机踩过：编辑好使、新增点不动）。
    enum PowerEditor: Hashable {
        /// 追加一条到表尾。
        case add
        /// 编辑第 `index` 条（预填现状）。
        case edit(index: Int)
    }

    private(set) var powerEditor: PowerEditor?

    var showsPowerEditor: Bool { powerEditor != nil }

    func openPowerAdd() {
        guard powerSchedule.isReady else { return }
        powerEditor = .add
    }

    func openPowerEdit(_ index: Int) {
        guard powerSchedule.isReady, powerSchedule.tasks.indices.contains(index) else { return }
        powerEditor = .edit(index: index)
    }

    func closePowerEditor() {
        powerEditor = nil
    }

    // MARK: - 计划行右键菜单

    /// 计划行的右键菜单（编辑 / 删除）。挂在根上 —— 行在卡片里，菜单画在行里
    /// 会被盖住；与歌曲 / 文件两个菜单同一归属。
    struct PowerRowMenuRequest: Identifiable {
        let id = UUID()
        let index: Int
        let point: CGPoint
    }

    private(set) var powerRowMenu: PowerRowMenuRequest?

    func openPowerRowMenu(_ index: Int, at point: CGPoint) {
        // 写回在途不出菜单：菜单里的动作都要写 NAS，在途时点了也得排队或被锁。
        guard powerSchedule.isReady, !powerSchedule.isWriting else { return }
        powerRowMenu = PowerRowMenuRequest(index: index, point: point)
    }

    func closePowerRowMenu() {
        powerRowMenu = nil
    }

    /// 弹窗「保存」：真写 ID3 到 NAS 文件（索引 0 秒跟上）。落地后改曲库行与
    /// 队列里那两份拷贝 —— 不整页重拉（与评分同一条道理）。
    func saveTagEditor(_ info: SongTagInfo) async {
        guard let manager = sessionManager, let editor = tagEditor, !editor.isSaving else { return }
        tagEditor?.isSaving = true
        do {
            try await TagEditor.apply(manager, path: editor.song.path, tags: info)
            library.applyTags(info, to: editor.song.id)
            playback?.applyTags(info, to: editor.song.id)
            tagEditor = nil
            showToast("「\(info.title)」标签已写入", .ok)
        } catch {
            tagEditor?.isSaving = false
            tagEditor?.errorMessage = error.localizedDescription
        }
    }

    // MARK: - 下载

    /// 右键「下载」：先让用户挑存哪儿，再把曲库里那个**原始文件**拉下来。
    ///
    /// 走文件会话的 `FileStation.Download`（与预取大封面同一条），拿的是原文件
    /// 而不是转码流。进度不给 —— Toast 一刷新就重开计时、还重播入场，反而看不清；
    /// 落地时一条「已保存」更实在。
    func download(_ song: AudioSong) async {
        guard let manager = sessionManager else { return }
        guard let destination = Self.askDestination(for: song) else { return }
        showToast("正在下载「\(song.title)」…", .info)
        do {
            let endpoint = try await manager.fileEndpoint
            try await FileDownloader(
                baseURL: endpoint.baseURL,
                credentials: endpoint.credentials,
                allowSelfSigned: endpoint.allowSelfSigned,
                destination: destination
            ).start(path: song.path)
            showToast("已保存「\(destination.lastPathComponent)」", .ok)
        } catch {
            showToast(error.localizedDescription, .err)
        }
    }

    /// 保存面板。默认文件名「歌手 - 标题.扩展名」—— 扩展名取自曲库路径（取不到
    /// 就不带），别写死 `.mp3`：库里 flac / m4a 都有。
    private static func askDestination(for song: AudioSong) -> URL? {
        askDestination(downloadName(for: song))
    }

    /// 文件管理里下载一个文件：默认名就是原文件名（文件名是 NAS 上那个，
    /// 不重拼 —— 用户在这一屏看到什么名字，存下来就该是什么名字）。
    func download(file entry: FileEntry) async {
        guard !entry.isDirectory, let manager = sessionManager else { return }
        guard let destination = Self.askDestination(entry.name) else { return }
        showToast("正在下载「\(entry.name)」…", .info)
        do {
            let endpoint = try await manager.fileEndpoint
            try await FileDownloader(
                baseURL: endpoint.baseURL,
                credentials: endpoint.credentials,
                allowSelfSigned: endpoint.allowSelfSigned,
                destination: destination
            ).start(path: entry.path)
            showToast("已保存「\(destination.lastPathComponent)」", .ok)
        } catch {
            showToast(error.localizedDescription, .err)
        }
    }

    /// 共享的保存面板（曲库「下载原文件」与文件管理两处同一条）。
    private static func askDestination(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "下载到"
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func downloadName(for song: AudioSong) -> String {
        var base = song.artist.isEmpty ? song.title : "\(song.artist) - \(song.title)"
        for bad in ["/", ":", "\\"] {
            base = base.replacingOccurrences(of: bad, with: "_")
        }
        let ext = StreamLoader.fileExtension(of: song)
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    // MARK: - 文件管理 · 搜索

    /// 搜索框回车（或清除钮）进来的那条路。
    ///
    /// 范围 = **当前所在目录往下递归** —— 文件管理里「搜索」是指着这一层找东西，
    /// 不是全库找（全库那种留给选目标弹窗的客户端筛选）。空串在 `FileSearch.run`
    /// 里当「退出搜索」处理。
    func submitFileSearch() async {
        await search.run(search.query, in: files.currentPath, on: sessionManager)
    }

    /// 搜索进度行上那个「停止」。
    func cancelFileSearch() async {
        await search.clear(on: sessionManager)
    }

    /// 点一行搜索结果：跳回浏览态，落到它所在的位置上。
    ///
    /// 这是搜索结果行**唯一**的动作（结果行不可多选）：搜索负责「找到」，复制 / 移动 /
    /// 删除在浏览态做 —— 那边才有选中集合。目录直接进去；文件进它所在目录并**选中它**，
    /// 于是下载 / 重命名 / 删除接着就能用。
    func openSearchHit(_ hit: FileSearchHit) async {
        let manager = sessionManager
        await search.clear(on: manager)
        if hit.isDirectory {
            await files.open(hit.path, on: manager)
            return
        }
        let folder = hit.parent
        await files.open(folder, on: manager)
        if let entry = files.entries.first(where: { $0.path == hit.path }) {
            files.select(entry)
        }
    }

    // MARK: - 文件管理 · 目录大小

    /// 算选中那个目录的体积（右键菜单那一项）。
    ///
    /// `DirSize` 慢且不稳（一次问一个目录，内部带重试），所以不在界面上挡任何东西：
    /// 状态栏会显示「正在计算…」，算完数值进那一行的大小列。失败给一条提示，
    /// 不弹窗 —— 它是顺手问一句的事。
    func measureFileSelection() async {
        guard let manager = sessionManager else { return }
        await files.measureSelection(on: manager)
        if let message = files.measureError {
            showToast(message, .err)
        } else if let entry = files.singleSelection,
                  let size = files.sizes[entry.path] {
            showToast("\(entry.name) · \(size.text)（\(size.detailText)）", .ok)
        }
    }

    /// 用户不等了（状态栏 / 菜单里那一项）。
    func cancelFileMeasure() {
        files.cancelMeasure()
    }

    // MARK: - 在文件管理中显示

    /// 曲库右键「在文件管理中显示」：切到文件管理模块，并打开这首歌所在的那个目录。
    ///
    /// 目录直接取 `song.path` 的父级（曲库路径就是 NAS 上的真实路径，与「下载原文件」
    /// 同一条依据），不靠名字拼 —— 曲库的艺术家 / 专辑名与目录名并不总是一样。
    func revealInFiles(_ song: AudioSong) async {
        closeSongMenu()
        select(.files)
        let folder = song.folder
        guard !folder.isEmpty else {
            showToast("这首歌没有可定位的目录", .err)
            return
        }
        await files.open(folder, on: sessionManager)
    }

    // MARK: - 文件管理 · 写操作

    /// 文件管理的弹窗请求。挂全局而不是 `FilesView` 的 `@State`：弹窗要盖住整个窗口
    /// （连播放条一起），而且冒烟通路得在视图之外把它摆出来截图核对。
    enum FileDialog: Identifiable {
        /// 在哪个目录里建 —— 建的位置要跟着**开它的地方**走：工具条上建在浏览到的
        /// 当前目录，选目标弹窗里建在**用户选中的目标**上（在那儿新建往往正是为了
        /// 把它当目标，建到别处等于白建）。
        case newFolder(in: String)
        case rename(FileEntry)
        case delete([FileEntry])

        var id: String {
            switch self {
            case .newFolder(let path): return "newfolder:\(path)"
            case .rename(let entry): return "rename:\(entry.path)"
            case .delete(let entries): return "delete:\(entries.count)"
            }
        }
    }

    private(set) var fileDialog: FileDialog?

    func openFileDialog(_ dialog: FileDialog) { fileDialog = dialog }
    func closeFileDialog() { fileDialog = nil }

    /// 名称检查：`nil` 表示能用。非法字符与重名都在客户端先拦。
    ///
    /// 这一步不能省 —— **建文件夹那条接口重名回成功**（返回已存在目录的 path、实际
    /// 什么也没做，2026-10-14 复验），服务端的成功应答在这件事上不可信。`Rename`
    /// 服务端会拦，本地先判只是省一趟往返。
    ///
    /// 重名按**逐字比较**（区分大小写）：实测把 `same6.txt` 改成 `Same6.TXT` 是合法的，
    /// 用不区分大小写的比较会把这种改名误拦。
    static func nameProblem(_ name: String, among entries: [FileEntry], excluding: FileEntry? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "名称不能为空。" }
        if trimmed.rangeOfCharacter(from: illegalNameCharacters) != nil {
            return "不能包含 \\ / : * ? \" < > | 这些字符。"
        }
        if entries.contains(where: { $0.name == trimmed && $0.path != excluding?.path }) {
            return "这个目录里已经有叫「\(trimmed)」的项了。"
        }
        return nil
    }

    /// 名称里的非法字符（DSM 的规矩，原型的提示行照这个写）。
    static let illegalNameCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")

    /// 新建文件夹。**先查重名** —— 服务端对已存在的名字回成功，靠返回码判会报成新建好了。
    ///
    /// 两个调用点：文件管理的工具条（`in` = 当前浏览目录）与选目标弹窗的脚部（`in` =
    /// 用户选中的目标）。后者建完**顺手把新文件夹选成目标** —— 用户在那儿新建，想去的
    /// 就是它。
    func createFolder(named name: String) async {
        guard let dialog = fileDialog, case .newFolder(let directory) = dialog else { return }
        guard let manager = sessionManager else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if try await FileStation.exists(manager, in: directory, name: trimmed) {
                showToast("这个目录里已经有叫「\(trimmed)」的项了", .err)
                return
            }
            try await FileStation.createFolder(manager, path: directory, name: trimmed)
            closeFileDialog()
            showToast("已新建「\(trimmed)」", .ok)
            if directory == files.currentPath {
                await files.refresh(manager, username: username)
            } else {
                // 建在选目标弹窗里：只重拉那一层，并把新夹选成目标。
                let path = directory.hasSuffix("/") ? directory + trimmed : directory + "/" + trimmed
                await transfers.picker.reload(directory, on: manager)
                transfers.picker.select(path)
            }
        } catch {
            showToast(error.localizedDescription, .err)
        }
    }

    /// 重命名（一次一项）。与「新建文件夹」同构，只有接口与文案不同。
    func rename(_ entry: FileEntry, to name: String) async {
        guard let manager = sessionManager else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 名字没改就直接收工 —— 不该为一次空操作发请求，也不该弹「已改名」。
        guard trimmed != entry.name else {
            closeFileDialog()
            return
        }
        do {
            try await FileStation.rename(manager, path: entry.path, to: trimmed)
            closeFileDialog()
            showToast("已改名为「\(trimmed)」", .ok)
            await files.refresh(manager, username: username)
        } catch {
            showToast(Self.renameFailure(error, name: trimmed), .err)
        }
    }

    /// `Rename` 撞名是 `1200` + `errors[{414}]`，翻成一句能照做的。
    private static func renameFailure(_ error: Error, name: String) -> String {
        if let synology = error as? SynologyError,
           synology.errors.contains(where: { ($0["code"] as? NSNumber)?.intValue == 414 }) {
            return "这个目录里已经有叫「\(name)」的项了"
        }
        return error.localizedDescription
    }

    /// 删除（确认过的那些）。**判成败看任务的 `errors`，不看 `finished`** —— 没递归
    /// 删非空目录时任务照样报 `finished`，只有 `errors` 里才看得出没删掉。
    /// 删除不进回收站，这件事情由确认弹窗对用户写死（见 `FilesView`）。
    func delete(_ entries: [FileEntry]) async {
        guard let manager = sessionManager, !entries.isEmpty else { return }
        do {
            let task = try await FileStation.delete(manager, paths: entries.map(\.path))
            closeFileDialog()
            if task.failed {
                showToast(task.failureText, .err)
            } else if entries.count == 1 {
                showToast("已删除「\(entries[0].name)」", .ok)
            } else {
                showToast("已删除 \(entries.count) 项", .ok)
            }
            await files.refresh(manager, username: username)
        } catch {
            // 超时或会话断了：弹窗照关，错误照报，列表重拉一遍看真实情况。
            closeFileDialog()
            showToast(error.localizedDescription, .err)
            await files.refresh(manager, username: username)
        }
    }

    // MARK: - 文件管理 · 上传

    /// 打开系统的选文件面板，挑完就传到当前目录。
    ///
    /// 面板是 AppKit 的模态（`runModal`）—— 它就是系统那一套，与第八节的自绘弹窗
    /// 不冲突：自绘弹窗管的是「应用自己的界面」，选本机文件这件事没有别的做法。
    /// 文件与文件夹都能选：文件夹按原型支持（里面的每个文件各自成一项）。
    func pickAndUpload() {
        guard sessionManager != nil else { return }
        guard files.currentCanWrite else {
            showToast("这个目录不可写，换个位置再传", .err)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        panel.message = "选文件或文件夹，传到「\(files.currentPath)」"
        guard panel.runModal() == .OK else { return }
        upload(urls: panel.urls)
    }

    /// 开传。撞名与否由队列自己先查，冲突时它会停下来问用户。
    ///
    /// 列表**只有装满整层才算数**时才顺手交给队列：界面上那张表是一页（1000 项），
    /// `/music` 有 3622 项 —— 拿首页当全部会把首页之外的撞名全漏掉（2026-10-14
    /// 冒烟抓到的真问题：测试件落在第 4 页，撞名检查没看见，直接传了第二份上去）。
    /// 装不下就让队列自己去拉满一层，多一趟往返换判定准确。
    func upload(urls: [URL]) {
        guard let manager = sessionManager, !urls.isEmpty else { return }
        guard files.currentCanWrite else {
            showToast("这个目录不可写，换个位置再传", .err)
            return
        }
        uploads.onBatchEnd = { [weak self] in await self?.finishUploadBatch() }
        let target = files.currentPath
        let complete = files.entries.count >= files.total ? files.entries : nil
        Task {
            await uploads.prepare(urls: urls, target: target,
                                  knownEntries: target == files.currentPath ? complete : nil,
                                  manager: manager)
        }
    }

    /// 冲突弹窗上的一票。
    func resolveUploadConflict(_ choice: UploadQueue.ConflictChoice, applyToAll: Bool) {
        guard let manager = sessionManager else { return }
        Task { await uploads.resolve(choice, applyToAll: applyToAll, manager: manager) }
    }

    /// 取消这一批（正在传的那一条断掉，剩下的不再传）。
    func cancelUploads() {
        guard uploads.items.contains(where: { $0.state == .uploading }) || uploads.conflict != nil else { return }
        uploads.cancel()
    }

    /// 一批传完（或停下）之后：收掉结束的行、重拉列表、报一句结果。
    ///
    /// 收尾提示只报「传完了多少」——失败那一项在列表上方那一行里写着原因，
    /// 再弹一条一样的提示只是噪音。
    func finishUploadBatch() async {
        guard let manager = sessionManager else { return }
        let done = uploads.items.filter { $0.state == .done && !$0.isDirectory }.count
        let failed = uploads.items.contains { if case .failed = $0.state { return true } else { return false } }
        uploads.dismissFinished()
        await files.refresh(manager, username: username)
        if !failed, done > 0 {
            showToast("已上传 \(done) 项", .ok)
        }
    }

    // MARK: - 文件管理 · 复制 / 移动

    /// 工具条上的「复制到…」「移动到…」：带上当前选中项，开选目标弹窗。
    ///
    /// **只有移动要来源目录可写** —— 复制是读来源、写目标，来源只读照样能复制。
    func beginTransfer(_ mode: FileTransfer.Mode) {
        guard sessionManager != nil else { return }
        let picked = files.selectedEntries
        guard !picked.isEmpty else { return }
        if mode == .move, !files.currentCanWrite {
            showToast("这个目录不可写，移不动里面的东西", .err)
            return
        }
        transfers.begin(mode, sources: picked, currentPath: files.currentPath)
        Task {
            await transfers.picker.open(
                currentPath: files.currentPath, shares: files.shares, on: sessionManager
            )
        }
    }

    func cancelTransfer() {
        transfers.cancel()
    }

    /// 选目标弹窗／撞名弹窗的开合状态 —— 根视图照它挂遮罩。
    var showsTransferPicker: Bool { transfers.isOpen && transfers.conflict == nil }
    var showsTransferConflict: Bool { transfers.conflict != nil }

    /// 弹窗上确认：先在目标层查一遍撞名，没撞的直接跑，撞了先问。
    ///
    /// 🔴 **撞名必须客户端先查**：撞名的文件服务端会跳过，任务却照报 `finished` +
    /// `success`（`skipstatus` 只说明「有同名项」，撞名的目录它还会照合并）——
    /// 返回码在这件事上什么都没说。
    func confirmTransfer() async {
        guard let manager = sessionManager, let mode = transfers.mode,
              transfers.blockingReason == nil else { return }
        let destination = transfers.picker.target
        let sources = transfers.sources
        do {
            let page = try await FileStation.list(
                manager, path: destination, sort: FileStation.defaultSort,
                limit: FileStation.treeFetchLimit
            )
            let taken = Set(page.entries.map(\.name))
            let clashes = sources.filter { taken.contains($0.name) }
            if clashes.isEmpty {
                await runTransfer(sources, to: destination, mode: mode, overwrite: true, skipped: 0)
            } else {
                transfers.raiseConflict(FileTransfer.Conflict(
                    mode: mode, destination: destination, clashes: clashes,
                    clean: sources.filter { !taken.contains($0.name) }
                ))
            }
        } catch {
            showToast(error.localizedDescription, .err)
        }
    }

    /// 撞名弹窗上的一票。
    ///
    /// 替换 = 整个批次 `overwrite=true` 发过去（文件真覆盖，目录按服务端规则合并）；
    /// 跳过 = **只把没撞名的那几项发过去** —— 服务端对撞名目录是合并、不是跳过，
    /// 靠 `overwrite=false` 表达不出「跳过目录」这件事。
    func resolveTransfer(_ choice: FileTransfer.ConflictChoice) async {
        guard let conflict = transfers.conflict else { return }
        transfers.clearConflict()
        guard transfers.mode != nil else { return }
        switch choice {
        case .replace:
            await runTransfer(conflict.clashes + conflict.clean, to: conflict.destination,
                              mode: conflict.mode, overwrite: true, skipped: 0)
        case .skip:
            await runTransfer(conflict.clean, to: conflict.destination,
                              mode: conflict.mode, overwrite: false, skipped: conflict.clashes.count)
        }
    }

    /// 真跑那一趟：异步任务 → 报一句 → 收弹窗 → 重拉列表。
    private func runTransfer(
        _ entries: [FileEntry],
        to destination: String,
        mode: FileTransfer.Mode,
        overwrite: Bool,
        skipped: Int
    ) async {
        guard let manager = sessionManager else { return }
        transfers.setBusy(true)
        defer { transfers.setBusy(false) }
        do {
            let task = try await FileStation.copyMove(
                manager, paths: entries.map(\.path), to: destination,
                move: mode == .move, overwrite: overwrite
            )
            transfers.cancel()
            showToast(task.failed
                      ? task.failureText
                      : Self.transferText(mode: mode, done: entries.count, skipped: skipped,
                                          destination: destination),
                      task.failed ? .err : .ok)
        } catch {
            transfers.cancel()
            showToast(error.localizedDescription, .err)
        }
        await files.refresh(manager, username: username)
    }

    /// 结果那句话。没跳过的只说去了哪儿；跳过了把两个数都报出来。
    static func transferText(
        mode: FileTransfer.Mode, done: Int, skipped: Int, destination: String
    ) -> String {
        let place = DestinationPicker.shortPath(destination)
        if skipped == 0 { return "已\(mode.verb) \(done) 项到「\(place)」" }
        if done == 0 { return "\(skipped) 项同名，已跳过" }
        return "已\(mode.verb) \(done) 项到「\(place)」，跳过 \(skipped) 项同名"
    }

    // MARK: - 文件右键菜单

    /// 文件列表的右键菜单请求。与歌曲菜单同一归属（挂全局）—— 菜单要浮在整个窗口
    /// 之上，而且菜单项与数量按**选中的那一组**出，不归某一行管。
    struct FileMenuRequest: Identifiable {
        let id = UUID()
        let entries: [FileEntry]
        /// 根视图坐标（左上原点）。
        let point: CGPoint
    }

    private(set) var fileMenu: FileMenuRequest?

    /// 行上按右键。落在没选中的行上先把它选上（访达的做法）—— 菜单项带的数量必须
    /// 与随后真被操作的那一组一致，否则「删除（3 个）」可能只删掉 1 个。
    func openFileMenu(for entry: FileEntry, at point: CGPoint) {
        if !files.isSelected(entry.path) { files.select(entry) }
        closeSongMenu()
        fileMenu = FileMenuRequest(entries: files.selectedEntries, point: point)
    }

    func closeFileMenu() { fileMenu = nil }

    // MARK: - 键盘

    /// 空格 = 播放 / 暂停，← / → = 后退 / 前进 `seekStep` 秒。
    ///
    /// 用**本地事件监听**而不是 `.keyboardShortcut`：快捷键挂在 Button 上时
    /// `performKeyEquivalent` 会先于文本框拿到按键 —— 曲库的搜索框里打一个空格
    /// 就变成了暂停。这里先看第一响应者，是文本输入就原样放行。
    ///
    /// 媒体键（Mac 的 F8）不走这里，那是系统按键 —— 见 `NowPlaying`。
    static let seekStep: Double = 5

    private var keyMonitor: Any?

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // `NSEvent` 不是 Sendable，别把它带进 `assumeIsolated` 的闭包里 ——
            // 先把要用的两个值取出来再跳。
            let code = event.keyCode
            let flags = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                self?.handleKey(code: code, flags: flags) ?? false
            }
            return handled ? nil : event
        }
    }

    /// 认了这个键就返回 true（事件被吃掉，不再往下传）。
    @discardableResult
    func handleKey(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        // Esc：菜单开着就先收菜单。
        if code == 53 {
            if songMenu != nil { closeSongMenu(); return true }
            if fileMenu != nil { closeFileMenu(); return true }
            // 冲突弹窗也是模态的，Esc 一样要能收 —— 收掉等于取消这一批上传。
            if uploads.conflict != nil { cancelUploads(); return true }
            // 复制 / 移动的撞名弹窗 Esc 退回选目标（换个目录再试）；选目标弹窗 Esc 整个收掉。
            if transfers.conflict != nil { transfers.clearConflict(); return true }
            if transfers.isOpen { cancelTransfer(); return true }
            // 搜索态：Esc 退出搜索回浏览态（结果行只负责「找到」，跳回去才谈得上操作）。
            // 收尾要调接口（stop + clean），所以甩进一个 Task —— `handleKey` 是同步的。
            if search.isActive {
                Task { await cancelFileSearch() }
                return true
            }
        }
        let modifiers = flags.intersection(.deviceIndependentFlagsMask)
        // Cmd+A：文件管理页全选当前列表。这条放在「⌘ 组合一律放行」**之前** ——
        // 那条是给系统与菜单的快捷键让路，而这是本模块自己的快捷键。光标在文本里
        // 时照样让路（输入框里的 Cmd+A 是「全选文字」）。
        if code == 0, modifiers.contains(.command), module == .files, !isEditingText {
            files.selectAll()
            return true
        }
        // ⌘ / ⌥ / ⌃ 的组合一律放行 —— 系统与菜单的快捷键优先。
        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
        // 光标在文本里就放行：搜索框要能打空格。
        guard !isEditingText, let engine = playback else { return false }

        switch code {
        case 49: engine.togglePlayPause()
        case 123: engine.seek(to: engine.currentTime - Self.seekStep)
        case 124: engine.seek(to: engine.currentTime + Self.seekStep)
        default: return false
        }
        return true
    }

    /// 第一响应者是不是文本输入。SwiftUI 的输入框在编辑时第一响应者是**字段
    /// 编辑器**（一个 `NSTextView`），`SecureField` 也一样。
    ///
    /// 问的是同一个 `hostingWindow()` —— 拿 `NSApp.keyWindow` 直取会在启动时序里
    /// 问到别的窗口，判据跟着飘。
    private var isEditingText: Bool {
        hostingWindow()?.firstResponder is NSTextView
    }

    /// 曲库页搜索框的聚焦请求，每加一就聚焦一次。给冒烟通路用：真机上没法用脚本
    /// 点进输入框，而 AppKit 那边硬塞第一响应者会被 SwiftUI 的焦点机制顶回来。
    private(set) var searchFocusTicket = 0
    func requestSearchFocus() { searchFocusTicket += 1 }

    /// `DM_KEYS=<逗号分隔>` 时由入口调用：按顺序发一遍按键，每步打引擎状态。
    ///
    /// 事件走 `NSApp.postEvent` 进事件队列 —— 与真按键同一条路（本地监听器、
    /// 响应链都在里面），比自己调 `handleKey` 更能证明接线是通的。
    /// 认得的名字：`space` / `left` / `right` / `search`。
    func smokeKeys(_ list: String) async {
        guard let engine = playback else {
            NSLog("[keys] 没有播放引擎，跳过")
            return
        }
        // 队列空就先播一首 —— 不然空格只是空转，看不出接线通没通。
        // 这样 `DM_KEYS` 自己就是一趟完整核对，不必再叠 `DM_SMOKE`（那趟跑完会切到
        // 队列页，曲库的搜索框就不在视图树里了，`search` 记号会找不到）。
        if !engine.hasQueue, isConnected, let manager = sessionManager {
            if let page = try? await AudioLibrary.songs(manager, limit: 20),
               let first = page.songs.first {
                NSLog("[keys] 队列是空的，先播第一首「%@」", first.title)
                engine.play(page.songs, at: 0)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
        for name in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            // `search`：把光标放进搜索框 —— 验证「光标在文本里时空格不暂停」那条守卫。
            if name == "search" {
                let moved = await focusSearchField()
                NSLog("[keys] 焦点挪到搜索框：%@（isEditingText=%@）",
                      moved ? "成功" : "没找到", isEditingText ? "是" : "否")
                continue
            }
            guard let code = Self.keyCode(for: name) else {
                NSLog("[keys] 认不出「%@」", name)
                continue
            }
            let before = engine.smokeStatus()
            if let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: code
            ) {
                NSApp.postEvent(event, atStart: false)
            }
            // 拖进度要等播放器反应，给一秒半。
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSLog("[keys] %@：%@ → %@", name, before, engine.smokeStatus())
        }
    }

    /// 把光标放进搜索框：每 0.25 秒举一次「聚焦请求」，一直到 `isEditingText`
    /// 成立为止，最多 5 秒。
    ///
    /// 走 SwiftUI 的焦点状态（`DmSearchField` 的 `focusTicket`），不用 AppKit 硬塞
    /// ——`makeFirstResponder` 收得下，但第一响应者不是字段编辑器，守卫仍然验不到
    /// （2026-10-13 实测）。
    ///
    /// 举多次而不是一次：视图树逐帧长出来，进程刚起那会儿曲库页还没挂上，挂上之前
    /// 的请求没人接；`onChange` 只在值变了才响，所以得继续加。
    private func focusSearchField() async -> Bool {
        for _ in 0..<20 {
            requestSearchFocus()
            try? await Task.sleep(nanoseconds: 250_000_000)
            if isEditingText { return true }
        }
        return false
    }

    /// 主窗口。`keyWindow` 优先，但它可能因启动时序还没立起来 —— 那时退到
    /// `mainWindow` 与第一个可见的非面板窗口。
    private func hostingWindow() -> NSWindow? {
        if let window = NSApp.keyWindow { return window }
        if let window = NSApp.mainWindow { return window }
        return NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    }

    private static func keyCode(for name: String) -> UInt16? {
        switch name {
        case "space": return 49
        case "left": return 123
        case "right": return 124
        default: return nil
        }
    }

    // MARK: - 系统媒体键

    /// 「正在播放」与媒体键（F7 / F8 / F9、控制中心、AirPods）。理由见 `NowPlaying`。
    let nowPlaying = NowPlaying()

    // MARK: - 连接

    /// 启动时自动连一次（本机凭据文件里真有那条才动）。
    ///
    /// 读文件不弹任何系统框。读取不能留在 `@MainActor` 上：挂在主线程时
    /// 整个启动都排在它后面。重试交给 `startAutoConnect` —— 这里只负责
    /// 把凭据读出来。
    func restoreAndAutoConnect() async {
        startLinkMonitor()
        guard isConnected == false, phase.isBusy == false else { return }
        let endpoint = endpointKey
        let user = trimmedUsername
        let saved = await Task.detached(priority: .userInitiated) {
            CredentialStore.load(endpointID: endpoint, username: user)
        }.value
        NSLog("[connect] 自动连：端点 %@ · 凭据 %@", endpoint, saved != nil ? "在" : "无")
        guard let password = saved else { return }
        startAutoConnect(password: password)
    }

    /// 自动连的重试任务（含退避等待）。用户手动连接 / 断开时整套取消。
    private var autoConnectTask: Task<Void, Never>?
    /// 网络监视器：只在「断 → 通」跳变的那一拍补连，平时不轮询。
    private var linkMonitor: NWPathMonitor?
    /// `nil` = 还没收到过路径回调。首个回调只登记基线，不算跳变 ——
    /// 否则开机的「网络本来就通」会跟 `restoreAndAutoConnect` 抢着连。
    private var linkWasSatisfied: Bool?

    /// 失败退避重试：0s / 5s / 15s / 30s / 60s 共五把。开机常见的竞态
    /// （Wi-Fi 还在连、Clash 还没起）两分钟内基本都能缓过来。三道闸：
    /// 连上或有人正在连就收手；口令被拒立即收手（DSM 自动封锁按失败
    /// 次数计，反复送只会把账号锁死）；任务被取消立即收手。
    func startAutoConnect(password: String) {
        autoConnectTask?.cancel()
        autoConnectTask = Task { [weak self] in
            guard let self else { return }
            for (n, wait) in zip([1, 2, 3, 4, 5], [0.0, 5.0, 15.0, 30.0, 60.0]) {
                if Task.isCancelled {
                    NSLog("[connect] 自动连第 %d 把前被取消", n)
                    return
                }
                if self.isConnected || self.phase.isBusy { return }
                if let err = self.lastConnectError, Self.isAuthRejection(err) {
                    NSLog("[connect] 上一次是口令被拒（%@），不重试", self.phase.label)
                    return
                }
                NSLog("[connect] 自动连接第 %d 把", n)
                if wait > 0 {
                    NSLog("[connect] 未连上（%@），%d 秒后再试",
                          self.phase.label, Int(wait))
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    if Task.isCancelled { return }
                    if self.isConnected || self.phase.isBusy { return }
                }
                await self.connect(password: password, method: self.resumeMethod)
                if self.isConnected { return }
            }
            NSLog("[connect] 自动连接五把都没成（%@），等网络恢复或手动连", self.phase.label)
        }
    }

    /// 取消自动连。用户在连接表单里自己动手（连 / 断）时调 —— 那之后
    /// 重试跟用户抢方向盘没有意义。
    func cancelAutoConnect() {
        autoConnectTask?.cancel()
        autoConnectTask = nil
        rebootReconnectTask?.cancel()
        rebootReconnectTask = nil
    }

    /// 口令被拒一族：登录 400 / 停用 / 无权限 / 两步验证 / 自动封锁 / 口令过期。
    /// 这些换多少次时机都是同一个答案，重试只会触发封锁。
    static func isAuthRejection(_ error: any Error) -> Bool {
        guard let err = error as? SynologyError, err.api == "SYNO.API.Auth" else { return false }
        return [400, 401, 402, 403, 404, 406, 407, 408, 409].contains(err.code)
    }

    /// 网络恢复自动补连：路径从断到通的那一拍，若还停在 failed / idle，
    /// 就再起一轮自动连（睡眠唤醒、Wi-Fi 重连都落在这条路上）。
    private func startLinkMonitor() {
        guard linkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                guard let was = self.linkWasSatisfied else {
                    self.linkWasSatisfied = satisfied
                    return
                }
                self.linkWasSatisfied = satisfied
                guard satisfied, !was else { return }
                guard !self.isConnected, !self.phase.isBusy else { return }
                if let err = self.lastConnectError, Self.isAuthRejection(err) { return }
                let endpoint = self.endpointKey
                let user = self.trimmedUsername
                let saved = await Task.detached(priority: .utility) {
                    CredentialStore.load(endpointID: endpoint, username: user)
                }.value
                guard let password = saved, !self.isConnected, !self.phase.isBusy else { return }
                NSLog("[connect] 网络恢复，自动补连")
                self.startAutoConnect(password: password)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.dreamanual.nas.linkmonitor"))
        linkMonitor = monitor
    }

    // MARK: - 冒烟验证

    /// `DM_SMOKE=1` 时由入口调用：连上后自动播第一页的第一首，并连打 20 秒
    /// 引擎状态 —— 真机播放验证不必依赖界面点击（AI 环境没有辅助功能权限，
    /// 点不到按钮）。日志走 stderr，从终端直接起进程就能收。
    func smokePlayFirst() async {
        guard isConnected, let manager = sessionManager, let engine = playback else {
            NSLog("[smoke] 未连接，跳过（phase=%@)", String(describing: phase))
            return
        }
        do {
            let page = try await AudioLibrary.songs(manager, limit: 20)
            guard let first = page.songs.first else {
                NSLog("[smoke] 曲库空")
                return
            }
            NSLog("[smoke] 曲库 %@ 首，开播「%@」path=%@", String(page.songs.count), first.title, first.path)
            engine.play(page.songs, at: 0)
            var sought = false
            var switched = false
            for second in 1...25 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // t+8s 拖进度到 60s；t+14s 切下一首；t+18s 切到队列页
                // —— 一轮覆盖三条主路径（队列页没有别的入口，只能这样进）。
                if second == 8, engine.duration > 0 {
                    engine.seek(to: 60)
                    sought = true
                }
                if second == 14 {
                    engine.next()
                    switched = true
                }
                if second == 18 {
                    toggleQueue()
                    NSLog("[smoke] 已切到队列页 showsQueue=%@", showsQueue ? "1" : "0")
                }
                let tag = sought && second <= 13 ? "（已拖）" : switched && second > 14 ? "（已切）" : ""
                NSLog("[smoke] t+%d%@ %@", second, tag, engine.smokeStatus())
                if !engine.isPlaying { break }
            }
            await smokeLibrarySources(manager)
            await smokeRating(manager, song: first)
        } catch {
            NSLog("[smoke] 失败：%@", error.localizedDescription)
        }
    }

    /// 评分自检：写 → 回读 → 再写另一个值 → 回读 → **复原成起始值**。
    ///
    /// `Song.setrating` 对不存在的 id 也回 `success: true`，成功标志不可信 ——
    /// 这条链路只有真机回读能证明。走的是界面同一条路（`rate`），顺带把
    /// Toast 与队列同步也跑过。**用完复原**：别在曲库里留下冒烟改过的分。
    private func smokeRating(_ manager: SessionManager, song: AudioSong) async {
        do {
            let before = try await AudioLibrary.rating(manager, songID: song.id)
            NSLog("[smoke] 评分 起始 %@ 星（%@）", String(before), song.title)

            for probe in [5, 3] {
                let applied = await rate(song.id, to: probe)
                NSLog("[smoke] 评分 写 %@ → 落地 %@ %@",
                      String(probe), applied.map(String.init) ?? "nil",
                      applied == probe ? "✓" : "✗")
            }

            let restored = await rate(song.id, to: before)
            NSLog("[smoke] 评分 复原 %@ → 落地 %@ %@",
                  String(before), restored.map(String.init) ?? "nil",
                  restored == before ? "✓" : "✗")
        } catch {
            NSLog("[smoke] 评分自检失败：%@", error.localizedDescription)
        }
    }

    /// `DM_IMMERSIVE=<关键词>` 时由入口调用：按关键词搜一首、开播、进沉浸模式，
    /// 再把歌词结果打出来。
    ///
    /// 沉浸屏的底（模糊封面）、280 封面与歌词两态都只能真机看 —— AI 环境点不了 UI，
    /// 只能让程序自己走到那一屏，再从终端起进程收日志、抓窗口截图。
    /// 关键词传 `-`（或空）就播曲库第一首。
    func smokeImmersive(keyword: String) async {
        guard isConnected, let manager = sessionManager, let engine = playback else {
            NSLog("[immersive] 未连接，跳过（phase=%@）", String(describing: phase))
            return
        }
        do {
            let page: AudioSongPage
            if keyword.isEmpty || keyword == "-" {
                page = try await AudioLibrary.songs(manager, limit: 20)
            } else {
                page = try await AudioLibrary.search(manager, keyword: keyword, limit: 50)
            }
            guard let first = page.songs.first else {
                NSLog("[immersive] 搜「%@」没有命中", keyword)
                return
            }
            NSLog("[immersive] 开播「%@」—「%@」id=%@", first.title, first.artist, first.id)
            engine.play(page.songs, at: 0)
            showsImmersive = true

            // 取词与取图都是异步的，等它们落地再报。
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            let lyrics = await LyricsStore.shared.lyrics(manager: manager, song: first)
            if let lyrics {
                NSLog("[immersive] 歌词 → %@ 行 · 时间轴 %@ · 来源 %@",
                      String(lyrics.lines.count),
                      lyrics.hasTimeline ? "有" : "无",
                      String(describing: lyrics.origin))
            } else {
                NSLog("[immersive] 歌词 → 未匹配到（应走「接下来播放」那一态）")
            }
            NSLog("[immersive] 下一首 = %@", engine.nextSong?.title ?? "（队尾）")
            NSLog("[immersive] 当前状态 %@", engine.smokeStatus())
        } catch {
            NSLog("[immersive] 失败：%@", error.localizedDescription)
        }
    }

    /// `DM_LIBRARY=<指令>` 时由入口调用：把曲库页摆到指定状态，供真机截图核对。
    ///
    /// 表头点不出排序箭头、字段菜单的勾选框也点不开 —— AI 环境没有辅助功能权限，
    /// 点击会被静默丢弃（理由同 `DM_IMMERSIVE`）。指令逗号分隔：
    /// `sort=<字段>:asc|desc` 设排序、`hide=<字段>` 藏一列、`menu` 展开字段菜单、
    /// `reset` 回默认（不排、八列全开）。**核对完记得 `reset`**，别把冒烟留下的
    /// 偏好存进用户的 `UserDefaults`。
    func smokeLibrary(_ command: String) async {
        guard isConnected, let manager = sessionManager else {
            NSLog("[library] 未连接，跳过（phase=%@）", String(describing: phase))
            return
        }
        await library.loadIfNeeded(manager)

        for raw in command.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if token == "menu" {
                library.showsFieldMenu = true
            } else if token == "reset" {
                library.resetColumns()
                await library.applySort(nil, on: manager)
            } else if token.hasPrefix("sort=") {
                let spec = token.dropFirst("sort=".count).split(separator: ":")
                guard let field = TrackField(rawValue: String(spec[0])) else {
                    NSLog("[library] 认不出字段「%@」", String(spec[0]))
                    continue
                }
                let ascending = spec.count < 2 || spec[1] != "desc"
                await library.applySort(SongSort(field: field, ascending: ascending), on: manager)
            } else if token.hasPrefix("hide=") {
                let name = String(token.dropFirst("hide=".count))
                guard let field = TrackField(rawValue: name) else {
                    NSLog("[library] 认不出字段「%@」", name)
                    continue
                }
                library.setVisible(field, false)
            } else if token.hasPrefix("dim=") {
                // 切维度走 `select`（模型层，与点分段控件同一条路）。三个实体维度
                // 是逐页拉的（每页 1000），这里把真实耗时报出来 —— 「切个维度等多久」
                // 是这一步要点验的数。
                let name = String(token.dropFirst("dim=".count))
                guard let dim = LibraryModel.Dimension(rawValue: name) else {
                    NSLog("[library] 认不出维度「%@」", name)
                    continue
                }
                let t0 = Date()
                await library.select(dim, on: manager)
                NSLog("[library] 切到「%@」用了 %.1f 秒", dim.title, Date().timeIntervalSince(t0))
            } else if token.hasPrefix("pick=") {
                // 点一行实体代入筛选（与点 EntityRow 同一条路）。
                let name = String(token.dropFirst("pick=".count))
                let t0 = Date()
                await library.apply(name, on: manager)
                NSLog("[library] 点「%@」代入筛选用了 %.1f 秒 → 页头「%@ · %@」",
                      name, Date().timeIntervalSince(t0),
                      library.headTitle, library.headSubtitle)
            } else if token.hasPrefix("click=") {
                NSLog("[library] 收到 click 指令「%@」", token)
                let name = String(token.dropFirst("click=".count))
                guard let field = TrackField(rawValue: name) else {
                    NSLog("[library] 认不出字段「%@」", name)
                    continue
                }
                await waitForHeaderFrames()
                let sent = await clickHeader(field)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                NSLog("[library] 合成点击表头「%@」：%@ → 排序 %@",
                      field.label, sent ? "已发出" : "没有位置",
                      library.sort.map { "\($0.field.rawValue) \($0.direction)" } ?? "默认")
            } else if token.hasPrefix("drag=") {
                let spec = token.dropFirst("drag=".count).split(separator: ":")
                guard spec.count == 2,
                      let from = TrackField(rawValue: String(spec[0])),
                      let to = TrackField(rawValue: String(spec[1])) else {
                    NSLog("[library] 认不出拖动指令「%@」", token)
                    continue
                }
                await waitForHeaderFrames()
                let sent = await dragHeader(from, to)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                NSLog("[library] 合成拖动「%@ → %@」：%@ → 列序 %@",
                      from.label, to.label, sent ? "已发出" : "没有位置",
                      library.visibleColumns.map(\.rawValue).joined(separator: "、"))
            } else if token.hasPrefix("draghold=") {
                let spec = token.dropFirst("draghold=".count).split(separator: ":")
                guard spec.count == 2,
                      let from = TrackField(rawValue: String(spec[0])),
                      let to = TrackField(rawValue: String(spec[1])) else {
                    NSLog("[library] 认不出拖动指令「%@」", token)
                    continue
                }
                await waitForHeaderFrames()
                let sent = await dragHeader(from, to, release: false)
                NSLog("[library] 拖住不放「%@ → %@」：%@ —— 界面停在正在拖那一帧，"
                      + "等着被截图（这一趟的进程随后就杀掉，不会真把列序写进用户偏好）",
                      from.label, to.label, sent ? "已按住" : "没有位置")
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            } else {
                NSLog("[library] 认不出指令「%@」", token)
            }
        }

        // 取数、取图都是异步的，等它们落地再报。
        try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
        NSLog("[library] 指令「%@」→ 排序 %@ · 列 %@ · 菜单 %@ · 共 %@ 首 · 总数 %@",
              command,
              library.sort.map { "\($0.field.rawValue) \($0.direction)" } ?? "默认",
              TrackField.allCases.filter { library.isVisible($0) }.map(\.rawValue).joined(separator: "、"),
              library.showsFieldMenu ? "开" : "关",
              String(library.songs.count),
              String(library.total))
        let head = library.songs.prefix(8).map { "\($0.title)[\($0.year.map(String.init) ?? "-")]" }
        NSLog("[library] 前八条 %@", head.joined(separator: " / "))
        // 实体维度那一屏报实体数与前几条（与 3800 / 5756 / 97 对数用）。
        NSLog("[library] 维度「%@」→ 艺术家 %@ / 专辑 %@ / 流派 %@",
              library.dimension.rawValue,
              String(library.artists.count),
              String(library.albums.count),
              String(library.genres.count))
        switch library.dimension {
        case .artist:
            NSLog("[library] 艺术家前八 %@",
                  library.artists.prefix(8).map(\.name).joined(separator: " / "))
        case .album:
            NSLog("[library] 专辑前八 %@",
                  library.albums.prefix(8).map { "\($0.name) — \($0.artist)" }
                      .joined(separator: " / "))
        case .genre:
            NSLog("[library] 流派前八 %@",
                  library.genres.prefix(8).joined(separator: " / "))
        case .all:
            break
        }
    }

    /// `DM_FILES=<指令>` 时由入口调用：把文件管理页摆到指定状态，供真机截图核对。
    ///
    /// 与曲库那条同一理由 —— AI 点不了 UI（没有辅助功能权限，点击被静默丢弃）。
    /// 指令逗号分隔：
    ///   · `open=<路径>` 打开目录、`expand=<路径>` 在树上展开一层；
    ///   · `sort=<字段>:asc|desc` 直设排序（**走模型层**，绕开点击）；
    ///   · `click=<字段>` 合成一次**真鼠标点击**表头（走的是「点表头 → 排序」这条
    ///     界面接线本身，与曲库的 `click=` 同一套做法）；
    ///   · `reveal=<关键词>` 走「在文件管理中显示」那条接线：搜一首、切模块、定位目录；
    ///   · `select=<名字>` 勾上一条（按名字，前缀匹配）、`selectall` 全选；
    ///   · `dialog=newfolder|rename|delete` 把某一张写操作弹窗摆出来（截图核对形态）；
    ///   · `menu` 摆出文件右键菜单；
    ///   · `writecheck` 在**自建沙箱**里跑一遍建夹 → 改名 → 删除，最后拆掉沙箱；
    ///   · `upload=<本机路径>` 把一个本机文件 / 文件夹传到当前目录（走界面上同一条路），
    ///     每秒打一次进度，撞名会停下等用户；
    ///   · `conflict[=<名字>]` 造一个与当前目录某项同名的临时文件丢进队列，把撞名弹窗摆出来；
    ///   · `drop` 摆出拖入高亮（真拖拽 AI 发不出来，只能这么看形态）；
    ///   · `cancelcheck` 传一个 3 MB 测试件、1.5 秒后取消，核对队列状态与现场清理；
    ///   · `copy` / `move` 把选目标弹窗摆出来（工具条那两个入口，真机上点不了）；
    ///   · `pick=<字>` 往弹窗搜索框里填字（空值清掉），看筛选态；
    ///   · `pickexpand=<路径>` 在弹窗的树里展开 / 收起一层（逐级懒加载）；
    ///   · `pickselect=<名字或路径>` 选目标，报出确认按钮的禁用原因（空 = 可以确认）；
    ///   · `pickconfirm` 走弹窗上的确认（撞名会弹第二张，不撞直接跑）；
    ///   · `cmcheck` 在**自建沙箱**里跑一遍复制 + 移动，回读核对后拆掉沙箱；
    ///   · `cmdialog` 搭一个注定撞名的沙箱、把撞名弹窗摆出来停住（沙箱留给 `cmclean` 收）；
    ///   · `cmclean` 把 `cmdialog` 留下的沙箱收干净；
    ///   · `search=<字>` 提交一次搜索（**真的等它跑完**，含假空重试），把结局与用掉几次
    ///     `start` 报出来；
    ///   · `searchbg=<字>` 同上但**不等结果** —— 用来截「正在搜索 / 正在重试」那一屏；
    ///   · `searchmore` 拉搜索结果下一页（任务还活着，走偏移取）；
    ///   · `searchhit=<序号>` 点第 N 条结果（1 起数），走「跳回浏览态」那条接线；
    ///   · `searchclear` 退出搜索（与 Esc / 清除钮同一条路）；
    ///   · `dirsize[=<文件夹名>]` 选一条目录并算它的体积（右键菜单那一项），
    ///     不给名字取列表里第一条目录；
    ///   · `reset` 排序回默认。**核对完 reset** —— 排序偏好会写进用户机的 `UserDefaults`。
    func smokeFiles(_ command: String) async {
        guard isConnected, let manager = sessionManager else {
            NSLog("[files] 未连接，跳过（phase=%@）", String(describing: phase))
            return
        }
        // 文件管理不是默认模块（默认落在听歌页）—— 先切过去，否则这一页根本没上屏，
        // 表头位置自然报不上来（2026-10-14 踩过：日志里「等表头位置 20 次都没有」）。
        select(.files)
        await files.loadIfNeeded(manager, username: username)

        for raw in command.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if token == "reset" {
                await files.applySort(FileStation.defaultSort, on: manager)
            } else if token.hasPrefix("open=") {
                await files.open(String(token.dropFirst("open=".count)), on: manager)
            } else if token.hasPrefix("expand=") {
                await files.toggleExpand(String(token.dropFirst("expand=".count)), on: manager)
            } else if token.hasPrefix("sort=") {
                let spec = token.dropFirst("sort=".count).split(separator: ":")
                guard let field = FileSortField(rawValue: String(spec[0])) else {
                    NSLog("[files] 认不出字段「%@」", String(spec[0]))
                    continue
                }
                await files.applySort(
                    FileSort(field: field, ascending: spec.count < 2 || spec[1] != "desc"),
                    on: manager
                )
            } else if token.hasPrefix("click=") {
                let name = String(token.dropFirst("click=".count))
                guard let field = FileSortField(rawValue: name) else {
                    NSLog("[files] 认不出字段「%@」", name)
                    continue
                }
                await waitForFilesHeaderFrames()
                let sent = await clickFilesHeader(field)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                NSLog("[files] 合成点击表头「%@」：%@ → 排序 %@",
                      field.label, sent ? "已发出" : "没有位置",
                      files.sort.map { "\($0.field.rawValue) \($0.direction)" } ?? "默认")
            } else if token.hasPrefix("reveal=") {
                await smokeReveal(String(token.dropFirst("reveal=".count)), manager: manager)
            } else if token.hasPrefix("select=") {
                smokeSelect(String(token.dropFirst("select=".count)))
            } else if token == "selectall" {
                files.selectAll()
                NSLog("[files] 全选 → %@ 项", String(files.selection.count))
            } else if token.hasPrefix("dialog=") {
                smokeFileDialog(String(token.dropFirst("dialog=".count)))
            } else if token == "menu" {
                smokeFileMenu()
            } else if token == "writecheck" {
                await smokeWriteCheck(manager)
            } else if token.hasPrefix("upload=") {
                await smokeUpload(String(token.dropFirst("upload=".count)))
            } else if token == "conflict" || token.hasPrefix("conflict=") {
                let name = token.hasPrefix("conflict=")
                    ? String(token.dropFirst("conflict=".count)) : nil
                await smokeConflict(name)
            } else if token == "drop" {
                uploads.dropTargeted = true
                NSLog("[files] 摆出拖入高亮（传到 %@）", files.currentPath)
            } else if token == "cancelcheck" {
                await smokeCancelCheck(manager)
            } else if token == "copy" || token == "move" {
                smokeOpenTransfer(token == "move" ? .move : .copy)
            } else if token.hasPrefix("pick=") {
                await smokePick(String(token.dropFirst("pick=".count)))
            } else if token.hasPrefix("pickexpand=") {
                let path = String(token.dropFirst("pickexpand=".count))
                await transfers.picker.toggleExpand(path, on: manager)
                NSLog("[files] 选目标树「%@」→ %@ · 共 %@ 行",
                      path, transfers.picker.isExpanded(path) ? "已展开" : "已收起",
                      String(transfers.picker.rows.count))
            } else if token.hasPrefix("pickselect=") {
                await smokePickSelect(String(token.dropFirst("pickselect=".count)))
            } else if token == "pickconfirm" {
                await waitPickerReady()
                NSLog("[files] 选目标确认：%@ → %@（原因 %@）",
                      transfers.mode?.title ?? "?",
                      transfers.picker.target, transfers.blockingReason ?? "无")
                await confirmTransfer()
                NSLog("[files] 选目标确认落地 → 撞名弹窗 %@ · 弹窗还开着 %@",
                      transfers.conflict == nil ? "没出" : "出了（\(transfers.conflict?.clashes.count ?? 0) 项）",
                      transfers.isOpen ? "是" : "否")
            } else if token == "cmcheck" {
                await smokeCopyMoveCheck(manager)
            } else if token == "cmdialog" {
                await smokeCopyMoveDialog(manager)
            } else if token == "cmclean" {
                await smokeCopyMoveClean(manager)
            } else if token.hasPrefix("searchbg=") {
                // 不等它跑完：用来截「正在搜索 / 正在重试」那一屏，收尾用 searchclear。
                search.query = String(token.dropFirst("searchbg=".count))
                Task { await submitFileSearch() }
                NSLog("[files] 搜索「%@」已发出（不等结果，当场是「%@」）",
                      search.query, search.progressNote)
            } else if token.hasPrefix("search=") {
                await smokeSearch(String(token.dropFirst("search=".count)))
            } else if token == "searchmore" {
                await search.loadMore(on: manager)
                NSLog("[files] 搜索翻页 → 手上 %@ 条 · total %@ · 还有更多 %@",
                      String(search.hits.count), String(search.total),
                      search.hasMore ? "是" : "否")
            } else if token.hasPrefix("searchhit=") {
                await smokeSearchHit(String(token.dropFirst("searchhit=".count)))
            } else if token == "searchclear" {
                await cancelFileSearch()
                NSLog("[files] 退出搜索 → 搜索态 %@ · 当前 %@",
                      search.isActive ? "还在" : "已退", files.currentPath)
            } else if token == "dirsize" || token.hasPrefix("dirsize=") {
                await smokeDirSize(token.hasPrefix("dirsize=")
                    ? String(token.dropFirst("dirsize=".count)) : nil)
            } else {
                NSLog("[files] 认不出指令「%@」", token)
            }
        }

        // 取数、取图都是异步的，等它们落地再报。
        try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
        NSLog("[files] 指令「%@」→ 当前 %@ · 排序 %@ · 共 %@ 项 · 选中 %@ 项",
              command, files.currentPath,
              files.sort.map { "\($0.field.rawValue) \($0.direction)" } ?? "默认",
              String(files.total),
              String(files.selection.count))
        NSLog("[files] 前八条 %@", files.entries.prefix(8)
            .map { "\($0.name)\($0.isDirectory ? "/" : "")" }.joined(separator: " / "))
        NSLog("[files] 树前十行 %@", files.treeRows.prefix(10).map(\.name).joined(separator: " / "))
        if search.isActive {
            NSLog("[files] 搜索态「%@」→ %@ · 用掉 %@ 次 start", search.query,
                  search.resultNote, String(search.attempt))
        }
    }

    /// `DM_STATUS=<指令>` 时由入口调用：把系统状态页摆到指定状态，供真机截图核对。
    ///
    /// 与曲库 / 文件两条同一理由 —— AI 点不了 UI（没有辅助功能权限，点击被静默丢弃）。
    /// 指令逗号分隔：
    ///   · `open` 切到系统状态页，等第一次取数落地（缺省动作，光给别的记号也算）；
    ///   · `refresh` 再取一次，走页头刷新钮的同一个入口 `load(force:)`，报耗时；
    ///   · `dump` 把解析后的数打到日志 —— 屏幕上**看不出来**的那几件（`up_time`
    ///     怎么切的、负载除没除 100、卷名跟 `space.volume[]` 对上没有）就靠它对；
    ///   · `drop=<块>` 抹掉一块看「部分失败」（`device` / `load` / `storage` / `health`）
    ///     —— 真机上造不出干净的部分失败（要把某条接口单独打断）；
    ///   · `clear` 清掉快照，回到载入初态；
    ///   · `sched` 把开关机计划重读一遍并打点（走界面同一条 `load(force:)`）；
    ///   · `togglerow=<n>` 拨第 n 行的开关 —— 操作即写回，等写回落定再打点；
    ///   · `schedadd` 追加一条「周末 22:05 开机」并写回（离线时只动本地）；
    ///   · `scheddel=<n>` 删第 n 条并写回（离线时只动本地）；
    ///   · `schededitor` 开编辑弹窗（第 0 条，先灌 mock）—— 离线也能跑；
    ///   · `schedaddopen` 开新增弹窗（先灌 mock）—— 离线也能跑；
    ///   · `powerconfirm` 摆关机确认弹窗 —— 离线也能跑；
    ///   · `powerreboot` **真重启**：发指令、断开、等它回来自动重连（只该在
    ///     真机验证时用）；
    ///   · `failtoggle=<n>` 开「写回假失败」拨第 n 行：界面弹回去 + 页脚失败行，
    ///     专门验「失败 → 本地回滚」这条腿（不发请求）；
    ///   · `schedroundtrip` 整条写回链路：拨 → 等写回 → 回读核对 → 拨回 → 等 →
    ///     回读核对（收尾回原样，见 `smokeScheduleRoundtrip`）。
    ///
    /// 顺序即字面顺序：`clear` 之后再 `drop=` 是抹不掉的（手上没快照），要抹就先抹。
    func smokeStatus(_ command: String) async {
        // 离线可跑的记号（不碰会话）先于连接判据 —— NAS 关机时也能灌 mock 摆界面
        // 截图；`schedadd` / `scheddel=` 离线时只动本地（写回要 manager，没有就跳过）。
        // 🔴 判定收进**一个函数**：整条命令全离线 → 提前截流；与在线记号混用 →
        // 在线循环里也认它。两处共用一份清单，新记号不会再漏改一边
        // （`open,powerconfirm` 那次只改白名单、在线循环认不出，弹窗没摆出来）。
        func isOfflineToken(_ token: String) -> Bool {
            token == "schedmock" || token == "schededitor" || token == "schedaddopen"
                || token == "schedadd" || token == "powerconfirm"
                || token.hasPrefix("scheddel=")
        }
        func runOffline(_ token: String) {
            let manager = sessionManager
            if token == "schedmock" {
                powerSchedule.injectMock()
                dumpSchedule()
            } else if token == "schededitor" {
                powerSchedule.injectMock()
                openPowerEdit(0)
                NSLog("[sched] 开编辑弹窗（第 0 条，灌了 mock 数据）")
            } else if token == "schedaddopen" {
                powerSchedule.injectMock()
                openPowerAdd()
                NSLog("[sched] 开新增弹窗（灌了 mock 数据）")
            } else if token == "powerconfirm" {
                openPowerConfirm(.shutdown)
                NSLog("[power] 摆关机确认弹窗")
            } else if token == "schedadd" {
                Task {
                    _ = await powerSchedule.commit(PowerTask(
                        kind: .poweron, enabled: true, hour: 22, minute: 5,
                        weekdays: [0, 6]), replacing: nil, on: manager)
                    dumpSchedule()
                }
            } else if token.hasPrefix("scheddel=") {
                let index = Int(token.dropFirst("scheddel=".count)) ?? 0
                powerSchedule.remove(index, on: manager)
                dumpSchedule()
            }
        }
        let parts = command.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if !parts.isEmpty, parts.allSatisfy(isOfflineToken) {
            for token in parts { runOffline(token) }
            return
        }

        // 冒烟 token 在启动瞬间就被消费，自动连却是异步的 —— 先等连接落定
        // （最多 30 秒）再走后面的判据；凭据不对的失败也一样等满，冒烟场景可接受。
        for _ in 0..<60 {
            if phase == .connected { break }
            if case .failed = phase { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard isConnected, let manager = sessionManager else {
            NSLog("[status] 未连接，跳过（phase=%@）", String(describing: phase))
            return
        }
        // 系统状态不是默认模块（默认落在听歌页）—— 先切过去，否则这一页根本没上屏。
        select(.status)
        await status.load(on: manager)
        // 取数是并发的，落屏还要一帧；等一拍再截图 / 打点。
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        dumpStatus()

        for raw in command.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if token == "open" || token == "dump" {
                continue    // 上面已经切过来并打过一份
            } else if token == "refresh" {
                let started = Date()
                await status.load(on: manager, force: true)
                let cost = String(format: "%.2f", Date().timeIntervalSince(started))
                NSLog("[status] 刷新一次，耗时 %@ 秒 → %@",
                      cost, status.snapshot == nil ? "没读到" : "有快照")
                dumpStatus()
            } else if token.hasPrefix("drop=") {
                let block = String(token.dropFirst("drop=".count))
                status.smokeDrop(block)
                NSLog("[status] 抹掉「%@」→ 提示条：%@", block, status.failureNote ?? "（没有缺口）")
                try? await Task.sleep(nanoseconds: 800_000_000)
            } else if token == "clear" {
                status.clear()
                NSLog("[status] 清掉快照 → 回到载入初态")
                try? await Task.sleep(nanoseconds: 500_000_000)
            } else if token == "sched" {
                await powerSchedule.load(on: manager, force: true)
                dumpSchedule()
        } else if token.hasPrefix("togglerow=") {
            let index = Int(token.dropFirst("togglerow=".count)) ?? 0
            powerSchedule.toggle(index, on: manager)
            await powerSchedule.waitWritesSettled()
            dumpSchedule()
        } else if token.hasPrefix("failtoggle=") {
            let index = Int(token.dropFirst("failtoggle=".count)) ?? 0
            powerSchedule.smokeFailWrites = true
            powerSchedule.toggle(index, on: manager)
            await powerSchedule.waitWritesSettled()
            powerSchedule.smokeFailWrites = false
            dumpSchedule()
        } else if token == "schedadd" || token == "schedmock" || token == "schededitor"
                    || token.hasPrefix("scheddel=") {
            // 只动草稿的记号（mock / 编辑器 / 追加 / 删除）与离线路径同一实现；
            // 在线时 add / del 照样写回。
            runOffline(token)
            await powerSchedule.waitWritesSettled()
            dumpSchedule()
        } else if token == "schedroundtrip" {
            await smokeScheduleRoundtrip(manager)
        } else if token == "powerreboot" {
            // 真重启 —— NAS 两分钟后回来，等待重连自己接盘。只该在真机验证时用。
            NSLog("[power] 冒烟：确认框之外直接发重启指令")
            await confirmPower(.reboot)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            dumpStatus()
        } else if isOfflineToken(token) {
            runOffline(token)
        } else {
            NSLog("[status] 认不出指令「%@」", token)
            }
        }
    }

    /// 冒烟用：开关机计划的**整条写回链路**。
    ///
    /// 屏幕上点不了 UI（没有辅助功能权限，点击被静默丢弃），所以「开关真能改到
    /// NAS 上」这件事只能在视图之外证一遍。操作即写回：拨开关 → 等写回落定 →
    /// 打点核对 → 拨回 → 再等 → 再核对，**收尾回原样**。
    ///
    /// 🔴 判据是**写回后的那一份**（成功路径放的就是服务端回读），不是任何返回值：
    /// 这个接口对非法的 `weekdays` 是静默剥掉（照回 `success`）。
    private func smokeScheduleRoundtrip(_ manager: SessionManager) async {
        guard !powerSchedule.tasks.isEmpty else {
            NSLog("[sched] 手上没有那一份计划（先 sched 读一次），跳过往返")
            return
        }
        let before = powerSchedule.tasks
        let index = before.count - 1
        var expected = before
        expected[index].enabled.toggle()
        NSLog("[sched] 往返起点 #%d %@ %@ 开关%@ → 目标 %@",
              index, before[index].kind.label, before[index].timeText,
              before[index].enabled ? "开" : "关",
              expected[index].enabled ? "开" : "关")

        powerSchedule.toggle(index, on: manager)
        await powerSchedule.waitWritesSettled()
        let first = powerSchedule.tasks
        NSLog("[sched] 往返 1/2 写回后 %@ · 与目标一致 %@",
              first.map { "\($0.timeText)/\($0.enabled ? "开" : "关")" }.joined(separator: " "),
              first == expected ? "是" : "否 ✗")

        powerSchedule.toggle(index, on: manager)
        await powerSchedule.waitWritesSettled()
        let second = powerSchedule.tasks
        NSLog("[sched] 往返 2/2 写回后 %@ · 与原样逐字一致 %@",
              second.map { "\($0.timeText)/\($0.enabled ? "开" : "关")" }.joined(separator: " "),
              second == before ? "是" : "否 ✗")
        dumpSchedule()
    }

    /// 冒烟用：把计划表的两份状态各打一行（走界面同一条 `dumpLines`）。
    private func dumpSchedule() {
        for line in powerSchedule.dumpLines {
            NSLog("[sched] %@", line)
        }
    }

    /// 冒烟用：把系统状态页上屏那几件数打到日志，供与接口原始读数逐项对照。
    ///
    /// 四张卡一律走界面同一条路（`SystemStatusAPI.stats`）—— 打的是「屏幕上是什么」，
    /// 不是「我以为是什么」；其余分块打全，因为界面上有些数根本没露（平均负载 5/15 分钟、
    /// 卷的忙闲、`deviceBytes` 与 `totalBytes` 谁是谁）。
    private func dumpStatus() {
        guard let snapshot = status.snapshot else {
            NSLog("[status] 还没有快照（phase=%@）", String(describing: status.phase))
            return
        }
        NSLog("[status] 链路 %@ · 快照到手 %@ 块 · 缺的：%@",
              linkMode?.label ?? "—",
              String(4 - snapshot.failures.count),
              snapshot.failures.isEmpty ? "无" : snapshot.failures.joined(separator: " / "))

        if let device = snapshot.device {
            NSLog("[status] 机器 %@ · 固件 %@ · 序列号 %@",
                  device.model, device.firmware, device.serial)
            NSLog("[status] CPU %@ %@ · %@ 核 · %@ MHz ｜ 内存 %@ ｜ 已开机 %@ 秒 = %@",
                  device.cpuFamily, device.cpuSeries, String(device.cpuCores),
                  String(device.cpuClockMHz), FileEntry.byteText(device.ramBytes),
                  String(device.uptimeSeconds), device.uptimePhrase)
            NSLog("[status] 开机时刻（本机时钟倒推）%@ ｜ 服务端温度 %@ °C · 告警 %@",
                  SystemStatusAPI.bootStamp.string(from: device.bootedAt),
                  String(device.temperature), device.temperatureWarn ? "是" : "否")
        } else {
            NSLog("[status] 机器信息：缺")
        }

        if let load = snapshot.load {
            NSLog("[status] CPU 用户 %@%% + 系统 %@%% = %@%%（DSM 利用率口径）· I/O 等待 %@%%",
                  String(load.cpuUser), String(load.cpuSystem),
                  String(load.cpuUsage), String(load.cpuIO))
            NSLog("[status] 平均负载 1/5/15 分钟 %@ / %@ / %@（服务端原值已除 100）",
                  String(format: "%.2f", load.load1), String(format: "%.2f", load.load5),
                  String(format: "%.2f", load.load15))
            NSLog("[status] 内存 %@%% ｜ 总 %@ · 可用 %@ · 缓存 %@",
                  String(load.memoryPercent), FileEntry.byteText(load.memoryTotalBytes),
                  FileEntry.byteText(load.memoryAvailableBytes),
                  FileEntry.byteText(load.memoryCachedBytes))
            for row in load.volumes {
                NSLog("[status]   卷读数「%@」→ 读 %@ · 写 %@ · 忙 %@%%",
                      row.id, SystemStatusAPI.rateText(row.readBytesPerSec),
                      SystemStatusAPI.rateText(row.writeBytesPerSec), String(row.utilization))
            }
            for row in load.disks {
                NSLog("[status]   盘读数「%@」→ 读 %@ · 写 %@ · 忙 %@%%",
                      row.id, SystemStatusAPI.rateText(row.readBytesPerSec),
                      SystemStatusAPI.rateText(row.writeBytesPerSec), String(row.utilization))
            }
        } else {
            NSLog("[status] 负载：缺")
        }

        if let storage = snapshot.storage {
            for volume in storage.volumes {
                NSLog("[status] 卷 %@（服务端 id %@ · num_id %@ · %@ · %@）%@ ｜ 已用 %@ / %@（%@%%）"
                      + " ｜ 可用 %@ ｜ total_device %@",
                      volume.name, volume.id, String(volume.numID), volume.fsType, volume.raidType,
                      volume.isHealthy ? "正常" : volume.status,
                      FileEntry.byteText(volume.usedBytes), FileEntry.byteText(volume.totalBytes),
                      String(format: "%.1f", volume.usedPercent * 100),
                      FileEntry.byteText(volume.freeBytes),
                      FileEntry.byteText(volume.deviceBytes))
                // 这一行的判据就是「卷名两边不一样」那件事 —— 按 `id` 对必挂。
                let matched = snapshot.load?.volume(volume.loadID)
                NSLog("[status]   卷读写匹配：loadID「%@」%@ ｜ id「%@」%@ ｜ 配上那份 读 %@ · 写 %@",
                      volume.loadID, matched == nil ? "没配上" : "配上",
                      volume.id, snapshot.load?.volume(volume.id) == nil ? "没配上" : "配上",
                      SystemStatusAPI.rateText(matched?.readBytesPerSec ?? -1),
                      SystemStatusAPI.rateText(matched?.writeBytesPerSec ?? -1))
            }
            for disk in storage.disks {
                NSLog("[status] 盘 %@（%@ · %@）· %@ · %@ °C · %@ · 寿命 %@",
                      disk.id, disk.name, disk.model,
                      disk.isHealthy ? "正常" : disk.status,
                      String(disk.temperature), FileEntry.byteText(disk.sizeBytes),
                      disk.remainLifeTrustable && disk.remainLifePercent >= 0
                          ? "\(disk.remainLifePercent)%" : "不适用（trustable=\(disk.remainLifeTrustable)）")
            }
        } else {
            NSLog("[status] 容量：缺")
        }

        if let health = snapshot.health {
            NSLog("[status] 健康 崩溃 %@ · 扩展网卡不兼容 %@ ｜ 提示条 %@",
                  health.crashed ? "是" : "否", health.nicIncompatible ? "是" : "否",
                  health.warnings.isEmpty ? "无" : health.warnings.joined(separator: " / "))
        } else {
            NSLog("[status] 健康：缺")
        }

        for stat in SystemStatusAPI.stats(snapshot) {
            NSLog("[status] 卡片「%@」= %@%@ ｜ %@%@",
                  stat.label, stat.value, stat.unit, stat.note,
                  stat.isWarning ? "（告警色）" : "")
        }
    }

    /// 冒烟用：提交一次搜索，等它跑到底，把三种结局（出数 / 真零 / 重试耗尽）都报出来。
    ///
    /// 这条**真的等**（假空最坏十几次、每次约 1 秒），因为「重试」正是这一步要核对的东西 ——
    /// 界面上那句「第 N 次 / 上限 12 次」在这里看得出来。
    private func smokeSearch(_ keyword: String) async {
        search.query = keyword
        let started = Date()
        await submitFileSearch()
        let cost = String(format: "%.1f", Date().timeIntervalSince(started))
        NSLog("[files] 搜索「%@」@ %@ → %@ · 用掉 %@ 次 start · 耗时 %@ 秒",
              keyword, search.folder, search.resultNote, String(search.attempt), cost)
        for (index, hit) in search.hits.prefix(6).enumerated() {
            NSLog("[files]   结果 %@. %@ %@",
                  String(index + 1), hit.isDirectory ? "目录" : "文件", hit.path)
        }
    }

    /// 冒烟用：点第 N 条结果（1 起数），走「跳回浏览态、落到它所在位置」那条接线。
    private func smokeSearchHit(_ text: String) async {
        guard let index = Int(text), index >= 1, search.hits.count >= index else {
            NSLog("[files] 结果里没有第「%@」条（手上 %@ 条）", text, String(search.hits.count))
            return
        }
        let hit = search.hits[index - 1]
        await openSearchHit(hit)
        NSLog("[files] 点结果 %@（%@ %@）→ 当前 %@ · 选中 %@ 项 · 搜索态 %@",
              text, hit.isDirectory ? "目录" : "文件", hit.path, files.currentPath,
              String(files.selection.count), search.isActive ? "还在" : "已退")
    }

    /// 冒烟用：挑一条目录算体积（右键菜单里那一项）。
    ///
    /// 不给名字就取列表里第一条目录。真机上 AI 点不了右键菜单，只能走模型层。
    /// 会说清楚「用的是哪条路」—— 与菜单项同一个入口 `measureFileSelection`。
    private func smokeDirSize(_ name: String?) async {
        let target: FileEntry?
        if let name {
            target = files.entries.first {
                ($0.name == name || $0.name.hasPrefix(name)) && $0.isDirectory
            }
        } else {
            target = files.entries.first(where: \.isDirectory)
        }
        guard let entry = target else {
            NSLog("[files] 当前目录里没有要算的文件夹（%@）", name ?? "没给名字")
            return
        }
        files.select(entry)
        NSLog("[files] 算「%@」体积（%@）…", entry.name, files.canMeasureSelection ? "可以算" : "入口是灰的")
        let started = Date()
        await measureFileSelection()
        let cost = String(format: "%.1f", Date().timeIntervalSince(started))
        if let size = files.sizes[entry.path] {
            NSLog("[files] 算「%@」体积：%@（%@）· 耗时 %@ 秒 · 表里那一格显示「%@」",
                  entry.name, size.text, size.detailText, cost, files.sizeText(for: entry))
        } else {
            NSLog("[files] 算「%@」体积没成（%@）· 耗时 %@ 秒",
                  entry.name, files.measureError ?? "没说原因", cost)
        }
        NSLog("[files] 选中合计 %@ 字节 · 没计的文件夹 %@ 个 · 还在算 %@",
              String(files.selectionBytes), String(files.unmeasuredDirectoryCount),
              files.isMeasuring ? "是" : "否")
    }

    /// 冒烟用：按名字勾上一条（前缀匹配，省得把长文件名整个打出来）。
    private func smokeSelect(_ name: String) {
        guard let entry = files.entries.first(where: { $0.name == name || $0.name.hasPrefix(name) }) else {
            NSLog("[files] 列表里找不到「%@」", name)
            return
        }
        files.select(entry, mode: .toggle)
        NSLog("[files] 勾上「%@」→ 选中 %@ 项", entry.name, String(files.selection.count))
    }

    /// 冒烟用：把某一张写操作弹窗摆出来（截图核对形态）。真机上点不了按钮，
    /// 弹窗的形态只能这么看。
    private func smokeFileDialog(_ which: String) {
        switch which {
        case "newfolder":
            openFileDialog(.newFolder(in: files.currentPath))
        case "rename":
            guard let entry = files.singleSelection ?? files.entries.first else { return }
            files.select(entry)
            openFileDialog(.rename(entry))
        case "delete":
            // 删除确认的样态是多选 —— 没选就全选，让清单列满。
            if files.selection.isEmpty { files.selectAll() }
            openFileDialog(.delete(files.selectedEntries))
        default:
            NSLog("[files] 认不出弹窗「%@」", which)
        }
        NSLog("[files] 摆出弹窗「%@」", which)
    }

    /// 冒烟用：摆出文件右键菜单。锚点给内容区中部 —— 菜单卡越界时会自己收回窗口内。
    private func smokeFileMenu() {
        if files.selection.isEmpty, let first = files.entries.first { files.select(first) }
        guard let entry = files.selectedEntries.first else {
            NSLog("[files] 列表是空的，菜单开不出来")
            return
        }
        openFileMenu(for: entry, at: CGPoint(x: 520, y: 300))
        NSLog("[files] 右键菜单已开：%@ 项", String(files.selection.count))
    }

    /// 「写操作一趟走完」的冒烟：在**当前目录下自建一个沙箱**，里面建夹 → 改名 → 删除，
    /// 最后把沙箱自己删掉。全程打日志，每步都回读列表核对（不看返回码）。
    ///
    /// 真机上写操作验不了「点按钮」（AI 点不了 UI），但能验完整的数据那一路 ——
    /// 走的是与界面同一套 `AppState` 动作。🔴 **沙箱用完必删**，别在用户的目录里留垃圾；
    /// 命名带时间戳，撞名时 `createFolder` 会自己拦下并报重名。
    private func smokeWriteCheck(_ manager: SessionManager) async {
        let root = files.currentPath
        guard !root.isEmpty else {
            NSLog("[files] 写自检：当前目录为空，跳过")
            return
        }
        let sandboxName = "DreamanualWriteSmoke_\(Int(Date().timeIntervalSince1970))"
        let sandbox = "\(root)/\(sandboxName)"
        NSLog("[files] 写自检：在 %@ 下建沙箱 %@", root, sandboxName)

        // 1. 建沙箱（先查重名再建，与界面同一条）
        await createFolder(named: sandboxName)
        await files.open(sandbox, on: manager)
        let boxMade = files.currentPath == sandbox
        NSLog("[files] 写自检 1 建沙箱 → %@（当前 %@）",
              boxMade ? "✓" : "✗ 没进去", files.currentPath)

        // 2. 里面建一个子目录
        await createFolder(named: "demo")
        let made = files.entries.first { $0.name == "demo" }
        NSLog("[files] 写自检 2 建 demo → %@", made == nil ? "✗ 列表里没有" : "✓ 已在列表里")

        // 3. 改名 demo → demo-renamed
        if let made {
            await rename(made, to: "demo-renamed")
            let ok = files.entries.contains { $0.name == "demo-renamed" }
            NSLog("[files] 写自检 3 改名 → %@", ok ? "✓ 已是 demo-renamed" : "✗ 没改到")
        }

        // 4. 删掉它（走「选中集合 → 删除」这条多选的路）
        if let target = files.entries.first(where: { $0.name == "demo-renamed" }) {
            files.select(target)
            NSLog("[files] 写自检 4 选中「%@」→ 选中 %@ 项", target.name, String(files.selection.count))
            await delete(files.selectedEntries)
            let gone = !files.entries.contains { $0.name == "demo-renamed" }
            NSLog("[files] 写自检 4 删除 → %@", gone ? "✓ 已不在列表里" : "✗ 还在")
        }

        // 5. 拆沙箱：回上一级、选中沙箱、删掉
        await files.open(root, on: manager)
        if let box = files.entries.first(where: { $0.name == sandboxName }) {
            files.select(box)
            await delete(files.selectedEntries)
            let gone = !files.entries.contains { $0.name == sandboxName }
            NSLog("[files] 写自检 5 拆沙箱 → %@", gone ? "✓ 已清干净" : "✗ 还在，手动去删")
        } else {
            NSLog("[files] 写自检 5 拆沙箱 → ✗ 列表里找不到沙箱（自己去看一眼）")
        }
    }

    // MARK: - 冒烟：选目标弹窗与复制 / 移动

    /// 冒烟用：把选目标弹窗摆出来。真机上点不了工具条那两个按钮，形态只能这么看。
    private func smokeOpenTransfer(_ mode: FileTransfer.Mode) {
        if files.selection.isEmpty, let first = files.entries.first { files.select(first) }
        guard !files.selection.isEmpty else {
            NSLog("[files] 列表是空的，选目标弹窗开不出来")
            return
        }
        beginTransfer(mode)
        NSLog("[files] 摆出选目标弹窗：%@ · 来源 %@ 项 · 默认目标 %@",
              mode.title, String(files.selection.count), files.currentPath)
    }

    /// 等选目标弹窗开完。`beginTransfer` 里把弹窗开到默认目标那一步是**异步**的，而它
    /// 开完会把 `query` 清零、把树拉齐 —— 不等它落地，后面填的搜索词会被抹掉、选的行
    /// 也找不到（真机首跑就踩了：日志说筛出 8 行，截图还是树）。
    private func waitPickerReady() async {
        let want = files.currentPath
        for _ in 0..<100 {
            if transfers.picker.target == want, !transfers.picker.isLoading { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// 冒烟用：往弹窗的搜索框里填字（输入即筛选）。空串清掉、回到树。
    private func smokePick(_ text: String) async {
        await waitPickerReady()
        transfers.picker.query = text
        // 筛选是纯本地计算，给一拍让视图落定再报。
        try? await Task.sleep(nanoseconds: 600_000_000)
        NSLog("[files] 选目标搜索「%@」→ %@ 行 · 目标 %@",
              text, String(transfers.picker.rows.count), transfers.picker.target)
    }

    /// 冒烟用：选一个目标。参数给名字（前缀匹配）或整条路径都认。
    /// 顺带把**确认按钮的禁用原因**报出来 —— 这是这一步真正要核对的（空 = 能确认）。
    private func smokePickSelect(_ text: String) async {
        await waitPickerReady()
        guard let row = transfers.picker.rows.first(where: {
            $0.path == text || $0.name == text || $0.path.hasSuffix("/" + text)
        }) else {
            NSLog("[files] 选目标：列表里找不到「%@」（现有 %@ 行）",
                  text, String(transfers.picker.rows.count))
            return
        }
        transfers.picker.select(row.path)
        NSLog("[files] 选目标「%@」(%@) → 确认%@ · 原因 %@",
              row.name, row.path,
              transfers.canConfirm ? "可以点" : "灰着",
              transfers.blockingReason ?? "无")
    }

    /// 「复制 / 移动一趟走完」的冒烟：在**当前目录下自建一个沙箱**，里面分「源」「目标」
    /// 两个夹，源里放两个文件：先整批复制过去（核对目标里有、源还在），再把源里剩下那个
    /// 移动过去（核对目标里有、源里没了）。最后拆掉整个沙箱。
    ///
    /// 走的是与界面同一套动作（`beginTransfer` → `picker.select` → `confirmTransfer`），
    /// 中间不发合成鼠标事件（点了也没用，见工程坑）。判成败一律**回读目录列表**，
    /// 不看返回码 —— 这条接口返回码说不了事（见 `FileStation.copyMove` 那五条）。
    private func smokeCopyMoveCheck(_ manager: SessionManager) async {
        let root = files.currentPath
        guard !root.isEmpty else {
            NSLog("[files] 复制自检：当前目录为空，跳过")
            return
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let boxName = "DreamanualCMUI_\(stamp)"
        let box = "\(root)/\(boxName)"
        let src = "\(box)/源"
        let dst = "\(box)/目标"
        NSLog("[files] 复制自检：在 %@ 下建沙箱 %@", root, boxName)

        // 0. 搭沙箱：源 / 目标两个夹，源里放两个本机测试件。
        try? await FileStation.createFolder(manager, path: root, name: boxName)
        try? await FileStation.createFolder(manager, path: box, name: "源")
        try? await FileStation.createFolder(manager, path: box, name: "目标")
        let local = FileManager.default.temporaryDirectory
        for name in ["a.txt", "b.txt"] {
            let url = local.appendingPathComponent("DreamanualCM_\(name)")
            try? "dreamanual copy smoke \(name)".data(using: .utf8)?.write(to: url)
            try? await FileStation.upload(manager, fileURL: url, name: name, to: src) { _, _ in }
        }
        async let srcPage0 = try? FileStation.list(
            manager, path: src, sort: FileStation.defaultSort, limit: FileStation.treeFetchLimit)
        let inSource = Set((await srcPage0?.entries ?? []).map(\.name))
        NSLog("[files] 复制自检 0 搭沙箱 → 源里有 %@",
              inSource.sorted().joined(separator: " / "))

        // 1. 复制：进源、全选、开弹窗、选目标、确认。
        await files.open(src, on: manager)
        files.selectAll()
        beginTransfer(.copy)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        transfers.picker.select(dst)
        let reason = transfers.blockingReason
        NSLog("[files] 复制自检 1 准备 → 选中 %@ 项 · 目标 %@ · 禁用原因 %@",
              String(files.selection.count), dst, reason ?? "无")
        await confirmTransfer()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let dstAfterCopy = await names(in: dst, on: manager)
        let srcAfterCopy = await names(in: src, on: manager)
        NSLog("[files] 复制自检 2 核对 → 目标里有 %@ · 源里还有 %@",
              dstAfterCopy.sorted().joined(separator: " / "),
              srcAfterCopy.sorted().joined(separator: " / "))

        // 2. 再移动同样的两项过去 —— 这一步**必然撞名**（目标里已经有这一份了），
        //    正好把「客户端先查撞名」与两条路都走一遍：先「跳过」，再「替换」。
        await files.open(src, on: manager)
        files.selectAll()
        beginTransfer(.move)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        transfers.picker.select(dst)
        NSLog("[files] 复制自检 3 移动 → 选中 %@ 项 · 目标 %@ · 禁用原因 %@",
              String(files.selection.count), dst, transfers.blockingReason ?? "无")
        await confirmTransfer()
        let clashes = transfers.conflict?.clashes.count
        NSLog("[files] 复制自检 3b 撞名 → %@",
              clashes == nil ? "没查到 ✗" : "查到 \(clashes!) 项 ✓")
        await resolveTransfer(.skip)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let srcAfterSkip = await names(in: src, on: manager)
        let dstAfterSkip = await names(in: dst, on: manager)
        NSLog("[files] 复制自检 4 跳过 → 源里 %@ · 目标里 %@",
              srcAfterSkip.sorted().joined(separator: " / "),
              dstAfterSkip.sorted().joined(separator: " / "))

        // 3. 同一批再走一次、这回选「替换」，源应该被搬空。
        await files.open(src, on: manager)
        files.selectAll()
        beginTransfer(.move)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        transfers.picker.select(dst)
        await confirmTransfer()
        await resolveTransfer(.replace)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let srcAfterMove = await names(in: src, on: manager)
        let dstAfterMove = await names(in: dst, on: manager)
        NSLog("[files] 复制自检 5 替换并移动 → 源里 %@ · 目标里 %@",
              srcAfterMove.isEmpty ? "空了 ✓" : "还有 " + srcAfterMove.sorted().joined(separator: " / "),
              dstAfterMove.sorted().joined(separator: " / "))

        // 4. 撞名那条：把目标里的东西再复制一次到目标自己（应当被界面拦下）。
        await files.open(dst, on: manager)
        if let first = files.entries.first {
            files.select(first)
            beginTransfer(.copy)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            transfers.picker.select(dst)
            NSLog("[files] 复制自检 6 目标=来源 → 确认%@ · 原因 %@",
                  transfers.canConfirm ? "可以点 ✗" : "灰着 ✓",
                  transfers.blockingReason ?? "无")
            cancelTransfer()
        }

        // 5. 拆沙箱。
        await files.open(root, on: manager)
        if let boxEntry = files.entries.first(where: { $0.name == boxName }) {
            files.select(boxEntry)
            await delete(files.selectedEntries)
            let gone = !files.entries.contains { $0.name == boxName }
            NSLog("[files] 复制自检 7 拆沙箱 → %@", gone ? "✓ 已清干净" : "✗ 还在，手动去删")
        } else {
            NSLog("[files] 复制自检 7 拆沙箱 → ✗ 列表里找不到沙箱")
        }
        for name in ["a.txt", "b.txt"] {
            try? FileManager.default.removeItem(at: local.appendingPathComponent("DreamanualCM_\(name)"))
        }
    }

    /// 拉一层的条目名（沙箱核对用）。
    private func names(in path: String, on manager: SessionManager) async -> [String] {
        let page = try? await FileStation.list(
            manager, path: path, sort: FileStation.defaultSort, limit: FileStation.treeFetchLimit)
        return (page?.entries ?? []).map(\.name)
    }

    /// 冒烟用：搭一个**注定撞名**的沙箱，把复制 / 移动的撞名弹窗摆出来停住（截图核对形态）。
    ///
    /// 真机上点不了按钮，撞名弹窗只有靠这条通路才看得到。⚠️ **沙箱留在盘上**（停在这里没法
    /// 自拆），核对完用 `cmclean` 收掉。
    private func smokeCopyMoveDialog(_ manager: SessionManager) async {
        let root = files.currentPath
        guard !root.isEmpty else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let boxName = "DreamanualCMUI_\(stamp)"
        let box = "\(root)/\(boxName)"
        let src = "\(box)/源"
        let dst = "\(box)/目标"
        try? await FileStation.createFolder(manager, path: root, name: boxName)
        try? await FileStation.createFolder(manager, path: box, name: "源")
        try? await FileStation.createFolder(manager, path: box, name: "目标")
        let local = FileManager.default.temporaryDirectory
        for name in ["潮汐.txt", "夜色.txt", "旧梦.txt"] {
            let url = local.appendingPathComponent("DreamanualCMDlg_\(name)")
            try? "dreamanual copy dialog \(name)".data(using: .utf8)?.write(to: url)
            try? await FileStation.upload(manager, fileURL: url, name: name, to: src) { _, _ in }
            try? await FileStation.upload(manager, fileURL: url, name: name, to: dst) { _, _ in }
            try? FileManager.default.removeItem(at: url)
        }
        await files.open(src, on: manager)
        files.selectAll()
        beginTransfer(.copy)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        transfers.picker.select(dst)
        await confirmTransfer()
        NSLog("[files] 撞名弹窗已摆出：%@ · 目标 %@ · 撞名 %@ 项 · 剩下 %@ 项不撞",
              transfers.mode?.title ?? "?",
              DestinationPicker.shortPath(dst),
              String(transfers.conflict?.clashes.count ?? 0),
              String(transfers.conflict?.clean.count ?? 0))
        NSLog("[files] 沙箱留在 %@ —— 核对完用 cmclean 收掉", boxName)
    }

    /// 冒烟用：把 `cmdialog` 留下的沙箱收干净（连同以前跑剩的）。
    private func smokeCopyMoveClean(_ manager: SessionManager) async {
        let root = files.currentPath
        guard !root.isEmpty else { return }
        guard let page = try? await FileStation.list(
            manager, path: root, sort: FileStation.defaultSort, limit: FileStation.treeFetchLimit
        ) else { return }
        let stale = page.entries.filter { $0.name.hasPrefix("DreamanualCMUI_") }
        guard !stale.isEmpty else {
            NSLog("[files] 没有要收的沙箱")
            return
        }
        let task = try? await FileStation.delete(manager, paths: stale.map(\.path))
        await files.refresh(manager, username: username)
        let left = files.entries.filter { $0.name.hasPrefix("DreamanualCMUI_") }
        NSLog("[files] 收沙箱 %@ 个 → %@", String(stale.count),
              (task?.failed ?? true) || !left.isEmpty ? "✗ 还剩 \(left.count) 个" : "✓ 干净")
    }

    /// 「上传一趟走完」的冒烟：把一个本机文件（或文件夹）传到当前目录，每秒打一次进度。
    ///
    /// 走的是与界面同一条动作（`upload(urls:)` → 队列 → `FileStation.upload`）——
    /// 真机上「点上传按钮选文件」这一步 AI 做不了（面板点不了），能验的是它之后那一整条。
    /// 撞名时队列会停下来问用户，这里照实报出来。
    private func smokeUpload(_ path: String) async {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("[files] 上传自检：本机没有 %@", path)
            return
        }
        // 先清掉上次跑剩的测试件 —— 上一趟若在核对前被打断就会留下，这一趟一进来
        // 就撞名停下来（第一次跑到这一步就是这么发现的：整层查重生效了）。
        if let manager = sessionManager,
           let layer = try? await FileStation.list(
               manager, path: files.currentPath, sort: FileStation.defaultSort,
               limit: FileStation.treeFetchLimit
           ).entries {
            let stale = layer.filter { $0.name.hasPrefix("DreamanualUploadSmoke") }
            if !stale.isEmpty {
                _ = try? await FileStation.delete(manager, paths: stale.map(\.path))
                NSLog("[files] 上传自检：先清掉上次剩的 %@ 个测试件", String(stale.count))
                await files.refresh(manager, username: username)
            }
        }
        NSLog("[files] 上传自检：把「%@」传到 %@", url.lastPathComponent, files.currentPath)
        upload(urls: [url])

        // 摊平与查撞名都要时间，队列还没动起来时别急着判结束 ——
        // 判据是「摊出来过 + 眼下没有项在等或在传」。
        var started = false
        for tick in 1...90 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if uploads.conflict != nil {
                NSLog("[files] 上传自检：撞名，停下来问用户（目标已有「%@」）",
                      uploads.conflict?.existing.name ?? "")
                return
            }
            if !uploads.items.isEmpty { started = true }
            let waiting = uploads.items.contains { $0.state == .waiting || $0.state == .uploading }
            if let item = uploads.headline {
                let total = item.expected > 0 ? item.expected : item.byteCount
                let percent = total > 0
                    ? String(format: "%.1f%%", Double(item.sent) / Double(total) * 100)
                    : "—"
                NSLog("[files] 上传自检 第 %@ 秒 · %@ · %@ · 已传 %@ / %@ · %@ · 速率 %@ B/s · 队列 %@ 项",
                      String(tick), item.name, Self.uploadStateText(item.state), String(item.sent),
                      String(total), percent, String(Int(item.rate)),
                      String(uploads.queuedCount))
            }
            if started, !waiting { break }
        }

        // 收尾核对与清理。**核对必须看整层**（`List` 拉满 5000），不能看界面上那一页：
        // `/music` 有 3600 多项，测试件按名字排在第 4 页，翻首页会报假的「没落地」。
        // 列表刷新也要时间，刚传完就查同样是假阴性。
        guard let manager = sessionManager else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let layer = (try? await FileStation.list(
            manager, path: files.currentPath, sort: FileStation.defaultSort,
            limit: FileStation.treeFetchLimit
        ).entries) ?? []
        let strays = layer.filter { $0.name.hasPrefix("DreamanualUploadSmoke") }
        NSLog("[files] 上传自检 → %@（整层 %@ 项里 %@ 个测试件）",
              strays.isEmpty ? "✗ 没看到落地" : "✓ 已落地",
              String(layer.count), String(strays.count))

        // 传的是文件夹就再往里看一层：层级对不对、**空目录建出来了没有**。
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isFolder, let root = strays.first {
            if let top = try? await FileStation.list(
                manager, path: root.path, sort: FileStation.defaultSort, limit: 200
            ).entries {
                NSLog("[files] 上传自检 远端第一层 → %@", Self.treeLine(top))
                for dir in top.filter(\.isDirectory) {
                    if let kids = try? await FileStation.list(
                        manager, path: dir.path, sort: FileStation.defaultSort, limit: 200
                    ).entries {
                        NSLog("[files] 上传自检 远端 %@ → %@", dir.name, Self.treeLine(kids))
                    }
                }
            }
        }
        await files.refresh(manager, username: username)
        guard !strays.isEmpty else { return }
        do {
            let task = try await FileStation.delete(manager, paths: strays.map(\.path))
            NSLog("[files] 上传自检 收尾 → %@", task.failed ? "✗ 没删掉：\(task.failureText)" : "✓ 已清干净")
            await files.refresh(manager, username: username)
        } catch {
            NSLog("[files] 上传自检 收尾 → ✗ \(error.localizedDescription)")
        }
    }

    /// 「撞名弹窗」的冒烟：造一个与当前目录某项同名的临时文件丢进队列 ——
    /// 队列自己查重名、自己停下来问（弹窗形态只能这么看）。
    private func smokeConflict(_ name: String?) async {
        let existing = files.entries.first { $0.isDirectory == false } ?? files.entries.first
        guard let target = (name?.isEmpty == false ? name : existing?.name) else {
            NSLog("[files] 冲突自检：列表是空的，造不出撞名")
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(target)
        try? Data("Dreamanual 撞名演示".utf8).write(to: temp)
        NSLog("[files] 冲突自检：造「%@」传到 %@（那里已有同名项）", target, files.currentPath)
        upload(urls: [temp])
        try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
        if let prompt = uploads.conflict {
            NSLog("[files] 冲突自检 → ✓ 弹窗已摆出：目标已有「%@」· 保留两者会叫「%@」· 剩余 %@ 项",
                  prompt.existing.name, prompt.keptName, String(prompt.remaining))
        } else {
            NSLog("[files] 冲突自检 → ✗ 没有停下来问（队列没识别出撞名？）")
        }
    }

    private static func uploadStateText(_ state: UploadQueue.State) -> String {
        switch state {
        case .waiting: return "等待"
        case .uploading: return "上传中"
        case .done: return "已完成"
        case .skipped: return "已跳过"
        case .failed(let reason): return "失败（\(reason)）"
        }
    }

    /// 冒烟日志用的一行树：`名字/` 表示目录。
    private static func treeLine(_ entries: [FileEntry]) -> String {
        entries.isEmpty
            ? "（空）"
            : entries.map { "\($0.name)\($0.isDirectory ? "/" : "")" }.joined(separator: " / ")
    }

    /// 「取消」的冒烟：传一个 3 MB 的测试件，1.5 秒后取消，核对队列状态并清理现场。
    ///
    /// 客户端断开后服务端**可能已经收到整份**（取消只是不再等应答），所以现场
    /// 一律清一遍 —— 半截文件是可能存在的。
    private func smokeCancelCheck(_ manager: SessionManager) async {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DreamanualUploadSmoke_\(Int(Date().timeIntervalSince1970)).bin")
        try? Data(count: 3 * 1024 * 1024).write(to: temp)
        NSLog("[files] 取消自检：造 3 MB 测试件开始传")
        upload(urls: [temp])
        // 等真发出去了再取消 —— 摊平与查撞名也要一秒多，那之前取消等于没测到中断。
        for _ in 1...20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if (uploads.items.first?.sent ?? 0) > 0 { break }
        }
        let before = uploads.items.first
        NSLog("[files] 取消自检：已传 %@ 字节（%@），现在取消",
              String(before?.sent ?? 0), Self.uploadStateText(before?.state ?? .waiting))
        uploads.cancel()
        NSLog("[files] 取消自检 → 队列状态 %@",
              uploads.items.map { Self.uploadStateText($0.state) }.joined(separator: ", "))
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let layer = (try? await FileStation.list(
            manager, path: files.currentPath, sort: FileStation.defaultSort,
            limit: FileStation.treeFetchLimit
        ).entries) ?? []
        let strays = layer.filter { $0.name.hasPrefix("DreamanualUploadSmoke") }
        if !strays.isEmpty {
            _ = try? await FileStation.delete(manager, paths: strays.map(\.path))
            NSLog("[files] 取消自检 收尾 → 清掉 %@ 个测试件（服务端留了半截）", String(strays.count))
        } else {
            NSLog("[files] 取消自检 收尾 → 现场干净（服务端没留下半截文件）")
        }
        await files.refresh(manager, username: username)
    }

    /// 「在文件管理中显示」那一条接线的冒烟：搜一首歌，按它的真实目录跳过去。
    private func smokeReveal(_ keyword: String, manager: SessionManager) async {
        do {
            let page = try await AudioLibrary.search(manager, keyword: keyword, limit: 1)
            guard let song = page.songs.first else {
                NSLog("[files] 搜「%@」没有命中", keyword)
                return
            }
            NSLog("[files] 定位「%@」→ 目录 %@", song.title, song.folder)
            await revealInFiles(song)
        } catch {
            NSLog("[files] 定位失败：%@", error.localizedDescription)
        }
    }

    /// 等文件表把各格位置报上来（视图是逐帧长出来的，进程刚起那会儿还没有位置）。
    private func waitForFilesHeaderFrames() async {
        for attempt in 0..<20 {
            if !files.headerFrames.isEmpty { return }
            if attempt == 0 || attempt == 19 {
                NSLog("[files] 第 %d 次等表头位置：%@", attempt + 1,
                      files.headerFrames.isEmpty ? "还没有" : "有了")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// 合成一次鼠标点击到文件表表头某列上。**走真事件链**（与真鼠标同一条路）——
    /// 位置取 `HeaderGrabber` 自报的窗口坐标，不换算、不猜原点。
    private func clickFilesHeader(_ field: FileSortField) async -> Bool {
        guard let window = hostingWindow(), let frame = files.headerFrames[field] else { return false }
        await activateForSyntheticInput(window)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        sendMouse(.leftMouseDown, at: point, in: window)
        sendMouse(.leftMouseUp, at: point, in: window)
        return true
    }

    /// 等表头把各列位置报上来。视图是逐帧长出来的，进程刚起那会儿还没有位置。
    private func waitForHeaderFrames() async {
        for attempt in 0..<20 {
            if !library.headerFrames.isEmpty { return }
            if attempt == 0 || attempt == 19 {
                NSLog("[library] 第 %d 次等表头位置：%@", attempt + 1,
                      library.headerFrames.isEmpty ? "还没有" : "有了")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// 合成一次鼠标点击到表头某列上。**走真事件链**（`NSApp.postEvent`，与真鼠标
    /// 同一条路）—— 用来证明「点表头 → 排序」这条接线是通的。
    ///
    /// AI 环境点不了 UI（`cliclick` / `osascript` 没有辅助功能权限，点击被静默丢弃），
    /// 而表头点击从没被真机验证过（上面那些 `sort=` 指令走的是模型层，绕过了点击）
    /// —— 合成事件是这条路的唯一验法。
    private func clickHeader(_ field: TrackField) async -> Bool {
        guard let window = hostingWindow(), let point = headerPoint(field) else {
            return false
        }
        await activateForSyntheticInput(window)
        sendMouse(.leftMouseDown, at: point, in: window)
        sendMouse(.leftMouseUp, at: point, in: window)
        return true
    }

    /// 合成一次拖动（按下源列 → 拖到目标列 → 松手），验「拖动表头改列序」。
    /// 中间插几步：位移要过 6pt 阈值才认成拖动，一步到位会被当成点击。
    ///
    /// `release: false` = 拖到位不松手，让界面停在「正在拖」那一帧上 —— 拖动中的
    /// 虚线框、手柄图标、落点竖线只在那一瞬存在，抓图核对只能这么抓（`draghold=`）。
    @discardableResult
    private func dragHeader(_ from: TrackField, _ to: TrackField,
                            release: Bool = true) async -> Bool {
        guard let window = hostingWindow(),
              let start = headerPoint(from),
              let end = headerPoint(to) else { return false }
        await activateForSyntheticInput(window)
        sendMouse(.leftMouseDown, at: start, in: window)
        for step in 1...6 {
            let t = CGFloat(step) / 6
            sendMouse(.leftMouseDragged,
                      at: CGPoint(x: start.x + (end.x - start.x) * t,
                                  y: start.y + (end.y - start.y) * t),
                      in: window)
        }
        if release { sendMouse(.leftMouseUp, at: end, in: window) }
        return true
    }

    /// 合成鼠标事件之前必须把 app 与窗口弄到前台。
    ///
    /// 2026-10-14 实测：直起二进制时 app 不在前台（`NSApp.isActive = false`），
    /// 这时窗口**直接丢掉**鼠标事件 —— 表头位置算得再准也没用（诊断日志里
    /// 「命中 PlatformGroupContainer 但排序不变」就是这一条）。
    /// 真用户点击时窗口当然是活跃的，这一步是把前置条件摆回真实场景。
    private func activateForSyntheticInput(_ window: NSWindow) async {
        // `.activateIgnoringOtherApps` 在 macOS 14 起已废弃（本就无效果），只留
        // `.activateAllWindows`；真正的「到前台」由下面 `NSApp.activate()` 负责。
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // 激活要经 WindowServer 生效，给它一拍再发事件。
        try? await Task.sleep(nanoseconds: 400_000_000)
        NSLog("[library] 合成前：app 在前台=%@ · 窗口是 key=%@",
              NSApp.isActive ? "是" : "否", window.isKeyWindow ? "是" : "否")
    }

    /// 表头某列的窗口坐标（格子的中心）。
    ///
    /// 位置由 `HeaderGrabber` 自己报上来（`convert(bounds, to: nil)`，就是窗口坐标），
    /// 与 `NSEvent.mouseEvent` 要的坐标同一套 —— 中间不翻转、不换算。
    /// 2026-10-14 之前这里走的是「SwiftUI `.global` 里翻 y 再 `content.convert`」，
    /// 那两步都是猜的（`.global` 与内容坐标是不是同一原点没验过），猜错的表现就是
    /// 事件落在表头下方一行、点了等于没点。
    private func headerPoint(_ field: TrackField) -> CGPoint? {
        guard let frame = library.headerFrames[field] else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        // 走 app 的事件队列（`postEvent`），**不是** `window.sendEvent`：
        // 真鼠标事件也是先进队列、再由 run loop 派发给窗口，这条路与键盘冒烟同一套。
        NSApp.postEvent(event, atStart: false)
    }

    /// `DM_UI=<逗号分隔>` 时由入口调用：把窗口与右键那套摆到指定状态，供真机核对。
    ///
    /// AI 环境点不了 UI、拖不动窗口、按不了保存面板 —— 这三件事只能让程序自己走。
    /// 认得的指令：`window=<宽>x<高>` 摆主窗内容尺寸（最小窗宽那一屏要真机看）；
    /// `songmenu` 或 `songmenu=<x>:<y>` 打开曲库第一首的右键菜单（后者按窗口坐标
    /// 开在任意点）；`scroll=<n>` 往下滚 n 格（真 scrollWheel 走 `window.sendEvent`）；
    /// `rclick=<x>:<y>` 在窗口坐标发一次**真右键**（`window.sendEvent`，走
    /// `RightClickCatcher` 同一条 hitTest 链 —— 之前用 CGEvent 投递进不了视图层，
    /// sendEvent 是从窗口自己派发，捕获层收得到）；`download` 把曲库第一首下到
    /// 临时目录（走界面同一条 `FileDownloader`，落盘报字节数后清掉，别留垃圾）；
    /// `savepanel` 真开一次系统存盘面板（核对文案本地化，不自动关）；
    /// `module=<music|files|status|settings>` 切模块（截图核对各页形态）；
    /// `reconnect` 真机走一遍重连链路（清旧会话 → 本机口令 → connect）。
    func smokeUI(_ command: String) async {
        // 与 `DM_STATUS` 同一条坑：入口在启动瞬间就消费它，自动连却是异步的。
        // 不先等，整套界面指令在「未连接」上直接丢掉（本批真机踩到）。
        for _ in 0..<60 {
            if phase == .connected { break }
            if case .failed = phase { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard isConnected, let manager = sessionManager else {
            NSLog("[ui] 未连接，跳过")
            return
        }
        for raw in command.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if token.hasPrefix("window=") {
                await smokeWindow(String(token.dropFirst("window=".count)))
            } else if token == "songmenu" {
                await smokeSongMenu(manager)
            } else if token.hasPrefix("songmenu=") {
                await smokeSongMenuAt(String(token.dropFirst("songmenu=".count)), manager)
            } else if token.hasPrefix("scroll=") {
                await smokeScroll(String(token.dropFirst("scroll=".count)))
            } else if token.hasPrefix("rclick=") {
                await smokeRightClick(String(token.dropFirst("rclick=".count)))
            } else if token == "download" {
                await smokeDownload(manager)
            } else if token == "savepanel" {
                smokeSavePanel()
            } else if token == "tagload" {
                await smokeTagLoad(manager)
            } else if token == "reconnect" {
                // 真机走一遍重连链路：清旧会话 → 本机口令 → connect（日志看 [connect]）。
                NSLog("[ui] 触发重新连接")
                await reconnect()
            } else if token.hasPrefix("module=") {
                // 切模块：截图核对各页形态用（设置页这类没有数据通路的页面只能这样摆）。
                let name = String(token.dropFirst("module=".count))
                if let target = Module(rawValue: name) {
                    select(target)
                    NSLog("[ui] 切到模块「%@」", target.title)
                } else {
                    NSLog("[ui] 认不出模块「%@」", name)
                }
            } else {
                NSLog("[ui] 认不出指令「%@」", token)
            }
        }
    }

    /// 主窗摆到指定内容尺寸。窗口是启动后长出来的，等它出现再摆。
    private func smokeWindow(_ spec: String) async {
        let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let width = parts.first, let height = parts.last else {
            NSLog("[window] 认不出尺寸「%@」（要 宽x高）", spec)
            return
        }
        for _ in 0..<20 {
            if let window = hostingWindow() {
                window.setContentSize(NSSize(width: width, height: height))
                try? await Task.sleep(nanoseconds: 800_000_000)
                let actual = window.contentRect(forFrameRect: window.frame).size
                NSLog("[window] 摆 %@x%@ → 实际 %@x%@",
                      String(Int(width)), String(Int(height)),
                      String(Int(actual.width)), String(Int(actual.height)))
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        NSLog("[window] 没等到窗口")
    }

    /// 冒烟：按窗口坐标把第一首的右键菜单开在任意点（与 `songmenu` 同一入口，
    /// 点可指定 —— 量漂移用）。
    private func smokeSongMenuAt(_ spec: String, _ manager: SessionManager) async {
        let parts = spec.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, let x = parts.first, let y = parts.last else {
            NSLog("[ui] songmenu 认不出「%@」（要 x:y）", spec)
            return
        }
        await library.loadIfNeeded(manager)
        guard let song = library.songs.first else {
            NSLog("[ui] 曲库空，开不了菜单")
            return
        }
        openSongMenu(song, at: CGPoint(x: x, y: y), queue: library.songs)
        NSLog("[ui] 菜单请求点 (%.0f, %.0f)", x, y)
    }

    /// 冒烟：往下滚 n 格（真 scrollWheel 经 `window.sendEvent`，列表自己接）。
    private func smokeScroll(_ spec: String) async {
        guard let n = Int(spec), n > 0, let window = hostingWindow() else {
            NSLog("[ui] scroll 认不出「%@」（要正整数且窗口已起）", spec)
            return
        }
        await MainActor.run {
            for _ in 0..<n {
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                 wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0)
                if let ev = cg.flatMap({ NSEvent(cgEvent: $0) }) {
                    window.sendEvent(ev)
                }
            }
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        NSLog("[ui] 已滚 %d 格", n)
    }

    /// 冒烟：窗口坐标发一次真右键（`window.sendEvent`，走捕获层同一条 hitTest）。
    /// 菜单开完留在屏上 —— 之后用窗口截图量「请求点 → 捕获层报点 → 渲染点」。
    private func smokeRightClick(_ spec: String) async {
        let parts = spec.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, let x = parts.first, let y = parts.last,
              let window = hostingWindow() else {
            NSLog("[ui] rclick 认不出「%@」（要 x:y 且窗口已起）", spec)
            return
        }
        // 不激活连 hitTest 都进不去 —— 事件先经 app 判 key window。
        await activateForSyntheticInput(window)
        await MainActor.run {
            // 窗口坐标（左上原点）→ window 基坐标（左下原点）。hiddenTitleBar 的
            // contentView 铺满整个 frame，直接用 frame 翻 y。
            let loc = NSPoint(x: window.frame.minX + x,
                              y: window.frame.maxY - y)
            NSLog("[ui] 右键请求窗口坐标 (%.0f, %.0f) → window 基坐标 (%.0f, %.0f) frame=%@",
                  x, y, loc.x, loc.y, NSStringFromRect(window.frame))
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                if let ev = NSEvent.mouseEvent(with: type, location: loc,
                                               modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 1) {
                    // 直投窗口（app 不在前台时 NSApp.sendEvent 会丢事件）；
                    // 捕获层 hitTest 认 `window.currentEvent`，这条路能进去。
                    window.sendEvent(ev)
                }
            }
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    /// 冒烟：读曲库第一首的标签（`TagEditor.load`，**只读**，验证标签接口通路）。
    private func smokeTagLoad(_ manager: SessionManager) async {
        await library.loadIfNeeded(manager)
        guard let song = library.songs.first else {
            NSLog("[tag] 曲库是空的，无从读起")
            return
        }
        do {
            let info = try await TagEditor.load(manager, path: song.path)
            NSLog("[tag] 读回「%@」：艺术家=%@ 专辑=%@ 年份=%@ 音轨=%@",
                  song.title, info.artist, info.album,
                  info.year.map(String.init) ?? "—", info.track.map(String.init) ?? "—")
        } catch {
            NSLog("[tag] 读失败：%@", error.localizedDescription)
        }
    }

    private func smokeSongMenu(_ manager: SessionManager) async {        await library.loadIfNeeded(manager)
        guard let song = library.songs.first else {
            NSLog("[ui] 曲库是空的，菜单开不出来")
            return
        }
        // 锚点给内容区中上那一块，菜单卡按指针摆、越界会收回窗口内。
        openSongMenu(song, at: CGPoint(x: 380, y: 240), queue: library.songs)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        NSLog("[ui] 右键菜单已开「%@」（四项：播放 / 下一首播放 / 评分 / 下载）", song.title)
    }

    /// 冒烟用：真开一次系统存盘面板（核对面板文案本地化，2026-10-15 用户点名
    /// 下载弹窗出英文）。`begin` 非模态开出来，**不开自动关** —— 冒烟流程截完图
    /// 直接 pkill 收场；留给将来要程序化关时再补。
    private func smokeSavePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "冒烟-面板文案.mp3"
        panel.canCreateDirectories = true
        panel.begin { _ in }
        NSLog("[ui] 存盘面板已开出（本地化核对用）· 面板将取本地化 %@",
              Bundle.main.preferredLocalizations.description)
    }

    private func smokeDownload(_ manager: SessionManager) async {
        await library.loadIfNeeded(manager)
        guard let song = library.songs.first else {
            NSLog("[ui] 曲库是空的，下载无从谈起")
            return
        }
        guard let endpoint = try? await manager.fileEndpoint else {
            NSLog("[ui] 拿不到文件服务的端点")
            return
        }
        let dir = URL(fileURLWithPath: "/tmp/dm-smoke-download", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(Self.downloadName(for: song))
        try? FileManager.default.removeItem(at: destination)
        do {
            try await FileDownloader(
                baseURL: endpoint.baseURL,
                credentials: endpoint.credentials,
                allowSelfSigned: endpoint.allowSelfSigned,
                destination: destination
            ).start(path: song.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue
            NSLog("[ui] 下载落地 %@（%@ 字节）",
                  destination.lastPathComponent, size.map(String.init) ?? "?")
            // 冒烟用完就清 —— 落盘这一步已经证明了。
            try? FileManager.default.removeItem(at: destination)
        } catch {
            NSLog("[ui] 下载失败：%@", error.localizedDescription)
        }
    }

    /// 四个数据源各取一次（侧栏点得动之前，先把「取数通不通」验掉）。
    private func smokeLibrarySources(_ manager: SessionManager) async {
        do {
            let random = try await AudioLibrary.randomSongs(manager, limit: 100)
            NSLog("[smoke] 每日随机 %@ 首，首条「%@」", String(random.songs.count), random.songs.first?.title ?? "-")

            await smokeCovers(manager, songs: Array(random.songs.prefix(12)))

            let top = try await AudioLibrary.topRatedSongs(manager, minRating: 4)
            NSLog("[smoke] 评分 ≥ 4 星 %@ 首，最高 %@ 星",
                  String(top.songs.count), String(top.songs.first?.rating ?? 0))

            let lists = try await AudioLibrary.playlists(manager)
            NSLog("[smoke] 歌单 %@ 个：%@", String(lists.count),
                  lists.map { "\($0.name)(\($0.type))" }.joined(separator: " / "))
            // 取歌要逐首补标签，挑个小的（日语 4 首）验通路，别拿大歌单拖冒烟。
            if let target = lists.first(where: { $0.name == "日语" }) ?? lists.first {
                let page = try await AudioLibrary.songs(manager, playlistID: target.id)
                NSLog("[smoke] 歌单「%@」%@ 首，首条「%@」艺术家=%@",
                      target.name, String(page.songs.count),
                      page.songs.first?.title ?? "-",
                      page.songs.first?.artist ?? "-")
            }
        } catch {
            NSLog("[smoke] 数据源自检失败：%@", error.localizedDescription)
        }
    }

    /// 封面自检：按专辑取图，最多试 3 张不同的专辑。
    ///
    /// 这条路的参数名踩过坑（拿歌曲 `id` 去要一律 404），只有真机回图能证明走对了；
    /// 顺带验缓存 —— 同一张专辑第二次要图应当直接命中、不再发请求。
    private func smokeCovers(_ manager: SessionManager, songs: [AudioSong]) async {
        var keys = Set<String>()
        for song in songs where !song.album.isEmpty {
            let key = "\(song.folder)\u{1}\(song.album)\u{1}\(song.albumArtist)"
            guard keys.insert(key).inserted else { continue }
            let data = await CoverStore.shared.cover(
                manager: manager,
                album: song.album,
                artist: song.albumArtist,
                folder: song.folder
            )
            NSLog("[smoke] 封面「%@」/%@ → %@",
                  song.album,
                  song.albumArtist.isEmpty ? "-" : song.albumArtist,
                  data.map { "\($0.count) 字节" } ?? "无图")
            if keys.count >= 3 { break }
        }
        if let first = songs.first(where: { !$0.album.isEmpty }) {
            let again = await CoverStore.shared.cover(
                manager: manager,
                album: first.album,
                artist: first.albumArtist,
                folder: first.folder
            )
            NSLog("[smoke] 封面「%@」二次 → %@（走缓存）",
                  first.album, again.map { "\($0.count) 字节" } ?? "无图")
        }
    }

    /// - Parameter password: 口令只在内存里传，落盘只落本机凭据文件（0600）。
    /// - Parameter method: 连接页分段选的方式。分支只认它，不认另一个
    ///   字段有没有值 —— 残留的直连地址不抢 QuickConnect 的路。
    func connect(password: String, method: ConnectMethod) async {
        guard phase.isBusy == false else { return }
        phase = .resolving
        endpointLabel = ""
        lastConnectError = nil
        NSLog("[connect] connect 开始（%@）",
              method == .direct ? "直连" : "QuickConnect")

        // 表单里粘进来的值常带首尾空白，账号那一个字符之差就是 Auth 400，
        // 而错误提示看不出是空白 —— 发出去之前先剪掉。
        let qc = trimmedQCID
        let user = trimmedUsername

        do {
            let client: SynologyClient
            switch method {
            case .direct:
                guard let direct = DirectAddress.parse(directAddress) else {
                    throw QuickConnectError.badResponse(
                        "直连地址没填对：填主机或主机:端口（局域网 / Tailscale）")
                }
                // 这条路的证书是 NAS 自签的，要放行。
                NSLog("[connect] 直连分支 %@:%d", direct.host, direct.port)
                client = SynologyClient(host: direct.host, port: direct.port, allowSelfSigned: true)
                endpointLabel = "直连 \(direct.host):\(direct.port)"
                linkMode = .direct
            case .quickconnect:
                guard !qc.isEmpty else { throw QuickConnectError.badResponse("先填 QuickConnect ID") }
                let endpoint = try await resolver.resolve(id: qc)
                // 中继域名挂的是真证书（按 CNAME 目标签），走默认校验；只有
                // 服务端退回给 IP 那一种情况要放行自签。
                client = SynologyClient(host: endpoint.host, port: endpoint.port,
                                        allowSelfSigned: endpoint.needsCertBypass)
                let region = endpoint.region.map { " · \($0)" } ?? ""
                endpointLabel = "QuickConnect\(region) · \(endpoint.host):\(endpoint.port)"
                linkMode = .relay
            }

            phase = .loggingIn
            NSLog("[connect] probe 前")
            let manager = SessionManager(client: client, account: user, password: password)

            // 会话是否真能用，拿一次心跳说话 —— 登录成功但权限不对是另一回事。
            try await manager.probe()
            NSLog("[connect] probe 通过")

            sessionManager = manager

            // 播放引擎跟着会话一起上：端点与证书策略在每首开播时随凭据取。
            let engine = PlaybackEngine()
            engine.attach(sessionManager: manager)
            // 曲目 / 播放状态 / 进度有变化时把「正在播放」交给系统（媒体键那条路的回执）。
            engine.nowPlayingHandler = { [weak self] song, isPlaying, elapsed, duration in
                self?.nowPlaying.publish(song: song, isPlaying: isPlaying,
                                         elapsed: elapsed, duration: duration)
            }
            playback = engine
            nowPlaying.attach(to: engine)

            await manager.startKeepAlive()
            lastConnectedAt = Date()
            phase = .connected

            // 小组件的共享快照：状态页拉到新数就顺手落盘；另外连上后
            // 每 15 分钟推一拍（与小组件的刷新节奏对齐 —— app 活着的
            // 时候，小组件基本用不着自己连）。
            status.onFreshSnapshot = { [weak self] snapshot in
                guard let self else { return }
                Task { await self.publishWidgetSnapshot(snapshot) }
            }
            startWidgetPush()

            // 连上即存：口令落本机文件（0600），下次启动自动重连。写也走后台，
            // 不占主线程。方式一并记下 —— 端点键与自动连都按它走。
            lastMethod = method
            defaults.set(Self.raw(of: method), forKey: Keys.method)
            let key = endpointKey
            Task.detached(priority: .utility) {
                CredentialStore.save(password: password, endpointID: key, username: user)
            }
        } catch {
            lastConnectError = error
            phase = .failed(error.localizedDescription)
            sessionManager = nil
        }
    }

    /// 设置页的「重新连接」：清掉旧会话，用本机存的口令原样再连一次。
    ///
    /// 与 `disconnect()` 的差别只在**不动本机缓存**（封面 / 歌词 / 开关机计划）——
    /// 连的还是同一台机器，重拉一遍封面纯属浪费。口令按当前端点键取：
    /// 刚改过直连地址的话键跟着变了、取不到，那就退回连接页让用户重输口令，
    /// 别拿旧口令硬试（错的凭据会把 DSM 的自动封锁喂起来，见 `接口文档` 登录 400 那条）。
    func reconnect() async {
        cancelAutoConnect()
        playback?.detach()
        playback = nil
        showsQueue = false
        showsImmersive = false
        status.clear()
        widgetPushTask?.cancel()
        widgetPushTask = nil
        if let manager = sessionManager {
            await manager.stopKeepAlive()
            await manager.logoutAll()
        }
        sessionManager = nil
        endpointLabel = ""
        linkMode = nil
        phase = .idle

        guard let password = CredentialStore.load(endpointID: endpointKey,
                                                 username: trimmedUsername),
              !password.isEmpty
        else {
            toast = ToastMessage("连接设置变了，需要重新输入口令", .info)
            NSLog("[connect] 重连取不到本端点的口令（端点键 %@），退回连接页", endpointKey)
            return
        }
        await connect(password: password, method: resumeMethod)
    }

    func disconnect() async {
        cancelAutoConnect()
        playback?.detach()
        playback = nil
        showsQueue = false
        showsImmersive = false
        // 封面与歌词缓存按专辑名 / 歌曲 id 做键、不区分是哪个库，换机器要清掉。
        await CoverStore.shared.clear()
        await LyricsStore.shared.clear()
        if let manager = sessionManager {
            await manager.stopKeepAlive()
            await manager.logoutAll()
        }
        sessionManager = nil
        endpointLabel = ""
        linkMode = nil
        status.clear()
        widgetPushTask?.cancel()
        widgetPushTask = nil
        // 改到一半的草稿也一起丢 —— 换了机器，旧计划不作数。
        powerSchedule.clear()
        phase = .idle
    }

    // MARK: - 小组件推送

    private var widgetPushTask: Task<Void, Never>?

    private func startWidgetPush() {
        widgetPushTask?.cancel()
        widgetPushTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pushWidgetSnapshot()
                try? await Task.sleep(nanoseconds: 900_000_000_000)
            }
        }
    }

    private func pushWidgetSnapshot() async {
        guard let manager = sessionManager else { return }
        let snapshot = await SystemStatusAPI.fetch(manager)
        guard !snapshot.isEmpty else { return }
        await publishWidgetSnapshot(snapshot)
    }

    private func publishWidgetSnapshot(_ snapshot: SystemSnapshot) async {
        // 口令随快照带：widget 沙箱里读不了 credential.json，自拉链路靠它。
        let password = CredentialStore.load(endpointID: endpointKey,
                                            username: trimmedUsername) ?? ""
        await WidgetBridge.publish(snapshot, endpointKey: endpointKey,
                                   qcID: trimmedQCID, directAddress: directAddress,
                                   username: trimmedUsername, password: password)
    }

    /// 冒烟：`feed` 现拉一份快照落盘并报内容；`state` 只回读落盘文件。
    func smokeWidget(_ command: String) async {
        switch command {
        case "feed":
            guard let manager = sessionManager else {
                NSLog("[widget] 没有会话 —— 先连上再 feed")
                return
            }
            let snapshot = await SystemStatusAPI.fetch(manager)
            NSLog("[widget] 现拉快照：device=%@ load=%@ storage=%@ health=%@ 失败=%@",
                  snapshot.device != nil ? "✓" : "✗",
                  snapshot.load != nil ? "✓" : "✗",
                  snapshot.storage != nil ? "✓" : "✗",
                  snapshot.health != nil ? "✓" : "✗",
                  snapshot.failures.isEmpty ? "无" : snapshot.failures.joined(separator: "；"))
            await publishWidgetSnapshot(snapshot)
            reportStoredWidgetState()
        case "state":
            reportStoredWidgetState()
        default:
            NSLog("[widget] 不认识的指令「%@」（feed / state）", command)
        }
    }

    private func reportStoredWidgetState() {
        guard let data = WidgetBridge.read() else {
            NSLog("[widget] 落盘文件不存在或解不开：%@", WidgetBridge.fileURL.path)
            return
        }
        NSLog("[widget] 快照 %@：温度 %d°C · CPU %d%% · 卷 %.2f/%.2f TB · 盘 %d 块 · crashed=%@ · 端点=%@",
              data.takenAt.description, data.temperature, data.cpuUsage,
              Double(data.volumeUsed) / 1_099_511_627_776, Double(data.volumeTotal) / 1_099_511_627_776,
              data.disks.count, data.crashed ? "是" : "否", data.endpointKey)
    }

    /// 凭据条目的键：QuickConnect ID 与直连地址是两个不同的「端点身份」，
    /// 各自记各自的凭据，切换连接方式不会互相覆盖。
    ///
    /// 按上一次成功连接的方式取（`lastMethod`）；没有记录（升级前的存量）
    /// 退回旧判定 —— 直连地址填了就算直连，与旧行为一致、凭据条目不变。
    private var endpointKey: String {
        switch lastMethod {
        case .quickconnect:
            return "qc:\(trimmedQCID)"
        case .direct, nil:
            if let direct = DirectAddress.parse(directAddress) {
                return "direct:\(direct.host):\(direct.port)"
            }
            return "qc:\(trimmedQCID)"
        }
    }

    /// 表单值发出去之前剪掉首尾空白。存储的那份保持原样 —— 一边敲一边被改，
    /// 光标会跳。
    private var trimmedQCID: String {
        qcID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

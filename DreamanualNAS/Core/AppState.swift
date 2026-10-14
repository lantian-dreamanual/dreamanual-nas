import AppKit
import Foundation
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

    // MARK: - 连接表单（持久化，口令除外）

    var qcID: String { didSet { defaults.set(qcID, forKey: Keys.qcID) } }
    var directAddress: String { didSet { defaults.set(directAddress, forKey: Keys.direct) } }
    var username: String { didSet { defaults.set(username, forKey: Keys.username) } }

    // MARK: - 运行状态

    private(set) var phase: Phase = .idle
    /// 端点描述，连上之后显示在侧栏底部（走中继还是直连、主机端口、区域）。
    private(set) var endpointLabel = ""
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
    }

    init() {
        qcID = defaults.string(forKey: Keys.qcID) ?? ""
        directAddress = defaults.string(forKey: Keys.direct) ?? ""
        username = defaults.string(forKey: Keys.username) ?? ""
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
        let panel = NSSavePanel()
        panel.title = "下载到"
        panel.nameFieldStringValue = downloadName(for: song)
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
        if code == 53, songMenu != nil {
            closeSongMenu()
            return true
        }
        // ⌘ / ⌥ / ⌃ 的组合一律放行 —— 系统与菜单的快捷键优先。
        let modifiers = flags.intersection(.deviceIndependentFlagsMask)
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
    /// 读文件不弹任何系统框；只有文件还没有、要走钥匙串迁移那一次可能弹
    /// 授权框。所以读取依然不能留在 `@MainActor` 上：挂在主线程时弹窗期间
    /// 整个窗口都不渲染（2026-10-12 实测：进程活着、窗口 0×0、卡死启动帧）。
    func restoreAndAutoConnect() async {
        guard isConnected == false, phase.isBusy == false else { return }
        let endpoint = endpointKey
        let user = trimmedUsername
        let saved = await Task.detached(priority: .userInitiated) {
            CredentialStore.load(endpointID: endpoint, username: user)
        }.value
        guard let password = saved else { return }
        await connect(password: password)
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
    /// `songmenu` 打开曲库第一首的右键菜单；`download` 把曲库第一首下到临时目录
    /// （走界面同一条 `FileDownloader`，落盘报字节数后清掉，别留垃圾）。
    func smokeUI(_ command: String) async {
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
            } else if token == "download" {
                await smokeDownload(manager)
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

    private func smokeSongMenu(_ manager: SessionManager) async {
        await library.loadIfNeeded(manager)
        guard let song = library.songs.first else {
            NSLog("[ui] 曲库是空的，菜单开不出来")
            return
        }
        // 锚点给内容区中上那一块，菜单卡按指针摆、越界会收回窗口内。
        openSongMenu(song, at: CGPoint(x: 380, y: 240), queue: library.songs)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        NSLog("[ui] 右键菜单已开「%@」（四项：播放 / 下一首播放 / 评分 / 下载）", song.title)
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
    func connect(password: String) async {
        guard phase.isBusy == false else { return }
        phase = .resolving
        endpointLabel = ""

        // 表单里粘进来的值常带首尾空白，账号那一个字符之差就是 Auth 400，
        // 而错误提示看不出是空白 —— 发出去之前先剪掉。
        let qc = trimmedQCID
        let user = trimmedUsername

        do {
            let client: SynologyClient
            if let direct = DirectAddress.parse(directAddress) {
                // 直连覆盖：局域网或 Tailscale。这条路的证书是 NAS 自签的，要放行。
                client = SynologyClient(host: direct.host, port: direct.port, allowSelfSigned: true)
                endpointLabel = "直连 \(direct.host):\(direct.port)"
            } else {
                guard !qc.isEmpty else { throw QuickConnectError.badResponse("先填 QuickConnect ID，或填一个直连地址") }
                let endpoint = try await resolver.resolve(id: qc)
                // 中继挂的是真证书，走默认校验。
                client = SynologyClient(host: endpoint.host, port: endpoint.port, allowSelfSigned: false)
                let region = endpoint.region.map { " · \($0)" } ?? ""
                endpointLabel = "QuickConnect\(region) · \(endpoint.host):\(endpoint.port)"
            }

            phase = .loggingIn
            let manager = SessionManager(client: client, account: user, password: password)

            // 会话是否真能用，拿一次心跳说话 —— 登录成功但权限不对是另一回事。
            try await manager.probe()

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

            // 连上即存：口令落本机文件（0600），下次启动自动重连。写也走后台，
            // 不占主线程。
            let key = endpointKey
            Task.detached(priority: .utility) {
                CredentialStore.save(password: password, endpointID: key, username: user)
            }
        } catch {
            phase = .failed(error.localizedDescription)
            sessionManager = nil
        }
    }

    func disconnect() async {
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
        phase = .idle
    }

    /// 凭据条目的键：QuickConnect ID 与直连地址是两个不同的「端点身份」，
    /// 各自记各自的凭据，切换连接方式不会互相覆盖。
    private var endpointKey: String {
        if let direct = DirectAddress.parse(directAddress) { return "direct:\(direct.host):\(direct.port)" }
        return "qc:\(trimmedQCID)"
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

/// 直连地址解析：接受 `主机`、`主机:端口`、`https://主机:端口`。
struct DirectAddress {
    let host: String
    let port: Int

    static func parse(_ text: String) -> DirectAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var rest = trimmed
        for scheme in ["https://", "http://"] where rest.hasPrefix(scheme) {
            rest = String(rest.dropFirst(scheme.count))
        }
        rest = rest.split(separator: "/").first.map(String.init) ?? rest

        let parts = rest.split(separator: ":")
        switch parts.count {
        case 1:
            return DirectAddress(host: String(parts[0]), port: 5001)
        case 2:
            guard let port = Int(parts[1]) else { return nil }
            return DirectAddress(host: String(parts[0]), port: port)
        default:
            return nil
        }
    }
}

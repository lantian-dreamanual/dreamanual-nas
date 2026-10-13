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
    /// 播放队列占主区（原型「队列」屏）—— 从播放条的队列按钮进出，
    /// 侧栏没有队列这一项。
    private(set) var showsQueue = false
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
    }

    /// 播放条的队列按钮：主区在曲库 ↔ 队列之间切。
    func toggleQueue() {
        if module != .music {
            select(.music)
            showsQueue = true
            return
        }
        showsQueue.toggle()
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

    // MARK: - 连接

    /// 启动时自动连一次（钥匙串里真有那条凭据才动）。
    ///
    /// 钥匙串的读可能弹系统授权框 —— 每次重新编译，ad-hoc 签名跟着变，macOS
    /// 要求重新授权读取 `dreamanual-nas` 条目；`SecItemCopyMatching` 在框被点掉
    /// 之前不返回。所以读取不能留在 `@MainActor` 上：挂在主线程时弹窗期间整个
    /// 窗口都不渲染（2026-10-12 实测：进程活着、窗口 0×0、卡死在启动帧）。
    func restoreAndAutoConnect() async {
        guard isConnected == false, phase.isBusy == false else { return }
        let endpoint = endpointKey
        let user = trimmedUsername
        let saved = await Task.detached(priority: .userInitiated) {
            KeychainStore.password(endpointID: endpoint, username: user)
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
            let key = "\(song.album)\u{1}\(song.albumArtist)"
            guard keys.insert(key).inserted else { continue }
            let data = await CoverStore.shared.cover(manager: manager, album: song.album, artist: song.albumArtist)
            NSLog("[smoke] 封面「%@」/%@ → %@",
                  song.album,
                  song.albumArtist.isEmpty ? "-" : song.albumArtist,
                  data.map { "\($0.count) 字节" } ?? "无图")
            if keys.count >= 3 { break }
        }
        if let first = songs.first(where: { !$0.album.isEmpty }) {
            let again = await CoverStore.shared.cover(manager: manager, album: first.album, artist: first.albumArtist)
            NSLog("[smoke] 封面「%@」二次 → %@（走缓存）",
                  first.album, again.map { "\($0.count) 字节" } ?? "无图")
        }
    }

    /// - Parameter password: 口令只在内存里传，落盘只落钥匙串。
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
            playback = engine

            await manager.startKeepAlive()
            lastConnectedAt = Date()
            phase = .connected

            // 连上即存：口令只进钥匙串，下次启动自动重连。写也走后台 ——
            // 同一条授权框没点掉时写入一样会挂住主线程。
            // 🔴 口令没变就不重写：save 是删了重建，会把条目上的访问授权
            //（security -A、历次「始终允许」）一并清掉，重编译后又要授权。
            let account = KeychainStore.accountKey(endpointID: endpointKey, username: user)
            Task.detached(priority: .utility) {
                if KeychainStore.password(account: account) != password {
                    KeychainStore.save(password: password, account: account)
                }
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
        // 封面缓存按专辑名做键、不区分是哪个库，换机器要清掉。
        await CoverStore.shared.clear()
        if let manager = sessionManager {
            await manager.stopKeepAlive()
            await manager.logoutAll()
        }
        sessionManager = nil
        endpointLabel = ""
        phase = .idle
    }

    /// 钥匙串条目的键：QuickConnect ID 与直连地址是两个不同的「端点身份」，
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

import AVFoundation
import Foundation
import Observation

/// 播放引擎：队列 + 取流 + AVPlayer。
///
/// 取流走 `StreamLoader`（自定义 scheme + 资源装载代理，接口结论 §二路线 A）——
/// AVPlayer 自己发不出带 `X-SYNO-TOKEN` 的请求，直连模式还要放行自签证书。
/// loader 与 asset **成对持有**：resource loader 不保证持住 delegate，而
/// AVFoundation 对象只被局部变量持有会在播放中途释放（接口结论的实测坑）。
@MainActor
@Observable
final class PlaybackEngine {
    private struct Track {
        let song: AudioSong
        let asset: AVURLAsset
        let loader: StreamLoader
    }

    /// 切上一首的门槛：过了它上一首就是「从头播」，没过就是「重播当前」。
    static let restartThreshold: Double = 3

    /// 冒烟日志开关（`DM_SMOKE=1` 时往 stderr 打关键状态）。
    static let smoke = ProcessInfo.processInfo.environment["DM_SMOKE"] == "1"

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var tracks: [Track] = []

    private(set) var queue: [AudioSong] = []
    /// 播放顺序 → 队列下标的映射。随机播放改这张表，队列本身不动。
    private(set) var playOrder: [Int] = []
    /// 当前播放位置（`playOrder` 的下标，不是队列下标）。
    private(set) var position: Int = 0

    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var volume: Double = 0.7 {
        didSet { player.volume = Float(volume) }
    }
    private(set) var isShuffled = false
    /// 取流失败时的提示，挂播放条上。成功开下一首时清掉。
    private(set) var streamErrorMessage: String?

    /// 「正在播放」信息的出口（装配时由 `AppState` 挂上 `NowPlaying`）。
    /// 曲目、播放状态、进度这三样有变化时往外送一次 —— 系统自己按
    /// `elapsedPlaybackTime` + `playbackRate` 外推进度，不必每秒刷。
    var nowPlayingHandler: (@MainActor (AudioSong?, Bool, Double, Double) -> Void)?

    var currentSong: AudioSong? {
        guard playOrder.indices.contains(position) else { return nil }
        return queue[playOrder[position]]
    }

    /// 队列里的下一首（按播放顺序，随机播放也照打乱后的顺序）。队尾回 nil ——
    /// 沉浸模式的「接下来播放」用它，队尾时那块换成一行占位文案。
    var nextSong: AudioSong? {
        guard playOrder.indices.contains(position + 1) else { return nil }
        return queue[playOrder[position + 1]]
    }

    var hasQueue: Bool { !queue.isEmpty }

    private var sessionManager: SessionManager?

    init() {
        // 进度：0.25s 一拍，够进度条走又不刷屏。
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
        player.volume = Float(volume)
    }

    // MARK: - 装配

    /// 连上之后由 `AppState` 挂进来。端点与证书策略在每首开播时随凭据一起取
    /// （重登会换 sid，缓存了反而会过期），这里只记会话。
    func attach(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    func detach() {
        stop()
        sessionManager = nil
    }

    // MARK: - 队列

    /// 用一组歌换掉整个队列，从第 `at` 首开始播（曲库表双击、歌单点播放）。
    func play(_ songs: [AudioSong], at index: Int) {
        guard !songs.isEmpty, songs.indices.contains(index) else { return }
        queue = songs
        isShuffled = false
        playOrder = Array(songs.indices)
        start(at: playOrder.firstIndex(of: index) ?? 0)
    }

    /// 同上，按歌曲 id 找起点（界面上手里常常只有 id）。
    func play(_ songs: [AudioSong], songID: String) {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
        play(songs, at: index)
    }

    /// 追加到队尾（「添加到歌单」那一族还没落，先留着这个口）。
    func append(_ songs: [AudioSong]) {
        guard !songs.isEmpty else { return }
        let base = queue.count
        queue.append(contentsOf: songs)
        playOrder.append(contentsOf: base..<(base + songs.count))
    }

    func clearQueue() {
        stop()
        queue = []
        playOrder = []
        position = 0
        publishNowPlaying()
    }

    /// 评分变更后同步队列里那一首 —— 播放条读 `currentSong`，本地不同步的话
    /// 评完分星还是灭的。
    func applyRating(songID: String, rating: Int) {
        guard let index = queue.firstIndex(where: { $0.id == songID }) else { return }
        queue[index].rating = rating
    }

    /// 随机播放：重排播放顺序，当前这首歌钉在第一位 —— 点开随即听到的还是
    /// 正在放的这首，后面的顺序打乱。再点一次回到原序。
    func toggleShuffle() {
        guard !queue.isEmpty else { return }
        let currentIndex = playOrder.indices.contains(position) ? playOrder[position] : 0
        if isShuffled {
            playOrder = Array(queue.indices)
            position = playOrder.firstIndex(of: currentIndex) ?? 0
        } else {
            var rest = queue.indices.filter { $0 != currentIndex }
            rest.shuffle()
            playOrder = [currentIndex] + rest
            position = 0
        }
        isShuffled.toggle()
    }

    // MARK: - 控制

    func togglePlayPause() {
        guard hasQueue else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else if player.currentItem != nil {
            player.play()
            isPlaying = true
        } else {
            start(at: position)
            return
        }
        publishNowPlaying()
    }

    /// 只播（媒体键 / 控制中心的播放）：已经在播就不动 —— 用 `togglePlayPause`
    /// 会把「系统发来 play」变成暂停。
    func play() {
        guard hasQueue, !isPlaying else { return }
        togglePlayPause()
    }

    /// 只停（媒体键的暂停）。
    func pause() {
        guard isPlaying else { return }
        togglePlayPause()
    }

    func next() {
        guard position + 1 < playOrder.count else {
            // 队尾：停在这一首的结尾，队列还在。
            pauseAtEnd()
            return
        }
        start(at: position + 1)
    }

    func previous() {
        if currentTime > Self.restartThreshold {
            seek(to: 0)
            return
        }
        guard position > 0 else {
            seek(to: 0)
            return
        }
        start(at: position - 1)
    }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        publishNowPlaying()
    }

    /// 把一首歌插到「接下来播放」的位置（右键菜单「下一首播放」）。
    ///
    /// 队列与播放顺序是两张表：歌追加到 `queue` 末尾，`playOrder` 里插到**当前
    /// 播放位置后面** —— 随机播放打开时也照打乱后的顺序落在「下一首」。
    func insertNext(_ song: AudioSong) {
        guard playOrder.indices.contains(position) else {
            play([song], at: 0)
            return
        }
        queue.append(song)
        playOrder.insert(queue.count - 1, at: position + 1)
    }

    func setVolume(_ value: Double) {
        volume = min(max(0, value), 1)
    }

    // MARK: - 内部

    private func start(at newPosition: Int) {
        guard playOrder.indices.contains(newPosition) else { return }
        position = newPosition
        streamErrorMessage = nil

        guard let manager = sessionManager else {
            streamErrorMessage = "会话不在了，重新连接后再播。"
            isPlaying = false
            return
        }
        let song = queue[playOrder[position]]
        currentTime = 0
        duration = Double(max(1, song.duration))

        Task { [weak self] in
            guard let self else { return }
            do {
                // 重登会换 sid —— 每首开播都取一次凭据快照，别缓存。
                let endpoint = try await manager.streamEndpoint
                let loader = StreamLoader(
                    songID: song.id,
                    contentType: StreamLoader.contentType(for: song),
                    endpoint: endpoint
                )
                let ext = StreamLoader.fileExtension(of: song)
                guard let url = URL(string: "\(StreamLoader.scheme)://stream/\(song.id).\(ext)") else {
                    throw PlaybackError.badAsset
                }
                let asset = AVURLAsset(url: url)
                loader.attach(to: asset)
                let item = AVPlayerItem(asset: asset)

                tracks = [Track(song: song, asset: asset, loader: loader)]
                // 结尾自动切下一首。观察者跟着 item 走，换歌即换观察。
                removeEndObserver()
                endObserver = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.didPlayToEndTimeNotification,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.handleEndOfItem()
                    }
                }
                // 装载代理的异步失败只进 loadingRequest，外面看不到 —— 在这里
                // 拦 item 的 failed，把错误挂上播放条（之前流断了 UI 毫无表示）。
                removeStatusObserver()
                statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, case .failed = item.status else { return }
                        self.streamErrorMessage = item.error?.localizedDescription ?? "取流失败。"
                        self.isPlaying = false
                        self.publishNowPlaying()
                    }
                }

                player.replaceCurrentItem(with: item)
                player.play()
                isPlaying = true
                self.publishNowPlaying()
                if Self.smoke {
                    NSLog("[play] start id=%@ ext=%@ item=%@", song.id, ext, item.debugDescription)
                }
            } catch {
                streamErrorMessage = error.localizedDescription
                isPlaying = false
                self.publishNowPlaying()
            }
        }
    }

    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?

    private func handleEndOfItem() {
        next()
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func removeStatusObserver() {
        statusObserver = nil
    }

    /// 冒烟验证的状态快照（`DM_SMOKE=1` 时由入口每秒打一条）。
    func smokeStatus() -> String {
        let status: String
        switch player.currentItem?.status {
        case .readyToPlay: status = "ready"
        case .failed: status = "failed"
        default: status = "unknown"
        }
        return String(
            format: "t=%.1fs dur=%.0fs playing=%d item=%@ err=%@",
            currentTime, duration, isPlaying ? 1 : 0, status, streamErrorMessage ?? "-"
        )
    }

    private func pauseAtEnd() {
        player.pause()
        isPlaying = false
        seek(to: duration)
    }

    private func publishNowPlaying() {
        nowPlayingHandler?(currentSong, isPlaying, currentTime, duration)
    }

    private func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeEndObserver()
        removeStatusObserver()
        isPlaying = false
        currentTime = 0
        duration = 0
        tracks = []
        publishNowPlaying()
    }
}

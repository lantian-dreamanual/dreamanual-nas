import Foundation
import MediaPlayer

/// 系统媒体键与「正在播放」信息（Mac 上的 F7 / F8 / F9、控制中心、AirPods 的按压）。
///
/// **为什么不自己把 F8 当按键绑**：
///   1. macOS 上 F8 是**系统媒体键**，由系统分给「当前发布正在播放信息的应用」。
///      自己当普通按键绑，就要求 app 有键盘焦点 —— 而媒体键的用处恰恰是 app
///      不在前台时（用户在别的窗口里想按一下暂停）。
///   2. 键盘没设成「F1–F12 作标准功能键」的机器上，F8 根本到不了 app 的按键事件，
///      收到的是系统媒体事件。
///   3. 没有实体 F8 的机型（Touch Bar、外接小键盘）按不到。
///
/// 接上 `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter` 之后这三条都不存在：
/// 系统把媒体键 / 控制中心 / 耳机上的操作都变成命令发给本应用，顺带把曲目信息
/// 显示在控制中心里。
@MainActor
final class NowPlaying {
    /// 媒体键翻译出来的动作。**先落成这一层再进引擎** —— 命令到动作的绑定在
    /// `attach` 里，动作本身可以单独驱动（冒烟通路走这条：AI 按不了 F8）。
    enum Action: Equatable {
        case play
        case pause
        case toggle
        case next
        case previous
        case seek(Double)
    }

    /// 媒体键「快进 / 快退」一步多少秒。
    static let skipStep: Double = 15

    private weak var engine: PlaybackEngine?

    /// 注册命令。**重复注册会叠加**（同一个命令挂两个 target，按一下跑两遍），
    /// 所以装配一次就够，别在每次连接时重挂。
    func attach(to engine: PlaybackEngine) {
        guard self.engine == nil else {
            self.engine = engine
            return
        }
        self.engine = engine

        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { _ in .play }
        register(center.pauseCommand) { _ in .pause }
        register(center.togglePlayPauseCommand) { _ in .toggle }
        register(center.nextTrackCommand) { _ in .next }
        register(center.previousTrackCommand) { _ in .previous }
        register(center.skipForwardCommand) { _ in .seek(Self.skipStep) }
        register(center.skipBackwardCommand) { _ in .seek(-Self.skipStep) }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipStep)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipStep)]
        // 进度条拖动（控制中心里那条）。
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: position.positionTime) }
            return .success
        }
    }

    /// 命令 → 动作的绑定。回调可能不在主线程，所以一律跳回主线程再动引擎。
    private func register(_ command: MPRemoteCommand,
                          action: @escaping (MPRemoteCommandEvent) -> Action) {
        command.isEnabled = true
        command.addTarget { [weak self] event in
            let resolved = action(event)
            Task { @MainActor in self?.perform(resolved) }
            return .success
        }
    }

    /// 落动作。对外是给冒烟通路用的（真机按不了媒体键）。
    @discardableResult
    func perform(_ action: Action) -> MPRemoteCommandHandlerStatus {
        guard let engine else { return .commandFailed }
        switch action {
        case .play: engine.play()
        case .pause: engine.pause()
        case .toggle: engine.togglePlayPause()
        case .next: engine.next()
        case .previous: engine.previous()
        case .seek(let delta): engine.seek(to: engine.currentTime + delta)
        }
        return .success
    }

    private func seek(to seconds: Double) {
        engine?.seek(to: seconds)
    }

    /// 把当前曲目与播放状态交给系统。曲目 / 播放状态 / 进度变化时各来一次就够 ——
    /// 系统按 `elapsedPlaybackTime` + `playbackRate` 自己外推进度条。
    func publish(song: AudioSong?, isPlaying: Bool, elapsed: Double, duration: Double) {
        let center = MPNowPlayingInfoCenter.default()
        guard let song else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if !song.artist.isEmpty { info[MPMediaItemPropertyArtist] = song.artist }
        if !song.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = song.album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}

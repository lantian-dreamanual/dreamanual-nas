import SwiftUI

/// 底部常驻播放条：通栏挂在窗口底部，不属于任何模块 —— 切到文件管理或
/// 系统状态，播放与进度不中断（产品定义第二节「外壳」）。
///
/// 进度条照网易云的展开形态（2026-10-13 用户拍板）：默认 3px 细线贴上沿、
/// 兼作与内容区的分隔线；悬停 / 拖动**向上**展开成 6px + 10px 大拇指 + 时间气泡，
/// 展开向上溢出条外、不挤占内容。播放行顶边距 6 / 底边距 10（顶上有线位压着，
/// 视觉才对称）。其余照原型 `.player`：三栏（300 / 弹性 / 200）、
/// 播放钮 36 圆、音量条 80×4（填充 `ink-2`）。数据源是 `PlaybackEngine` ——
/// 没有引擎（未连接）或队列为空时是**空态**：线保持 3px 灰、控件禁用、左侧写「未在播放」。
struct PlayerBarView: View {
    @Environment(AppState.self) private var state
    let engine: PlaybackEngine?

    // 进度条的悬停 / 拖拽。`onContinuousHover` 给坐标，气泡才能跟着走。
    @State private var hoverX: CGFloat?
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0
    // 播放钮的悬停（原型 hover 换 fill-2）。
    @State private var isPlayHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // 进度线就是播放条的顶线（不再另画发丝），线位只占 3px：
            // 行高 56 装 44 封面，上下各余 6，边距对称。
            progressLine

            HStack(spacing: DmSpace.s16) {
                nowPlaying
                Spacer(minLength: 0)
                controls
                Spacer(minLength: 0)
                volume
            }
            .padding(.horizontal, DmSpace.s16)
            // 底边距比顶边距大 4：顶上有 3px 线位压着，视觉上才对称
            //（2026-10-13 用户反馈「下边距小」）。
            .padding(.top, DmSpace.s6)
            .padding(.bottom, DmSpace.s10)
        }
        .background(Color.dmPanel)
    }

    // MARK: 进度条

    private var durationFraction: Double {
        guard let engine, engine.duration > 0 else { return 0 }
        return min(1, engine.currentTime / engine.duration)
    }
    private var shownFraction: Double { isScrubbing ? scrubFraction : durationFraction }
    private var isEngaged: Bool { hoverX != nil || isScrubbing }

    private func timeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// 进度线本体：占位 3px；悬停时长到 6px 且**整体抬到条沿外**（轨道 [-6,0]，
    /// 拇指骑在沿上）—— 展开只向上、条内几何不动。🔴 两个布局坑（2026-10-13
    /// 用户两轮抓出来的）：① GeometryReader 把超框子视图居中放，轨道要在 GR
    /// 里钉底再抬；② 气泡不能当轨道 ZStack 的布局子视图（Text 撑高 ZStack、
    /// 轨道跟着居中漂），要挂 overlay。
    private var progressLine: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let h: CGFloat = isEngaged ? 6 : 3
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.dmPanel3)
                    .frame(height: h)
                Rectangle()
                    .fill(isEngaged ? Color.dmAccent2 : Color.dmAccent)
                    .frame(width: width * shownFraction, height: h)
                if isEngaged {
                    Circle()
                        .fill(Color.dmInk)
                        .frame(width: 10, height: 10)
                        .offset(x: width * shownFraction - 5)
                }
            }
            .frame(height: h)
            .overlay(alignment: .top) {
                if let hoverX, !isScrubbing, let engine, engine.hasQueue {
                    // 气泡报悬停位置的时间（原型 `.p-line .tip`）；挂 overlay
                    // 不参与布局，悬在轨道上方。
                    let hoverTime = Double(hoverX / max(width, 1)) * engine.duration
                    Text("\(timeText(hoverTime)) / \(timeText(engine.duration))")
                        .font(.system(size: DmText.t11))
                        .monospacedDigit()
                        .foregroundColor(Color.dmInk)
                        .padding(.horizontal, DmSpace.s8)
                        .padding(.vertical, DmSpace.s2)
                        .background(
                            RoundedRectangle(cornerRadius: DmRadius.r6)
                                .fill(Color.dmPanel3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DmRadius.r6)
                                        .strokeBorder(Color.dmLine2, lineWidth: DmLine.hairline)
                                )
                        )
                        .fixedSize()
                        .offset(x: min(max(hoverX, 40), width - 40) - width / 2, y: -26)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            // 钉底之后整体抬 3：悬停时轨道 [-6,0]、完全在条沿外，只向上展开。
            .offset(y: isEngaged ? -3 : 0)
        }
        .frame(height: 3)
        .overlay(interactionZone)
        .animation(.easeOut(duration: DmMotion.fast), value: isEngaged)
    }

    /// 命中区：12px 高、以 overlay 挂在 3px 线位上（不参与布局），上探出条外
    /// 7.5px、下探进行内 4.5px —— 好命中、也接得住从内容区边缘划过来的指针，
    /// 又不偷到封面的可点区域（封面距线位 6px 起）。
    private var interactionZone: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverX = point.x
                    case .ended: hoverX = nil
                    }
                }
                .gesture(seekGesture(width: geo.size.width))
                .disabled(!(engine?.hasQueue ?? false))
        }
        .frame(height: 12)
        .offset(y: -3)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let engine, engine.duration > 0 else { return }
                isScrubbing = true
                scrubFraction = min(max(0, value.location.x / width), 1)
            }
            .onEnded { _ in
                guard let engine else { return }
                engine.seek(to: scrubFraction * engine.duration)
                isScrubbing = false
            }
    }

    // MARK: 正在播

    private var nowPlaying: some View {
        HStack(spacing: DmSpace.s10) {
            DmCover(
                album: engine?.currentSong?.album ?? "",
                artist: engine?.currentSong?.albumArtist ?? "",
                size: 44
            )
            VStack(alignment: .leading, spacing: DmSpace.s2) {
                if let song = engine?.currentSong {
                    Text(song.title)
                        .font(.system(size: DmText.t13, weight: .semibold))
                        .foregroundColor(Color.dmInk)
                    Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: DmText.t12))
                        .foregroundColor(Color.dmInk3)
                } else {
                    Text("未在播放")
                        .font(.system(size: DmText.t13, weight: .medium))
                        .foregroundColor(Color.dmInk2)
                    Text("从曲库选一首开始")
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                }
                if let message = engine?.streamErrorMessage {
                    Text(message)
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmDanger)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 播放条只放一颗星（放不下 5 颗）：点亮即 5 星、再点清零，
            // 与列表共用同一个评分字段（原型「播放条 · 单星」）。
            if let song = engine?.currentSong {
                ratingButton(for: song)
            }
        }
        .frame(width: 300, alignment: .leading)
    }

    private func ratingButton(for song: AudioSong) -> some View {
        iconButton(
            "star",
            size: DmIcon.i16,
            active: song.rating > 0,
            filled: song.rating > 0
        ) {
            Task { await state.rate(song.id, to: song.rating > 0 ? 0 : 5) }
        }
    }

    // MARK: 控制钮

    private var controls: some View {
        HStack(spacing: DmSpace.s10) {
            iconButton("shuffle", size: DmIcon.i16, active: engine?.isShuffled == true) {
                engine?.toggleShuffle()
            }
            iconButton("skip-back", size: DmIcon.i18) {
                engine?.previous()
            }
            playButton
            iconButton("skip-forward", size: DmIcon.i18) {
                engine?.next()
            }
            iconButton("list-music", size: DmIcon.i16, active: state.showsQueue) {
                state.toggleQueue()
            }
        }
        .disabled(!(engine?.hasQueue ?? false))
        .opacity(engine?.hasQueue == true ? 1 : 0.5)
    }

    private var isPlayingNow: Bool { engine?.isPlaying == true }

    private var playButton: some View {
        Button {
            engine?.togglePlayPause()
        } label: {
            LucideIcon(isPlayingNow ? "pause" : "play", size: DmIcon.i16)
                .foregroundColor(Color.dmOnAccent)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(isPlayHovered ? Color.dmAccentFill2 : Color.dmAccentFill)
                )
        }
        .buttonStyle(.plain)
        .onHover { isPlayHovered = $0 }
        .animation(.easeInOut(duration: DmMotion.fast), value: isPlayHovered)
    }

    private func iconButton(
        _ name: String,
        size: CGFloat,
        active: Bool = false,
        filled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            LucideIcon(name, size: size, filled: filled)
                .foregroundColor(active ? Color.dmAccent2 : Color.dmInk2)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    // MARK: 音量

    private var volume: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon("volume-2", size: DmIcon.i16)
                .foregroundColor(Color.dmInk3)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.dmPanel3)
                    Rectangle()
                        .fill(Color.dmInk2)
                        .frame(width: geo.size.width * (engine?.volume ?? 0.7))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            engine?.setVolume(value.location.x / geo.size.width)
                        }
                )
            }
            .frame(width: 80, height: 4)
        }
        .frame(width: 200, alignment: .trailing)
    }
}

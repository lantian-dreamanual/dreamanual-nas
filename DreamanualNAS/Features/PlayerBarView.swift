import SwiftUI

/// 底部常驻播放条：通栏挂在窗口底部，不属于任何模块 —— 切到文件管理或
/// 系统状态，播放与进度不中断（产品定义第二节「外壳」）。
///
/// 规格照原型 `.player`：三栏（300 / 弹性 / 200）、进度条贴上沿拉满整窗宽
/// （4px，悬停 8px + 拇指 + 气泡）、播放钮 36 圆、音量条 80×4（填充 `ink-2`）。
/// 数据源是 `PlaybackEngine` —— 没有引擎（未连接）或队列为空时是**空态**：
/// 进度条压平、控件禁用、左侧写「未在播放」。
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
            Rectangle()
                .fill(Color.dmLine2)
                .frame(height: DmLine.hairline)

            progressLine

            HStack(spacing: DmSpace.s16) {
                nowPlaying
                Spacer(minLength: 0)
                controls
                Spacer(minLength: 0)
                volume
            }
            .padding(.horizontal, DmSpace.s16)
            .frame(height: 56)
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

    private var progressLine: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.dmPanel3)
                Rectangle()
                    .fill(isEngaged ? Color.dmAccent2 : Color.dmAccent)
                    .frame(width: width * shownFraction)
                if isEngaged {
                    Circle()
                        .fill(Color.dmInk)
                        .frame(width: 12, height: 12)
                        .offset(x: width * shownFraction - 6)
                }
                if let hoverX, !isScrubbing, let engine, engine.hasQueue {
                    // 气泡报悬停位置的时间（原型 `.p-line .tip`）。
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
                        .offset(x: min(max(hoverX, 40), width - 40), y: -26)
                }
            }
            .frame(height: isEngaged ? 8 : DmSpace.s4)
            .frame(maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .animation(.easeOut(duration: DmMotion.fast), value: isEngaged)
            .gesture(seekGesture(width: width))
            .disabled(!(engine?.hasQueue ?? false))
        }
        .frame(height: 8)
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
            RoundedRectangle(cornerRadius: DmRadius.r6)
                .fill(Color.dmPanel2)
                .frame(width: 44, height: 44)
                .overlay(
                    LucideIcon("music", size: DmIcon.i20)
                        .foregroundColor(Color.dmInk3)
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
        }
        .frame(width: 300, alignment: .leading)
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

    private func iconButton(_ name: String, size: CGFloat, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LucideIcon(name, size: size)
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

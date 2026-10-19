import SwiftUI

/// 侧栏底部的迷你播放卡（只在非听歌模块出现，2026-10-18 定）。
///
/// 一行 28：封面 20 + 歌名 + 暂停钮；**进度做成卡面淡主色底** —— 从左边铺到
/// 进度点、不画边缘竖线（深浅交界已经说清位置），也不额外占一条底线。
/// 高 28 比侧栏行（`h32`）薄一档，读作「附注」而不是第四个导航项。
///
/// **两个热区**：
/// - 按钮：切播放 / 暂停，留在当前页；
/// - 卡片其余位置：回听歌模块，落在离开时那一屏（`AppState.resumeMusic()`）。
///
/// 按钮用 `.overlay(alignment: .trailing)` 叠在卡片手势之上。写成「按钮套在
/// 卡片 Button 里」时外层会吞掉内层点击 —— 同一个命中区只有一个手势胜出，
/// 独立成层才各自吃事件。
///
/// 按钮三态：播放中 `pause`、暂停 `play`、队列到头 `list-start`（点回第一首重播）。
/// 三态都从 `PlaybackEngine` 读，不由点击顺序给；只在卡片这一处特判会出现
/// 「图标换了、空格按了没反应」。
struct MiniPlayerView: View {
    let engine: PlaybackEngine
    let onOpen: () -> Void

    @State private var isHovered = false

    private var song: AudioSong? { engine.currentSong }

    /// 进度比例。到队尾时铺满 —— 「这一轮走完了」由底色先说，按钮换 `list-start`
    /// 才有上下文；只换图标、底色停在 99%，看着像卡住了。
    private var fraction: Double {
        if engine.isAtQueueEnd { return 1 }
        guard engine.duration > 0 else { return 0 }
        return min(1, max(0, engine.currentTime / engine.duration))
    }

    private var buttonIcon: String {
        if engine.isAtQueueEnd { return "list-start" }
        return engine.isPlaying ? "pause" : "play"
    }

    private var buttonHelp: String {
        if engine.isAtQueueEnd { return "从头播放" }
        return engine.isPlaying ? "暂停" : "播放"
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: DmRadius.r6)
                .fill(isHovered ? Color.dmPanel3 : Color.dmPanel3.opacity(0.45))

            // 进度块：绝对铺满卡高、只到进度点。挂 GeometryReader 是为了按卡的
            // 实际宽度取比例 —— 侧栏宽度将来若变，这里不用跟着改。
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.dmAccent.opacity(0.18))
                    .frame(width: geo.size.width * fraction)
            }

            content
        }
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r6))
        .frame(height: DmControl.h28)
        .contentShape(RoundedRectangle(cornerRadius: DmRadius.r6))
        .onTapGesture(perform: onOpen)
        .overlay(alignment: .trailing) { playButton }
        .trackingHover($isHovered)
        // 换图标时给一点淡入淡出，别硬切（与卡片底色同一档时长）。
        .animation(.easeOut(duration: DmMotion.fast), value: engine.isPlaying)
        .animation(.easeOut(duration: DmMotion.fast), value: engine.isAtQueueEnd)
    }

    private var content: some View {
        HStack(spacing: DmSpace.s4) {
            DmCover(
                album: song?.album ?? "",
                artist: song?.albumArtist ?? "",
                folder: song?.folder ?? "",
                size: 20,
                // 20 见方再用 r-8 就成了半圆（曲库 28 / 播放条 44 才是 r-8）。
                cornerRadius: DmRadius.r4
            )
            Text(song?.title ?? "")
                .font(.system(size: DmText.t11, weight: .medium))
                .foregroundColor(Color.dmInk)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, DmSpace.s8)
        // 右侧让给按钮（20 + 4 间距）：文字区止于按钮左沿，不顶到它底下。
        .padding(.trailing, DmSpace.s24)
    }

    private var playButton: some View {
        Button {
            // 队尾那一态由引擎内部转成「回第一首重播」—— 这里不重复判断。
            engine.togglePlayPause()
        } label: {
            LucideIcon(buttonIcon, size: DmIcon.i12)
                .foregroundColor(Color.dmInk2)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, DmSpace.s4)
        .help(buttonHelp)
    }
}

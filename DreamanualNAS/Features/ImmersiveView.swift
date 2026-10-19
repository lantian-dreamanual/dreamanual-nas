import SwiftUI

/// 沉浸模式（原型 `data-screen="immersive"`）。
///
/// 从播放条的封面或歌名进来、再点一次或按 Esc 退出。**只收掉侧栏**，播放条原样
/// 留在底下 —— 控制、进度、气泡与曲库状态是同一个组件、同一份数据。
///
/// 底是一张放大的封面：等比撑满 + 重高斯模糊 + 一层压暗，保证前景文字对比度；
/// 底缘再从透明渐到播放条的 panel 色（网易云口径），让模糊封面自然接上播放条。
/// 没有封面（或还没取回来）时退回纯色底 —— 原型那层渐变是占位美术，不落进实现。
/// 左封面 280、右信息栏 380，间距 56（容器级留白，第 5 节按布局值保留）。
///
/// 歌词区两态（第八节「沉浸模式」）：**有歌词**就逐行渲染、当前行高亮并跟着进度
/// 居中滚、离当前行越远越淡；**没有歌词**不留白板，换成「未匹配到歌词 + 接下来
/// 播放」—— 库里带内嵌歌词的只有约 0.3%，所以「没有歌词」是常态，不配警告色。
///
/// 🔴 这一屏是**远看**的：字号整体比常规页面大一档到两档（歌名 34、歌词 17/20），
/// 常规页的 13/12 在这一屏看着费劲（2026-10-13 用户点名）。要改这一屏的字号，
/// 照「第八节 · 沉浸模式」那张表改，别按常规页面对齐。
struct ImmersiveView: View {
    @Environment(AppState.self) private var state

    /// 歌词：`loaded` 为 false 表示还在取（这一档什么都不画，不闪一下「未匹配到」）。
    @State private var lyrics: Lyrics?
    @State private var lyricsLoaded = false
    @State private var coverImage: NSImage?
    @State private var isNextHovered = false

    /// 封面与信息栏之间。56 是容器级留白（间距档只到 24），按布局值保留。
    private static let columnGap: CGFloat = 56

    private var engine: PlaybackEngine? { state.playback }
    private var song: AudioSong? { engine?.currentSong }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 底挂在 background：随内容边界走，不参与布局 —— 底要是当 ZStack 的
                // 布局子视图（首版），它比提案高出一截就把播放条整个挤出窗外。
                .background { backdrop }
                .overlay(alignment: .topTrailing) { closeButton }
                .clipped()

            // 层内播放条（第 5 稿）：与层同宽、铺满整窗。普通模式那条只占主区宽
            // （少 220），宽度差用「同一组件的另一个实例」补 —— 播放状态、进度、
            // 音量同源，悬停与进度气泡各算各的（临时 UI，切过来重置一次无妨）。
            PlayerBarView(engine: state.playback)
        }
        // 歌词跟着歌走。`nil` 的 id 会让 task 立刻结束，正好当「没有歌」处理。
        .task(id: song?.id) { await loadLyrics() }
        .task(id: coverTaskKey) { await loadCover() }
        // Esc 退出（原型只写了右上角的关闭钮，键盘退出是 macOS 上的惯例）。
        .onExitCommand { state.closeImmersive() }
    }

    @ViewBuilder
    private var content: some View {
        if let song {
            HStack(alignment: .center, spacing: Self.columnGap) {
                coverArt
                info(song)
            }
            .padding(DmSpace.s24)
        } else {
            Text("队列空了")
                .font(.system(size: DmText.t15))
                .foregroundColor(Color.dmInk3)
        }
    }

    // MARK: 底

    /// 封面等比撑满 + 重高斯模糊 + 一层压暗。GeometryReader 把图钉在容器
    /// 边界内 —— `scaledToFill` 裸放在这里会按图片自身的宽高比把容器撑高。
    private var backdrop: some View {
        ZStack {
            Color.dmBg
            if let coverImage {
                GeometryReader { geo in
                    Image(nsImage: coverImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        // 放大 1.3 再模糊：原型的底是 `inset:-15%`，不放大时模糊会
                        // 从视图边界外取到透明像素，四边糊出一圈灰。放大后边界落在
                        // 视野外，外面那层 `.clipped()` 收掉。
                        .scaleEffect(1.3)
                        .blur(radius: 80)
                        .saturation(1.15)
                        .opacity(0.45)
                }
            }
            // 压暗层：原型是 rgba(10,10,10,.62)，这里用 bg 色压同样的透明度。
            Color.dmBg.opacity(0.62)
            // 底缘渐隐（网易云口径，2026-10-13 用户点名）：从透明渐到播放条的
            // panel 色，模糊封面在底部自然接上播放条、不再有一条硬边。渐变高度
            // 140 是布局值（视觉过渡带，无令牌可取）。渐变层在压暗层之上、
            // 内容之下（backdrop 整体是 background）。
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [Color.dmPanel.opacity(0), Color.dmPanel],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)
            }
        }
    }

    // MARK: 封面

    private var coverArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DmRadius.r12)
                .fill(Color.dmPanel2)
            LucideIcon("music", size: DmIcon.i64)
                .foregroundColor(Color.dmInk3)
            if let coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: DmRadius.r12))
            }
        }
        .frame(width: 280, height: 280)
        .dmShadowModal()
    }

    // MARK: 信息栏

    private func info(_ song: AudioSong) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(song.title)
                .font(.system(size: DmText.t34, weight: .bold))
                .kerning(-0.68)
                .foregroundColor(Color.dmInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !song.artist.isEmpty {
                Button {
                    Task { await state.showSongs(byArtist: song.artist) }
                } label: {
                    Text(song.artist)
                        .font(.system(size: DmText.t17))
                        .foregroundColor(Color.dmAccent2)
                }
                .buttonStyle(.plain)
                .padding(.top, DmSpace.s8)
            }

            Text(metaLine(song))
                .font(.system(size: DmText.t13))
                .foregroundColor(Color.dmInk3)
                .lineLimit(1)
                .padding(.top, DmSpace.s8)

            lyricsArea
        }
        .frame(width: 380, alignment: .leading)
    }

    private func metaLine(_ song: AudioSong) -> String {
        [song.album, song.yearText, song.genre, song.durationText]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var closeButton: some View {
        // 收起（2026-10-18 用户点名）：这一屏是「从底下滑上来」的覆盖层，
        // 退出动作就是往下收 —— `arrow-down-to-line` 说的是那个动作，
        // `x` 说的是「关掉一个东西」，在整窗覆盖层上语义对不上。
        //
        // 落位与照片查看器统一（同日）：按钮中线对齐窗口题头行 —— 28 高的钮
        // top 6 → 中线 20，与查看器 40 高顶栏的中线一致；右边距 16。图形 18：
        // 这一屏唯一的常驻控件，比工具条里的次级动作大一号。
        IconButton(iconName: "arrow-down-to-line", iconSize: DmIcon.i18) { state.closeImmersive() }
            .help("收起（Esc）")
            .padding(.top, DmSpace.s6)
            .padding(.trailing, DmSpace.s16)
    }

    // MARK: 歌词

    @ViewBuilder
    private var lyricsArea: some View {
        if let lyrics, !lyrics.isEmpty {
            lyricsList(lyrics)
        } else if lyricsLoaded {
            nextUp
        }
    }

    /// 当前行号。纯文本歌词（整篇没有时间轴）回 nil，那时一行都不高亮。
    private var activeLine: Int? {
        guard let lyrics, lyrics.hasTimeline, let engine else { return nil }
        return lyrics.activeIndex(at: engine.currentTime)
    }

    /// 离当前行越远越淡（2026-10-13 用户点名：远处的行别跟当前行抢视线）：
    /// 每往外一行掉 0.25、压到 0.2 为止，当前行满档。整篇没有时间轴（`activeLine`
    /// 为 nil）时不衰减 —— 那时没有「当前行」可参照，一行都不该被压暗。
    private func lyricOpacity(_ index: Int) -> Double {
        guard let activeLine else { return 1 }
        return max(0.2, 1 - 0.25 * Double(abs(index - activeLine)))
    }

    private func lyricsList(_ lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DmSpace.s12) {
                    ForEach(lyrics.lines.indices, id: \.self) { index in
                        Text(lyrics.lines[index].text)
                            .font(.system(
                                size: index == activeLine ? DmText.t20 : DmText.t17,
                                weight: index == activeLine ? .semibold : .regular
                            ))
                            .foregroundColor(index == activeLine ? Color.dmAccent2 : Color.dmInk3)
                            .opacity(lyricOpacity(index))
                            .fixedSize(horizontal: false, vertical: true)
                            // 行盒下限 30（放在 fixedSize 之后才有意义）：单行歌词都占
                            // 同一档高，当前行在 17 / 20 之间换档时整块不跟着抖
                            //（20 的自然行高不到 30、撑不破；折行的行按实际高度走）。
                            .frame(minHeight: 30, alignment: .leading)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DmSpace.s4)
            }
            .frame(height: 300)
            .padding(.top, DmSpace.s24)
            .onChange(of: activeLine) { _, line in
                guard lyrics.hasTimeline, let line else { return }
                withAnimation(.easeOut(duration: DmMotion.base)) {
                    proxy.scrollTo(line, anchor: .center)
                }
            }
        }
    }

    /// 没有歌词时的常态：说明行 + 牌头 + 可点跳的下一首。
    private var nextUp: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DmSpace.s8) {
                LucideIcon("info", size: DmIcon.i14)
                    .foregroundColor(Color.dmInk3)
                Text("未匹配到歌词")
                    .font(.system(size: DmText.t13))
                    .foregroundColor(Color.dmInk3)
            }

            // 牌头：顶上一条发丝，上下各 16（原型 `.nx-cap` 的 margin/padding 16）。
            Rectangle()
                .fill(Color.dmLine)
                .frame(height: DmLine.hairline)
                .padding(.top, DmSpace.s16)

            Text(engine?.nextSong == nil ? "队列到此为止" : "接下来播放")
                .font(.system(size: DmText.t12))
                .kerning(0.96)
                .foregroundColor(Color.dmInk3)
                .padding(.top, DmSpace.s16)

            if let next = engine?.nextSong {
                nextUpRow(next)
                    .padding(.top, DmSpace.s10)
            } else {
                Text("这一首是队列的最后一首")
                    .font(.system(size: DmText.t13))
                    .foregroundColor(Color.dmInk3)
                    .padding(.top, DmSpace.s10)
            }
        }
        .padding(.top, DmSpace.s24)
    }

    private func nextUpRow(_ next: AudioSong) -> some View {
        Button {
            engine?.next()
        } label: {
            HStack(spacing: DmSpace.s12) {
                ZStack {
                    RoundedRectangle(cornerRadius: DmRadius.r6)
                        .fill(Color.dmInk.opacity(0.1))
                    LucideIcon("music", size: DmIcon.i16)
                        .foregroundColor(Color.dmInk3)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: DmSpace.s2) {
                    Text(next.title)
                        .font(.system(size: DmText.t17, weight: .semibold))
                        .foregroundColor(Color.dmInk)
                        .lineLimit(1)
                    Text([next.artist, next.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: DmText.t13))
                        .foregroundColor(Color.dmInk3)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(next.durationText)
                    .font(.system(size: DmText.t13))
                    .monospacedDigit()
                    .foregroundColor(Color.dmInk3)
            }
            .padding(DmSpace.s10)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r10)
                    .fill(Color.dmInk.opacity(isNextHovered ? 0.1 : 0.06))
            )
        }
        .buttonStyle(.plain)
        .onHover { isNextHovered = $0 }
    }

    // MARK: 取数

    private var coverTaskKey: String {
        guard let song, !song.album.isEmpty else { return "" }
        return "\(song.folder)\u{1}\(song.album)\u{1}\(song.albumArtist)"
    }

    private func loadCover() async {
        guard let song, !song.album.isEmpty, let manager = state.sessionManager else {
            coverImage = nil
            return
        }
        let data = await CoverStore.shared.cover(
            manager: manager,
            album: song.album,
            artist: song.albumArtist,
            folder: song.folder,
            // 280 见方的封面卡：要原图，120×120 的缩略图放大到这个尺寸会糊。
            highRes: true
        )
        coverImage = data.flatMap(NSImage.init(data:))
    }

    private func loadLyrics() async {
        lyricsLoaded = false
        guard let song, let manager = state.sessionManager else {
            lyrics = nil
            lyricsLoaded = true
            return
        }
        let result = await LyricsStore.shared.lyrics(manager: manager, song: song)
        // 取词这几秒里用户可能已经切歌了 —— 只让当前这首的结果落地。
        guard song.id == self.song?.id else { return }
        lyrics = result
        lyricsLoaded = true
    }
}

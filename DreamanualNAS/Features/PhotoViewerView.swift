import AppKit
import AVFoundation
import SwiftUI

/// 照片查看器（批 1 后半）。
///
/// 与听歌的沉浸屏是**同一套整窗覆盖层**（第八节「沉浸模式」）：从窗口底部滑入、
/// 层不透明、退出只留右上角一枚往下收的钮。差异只有两处 —— 照片不是播放场景，
/// 层底没有播放条；大图右侧多了 300 宽的信息栏。
///
/// 顶栏 40（28 控件 + 上下 6）：左边文件名与「当天第几张」，右边动作组。三点是
/// 窗口 chrome、位置固定，所以顶栏内容要从 80 起，中线才对得上三点中线。
///
/// 翻页走 `←` `→`，序列是「全部条目按天摊平」——条目全量在手，翻页纯序列运算。
///
/// **视频**（2026-10-20 加）：同一个查看器，`stage` 换成播放器。取流走
/// `StreamLoader`（照片族要 `X-SYNO-TOKEN`、直连要放行自签证书，AVPlayer 自己
/// 发不出来），地址是 `SYNO.FotoTeam.Streaming`；服务端按 Range 裁，拖进度有基础。
/// 播放前先铺缩略图当海报，点一下才开始 —— 翻到视频就出声不合适。
struct PhotoViewerView: View {
    @Environment(AppState.self) private var state

    /// 信息栏默认展开：它是点开一张图之后最想知道的东西（什么时候拍的、什么机器）。
    @State private var showsInfo = true
    /// m 档先铺上、xl 换掉 —— 本地库取一张 1280 的长边要等一拍，先给个影。
    @State private var preview: NSImage?
    @State private var full: NSImage?
    @State private var isStepping = false
    /// `←` `→` 用本机事件监听：覆盖层里没有文本输入，全局拦这两个键不会误伤。
    @State private var keyMonitor: Any?
    /// 描述行内编辑态（规划第四节 8：悬停出铅笔、点开变行内表单）。
    @State private var isEditingDescription = false
    /// 编辑中的草稿。进编辑态时从 `item.note` 复制，取消即弃。
    @State private var descriptionDraft = ""
    /// 进编辑态时的原值：失焦提交走脏检查，没改字就不发请求。
    @State private var descriptionOriginal = ""
    /// 编辑框焦点：进编辑态即聚焦，回车直接提交。
    @FocusState private var isDescriptionFieldFocused: Bool
    /// 拍摄时间的编辑态：点铅笔弹日历浮层（图形日历 + 时分），改完在浮层里
    /// 取消 / 保存。原先是手输一整行 `2026-10-18 20:46`，用户反馈不好用。
    @State private var isEditingTime = false
    @State private var timeDraftDate = Date()
    /// 浮层里时分输入框的字（`20:46`）。有改动就并进 `timeDraftDate`，
    /// 日历选日时才能带上最新时分。
    @State private var timeText = ""

    // 视频
    @State private var player: AVPlayer?
    @State private var videoLoader: StreamLoader?
    @State private var videoError: String?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0
    @State private var timeObserver: Any?
    @State private var statusObservation: NSKeyValueObservation?
    /// 音量。曲库播放条同样只在内存里（`PlaybackEngine.volume` 默认 0.7、不落盘），
    /// 这里跟它对齐：查看器内换条目不变，收起再开回默认。
    @State private var volume: Double = 0.7
    /// 静音前那一档。点一下喇叭静音、再点回原档 —— 不回到固定值，免得每次都重调。
    @State private var lastAudibleVolume: Double = 0.7

    private var library: PhotoLibrary { state.photos }
    private var item: PhotosAPI.Item? { library.viewingItem }
    private var isVideo: Bool { item?.isVideo ?? false }

    /// 顶栏内容起点。三点区约 66 宽，留到 80 之后才不压住。
    private static let titleInset: CGFloat = 80
    private static let infoWidth: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                stage
                if showsInfo { infoPanel }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dmBg)
        // 规范里的「层顶边上投阴影」两端都没落：层铺满整窗，静止时顶边就在窗口
        // 边界上、阴影被裁掉看不见，只有滑入动画的一瞬可见 —— 沉浸屏同样没画，
        // 与它保持一致（真机上滑入过程也没有可感知的缺失）。
        .task(id: item?.id) {
            exitEditingIfNeeded(item?.id ?? 0)
            await load()
            // 冒烟通路（`DM_UI=photovideo`）：查看器一开就播，省掉「点一下海报」
            // 这一步。真机照常从海报开始。
            if state.photoAutoStartVideo, let item, item.isVideo {
                state.photoAutoStartVideo = false
                await prepareVideo(item)
                if state.photoSmokeMute {
                    state.photoSmokeMute = false
                    setVolume(0)
                    NSLog("[photos] 冒烟：静音态 音量=%.2f", volume)
                }
            }
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            removeKeyMonitor()
            teardownVideo()
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: DmSpace.s8) {
            Text(item?.filename ?? "")
                .font(.system(size: DmText.t13, weight: .semibold))
                .foregroundColor(Color.dmInk)
                .lineLimit(1)
                .truncationMode(.middle)

            if let spot = item.flatMap({ library.position(of: $0) }) {
                Text("\(spot.index) / \(spot.count)")
                    .font(.system(size: DmText.t11))
                    .monospacedDigit()
                    .foregroundColor(Color.dmInk3)
            }

            Spacer(minLength: DmSpace.s12)

            // 右键在独占整窗的查看器里不是自然动作，所以这里必须给按钮（规划第四节
            // 第 5 条）。跳过去是单向的：切到文件管理、打开所在目录并选中这张。
            IconButton(iconName: "folder-open", label: "在文件夹中显示") {
                guard let item else { return }
                Task { await state.revealInFiles(item) }
            }
            .help("在文件夹中显示")

            IconButton(iconName: "panel-right",
                       label: showsInfo ? "收起信息栏" : "展开信息栏") {
                withAnimation(.easeInOut(duration: DmMotion.base)) { showsInfo.toggle() }
            }
            .help(showsInfo ? "收起信息栏" : "展开信息栏")

            IconButton(iconName: "arrow-down-to-line", iconSize: DmIcon.i18, label: "收起") {
                close()
            }
            .help("收起（Esc）")
        }
        .frame(height: 40)
        .padding(.leading, Self.titleInset)
        .padding(.trailing, DmSpace.s16)
    }

    // MARK: - 大图

    private var stage: some View {
        GeometryReader { geo in
            ZStack {
                if isVideo {
                    videoStage(geo.size)
                } else if let image = full ?? preview {
                    let box = Self.fitted(image.size, in: geo.size)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: box.width, height: box.height)
                        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r12))
                        .dmShadowModal()
                } else {
                    LucideIcon("loader", size: DmIcon.i24)
                        .foregroundColor(Color.dmInk3)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 视频

    /// 视频画面铺满可用区（黑底、等比留边），控制条压在画面下沿。
    ///
    /// 海报用缩略图（`Thumbnail` 对 MOV 出的是首帧），点一下才建播放器 —— 翻到
    /// 一段视频就自动出声不合适，页游式自动播也没必要。
    @ViewBuilder
    private func videoStage(_ size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DmRadius.r12)
                .fill(Color.black)

            if let player {
                VideoSurface(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: DmRadius.r12))
            } else if let poster = preview {
                Image(nsImage: poster)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: DmRadius.r12))
                    .overlay {
                        Color.black.opacity(0.25)
                            .clipShape(RoundedRectangle(cornerRadius: DmRadius.r12))
                    }
            }

            if let videoError {
                VStack(spacing: DmSpace.s8) {
                    LucideIcon("triangle-alert", size: DmIcon.i24)
                        .foregroundColor(Color.dmInk3)
                    Text(videoError)
                        .font(.system(size: DmText.t12))
                        .foregroundColor(Color.dmInk2)
                        .multilineTextAlignment(.center)
                }
                .padding(DmSpace.s24)
            } else if player == nil {
                // 海报态的大播放键：白色压半透明黑，任何画面都看得见。
                Button(action: startVideo) {
                    LucideIcon("play", size: DmIcon.i24, filled: true)
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("播放")
            }

            if player != nil {
                VStack {
                    Spacer(minLength: 0)
                    videoControls
                }
                .padding(DmSpace.s16)
            }
        }
        .frame(width: size.width, height: size.height)
        .padding(DmSpace.s24)
    }

    /// 控制条：播放 / 暂停 + 当前时间 + 进度线 + 总长 + 音量。
    ///
    /// 白字白线压在 `black 55%` 上 —— 与网格里的视频角标同一口径（那是唯一
    /// 一处「压在画面上」的常驻文字，跟着它走比另造一套强）。
    private var videoControls: some View {
        HStack(spacing: DmSpace.s12) {
            IconButton(iconName: isPlaying ? "pause" : "play",
                       iconSize: DmIcon.i14,
                       label: isPlaying ? "暂停" : "播放") {
                togglePlay()
            }
            .help(isPlaying ? "暂停（空格）" : "播放（空格）")

            Text(Self.timeText(currentTime))
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(.white)

            videoProgress

            Text(Self.timeText(duration))
                .font(.system(size: DmText.t11))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.7))

            volumeControl
        }
        .padding(.horizontal, DmSpace.s12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r10)
                .fill(Color.black.opacity(0.55))
        )
    }

    /// 音量：喇叭（点一下静音 / 还原）+ 80×4 细轨。
    ///
    /// 形态照曲库播放条（`PlayerBarView.volume`）：视觉 80×4、滑块是 3×10 的亮条
    /// 骑在填充端、命中区抬到整行 28（4pt 的细线基本点不中）。配色换白色 —— 这一条
    /// 压在画面上，与进度线同一套（轨道 `white 22%`、填充与滑块纯白）。
    private var volumeControl: some View {
        HStack(spacing: DmSpace.s8) {
            IconButton(iconName: isMuted ? "volume-x" : "volume-2",
                       iconSize: DmIcon.i14,
                       label: isMuted ? "取消静音" : "静音") {
                toggleMute()
            }
            .help(isMuted ? "取消静音" : "静音")

            GeometryReader { geo in
                let width = geo.size.width
                let fill = width * volume
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(height: 3)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: fill, height: 3)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: DmLine.bold, height: DmIcon.i10)
                        .offset(x: max(0, min(fill - DmLine.bold / 2,
                                              width - DmLine.bold / 2)))
                }
                // 与曲库那条同一个坑：`GeometryReader` 默认把子视图钉左上角，
                // 撑满后按 `.leading` 落位才是「水平靠左、垂直居中」。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            setVolume(Double(value.location.x / max(width, 1)))
                        }
                )
            }
            .frame(width: 80, height: DmControl.h28)
        }
    }

    private var videoProgress: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = isScrubbing ? scrubFraction
                : (duration > 0 ? min(1, currentTime / duration) : 0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: 3)
                Capsule()
                    .fill(Color.white)
                    .frame(width: width * fraction, height: 3)
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .offset(x: width * fraction - 5)
                    .opacity(isScrubbing ? 1 : 0)
            }
            .frame(height: 12)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        isScrubbing = true
                        scrubFraction = min(max(0, value.location.x / max(width, 1)), 1)
                    }
                    .onEnded { _ in
                        seek(to: scrubFraction * duration)
                        isScrubbing = false
                    }
            )
        }
        .frame(height: 12)
    }

    private static func timeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func startVideo() {
        guard let item, player == nil else { return }
        Task { await prepareVideo(item) }
    }

    private func prepareVideo(_ item: PhotosAPI.Item) async {
        guard let manager = state.sessionManager else { return }
        do {
            // 重登会换 sid —— 每次开播取一次快照，别缓存（与曲库那条同理）。
            let endpoint = try await manager.fileEndpoint
            let loader = StreamLoader(videoItemID: item.id, endpoint: endpoint)
            let ext = StreamLoader.videoExtension(item.filename)
            guard let url = URL(string: "\(StreamLoader.scheme)://video/\(item.id).\(ext)") else {
                throw PlaybackError.badAsset
            }
            let asset = AVURLAsset(url: url)
            loader.attach(to: asset)
            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            player.actionAtItemEnd = .pause
            // 换条目重建播放器时把音量带上：`AVPlayer` 新实例一律 1.0。
            player.volume = Float(volume)

            videoLoader = loader
            self.player = player
            installTimeObserver(on: player)
            statusObservation = playerItem.observe(\.status, options: [.new]) { observed, _ in
                Task { @MainActor in
                    switch observed.status {
                    case .readyToPlay:
                        let seconds = CMTimeGetSeconds(observed.duration)
                        if seconds.isFinite, seconds > 0 { duration = seconds }
                    case .failed:
                        videoError = observed.error?.localizedDescription ?? "这段视频打不开。"
                    default:
                        break
                    }
                }
            }
            player.play()
            isPlaying = true
            NSLog("[photos] 视频开播 %d %@", item.id, item.filename)
            // 取流是异步的：建好播放器不代表解码跑起来了（地址错、UTI 错都会在
            // 几秒后才掉 failed）。隔三秒把位置与状态打进日志，真机验收看这一行。
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let seconds = CMTimeGetSeconds(player.currentTime())
            let total = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
            NSLog("[photos] 视频状态 控件=%ld 位置=%.1fs / %.1fs 错误=%@",
                  player.timeControlStatus.rawValue, seconds.isFinite ? seconds : -1,
                  total.isFinite ? total : -1,
                  player.currentItem?.error?.localizedDescription ?? "无")
        } catch {
            videoError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSLog("[photos] 视频开播失败：%@", error.localizedDescription)
        }
    }

    /// 0.25 秒一拍够用：进度线与时间都按它刷，拖动时由 `isScrubbing` 让位。
    private func installTimeObserver(on player: AVPlayer) {
        removeTimeObserver()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            Task { @MainActor in
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite, !isScrubbing { currentTime = seconds }
                isPlaying = player.timeControlStatus == .playing
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func togglePlay() {
        guard let player else { return startVideo() }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - 音量

    private var isMuted: Bool { volume <= 0.001 }

    private func toggleMute() {
        if isMuted {
            // 静音前拖到 0 的那一档已经没了，回一个听得见的低位，不是回到 0。
            setVolume(max(lastAudibleVolume, 0.05))
        } else {
            lastAudibleVolume = volume
            setVolume(0)
        }
    }

    private func setVolume(_ value: Double) {
        let clamped = min(max(0, value), 1)
        volume = clamped
        if clamped > 0.001 { lastAudibleVolume = clamped }
        player?.volume = Float(clamped)
    }

    /// 换条目 / 收起查看器都要拆干净 —— 播放器留着会在后台继续出声。
    private func teardownVideo() {
        removeTimeObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        videoLoader = nil
        videoError = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isScrubbing = false
    }

    /// 等比缩到容器内（四周留 `s24`），返回图片自身的显示尺寸。
    ///
    /// 不用 `scaledToFit` 一把梭：那样布局框是整块容器，圆角与阴影会跑到容器边界上，
    /// 图四周的留白里就裁不出圆角。
    private static func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        let available = CGSize(width: max(1, box.width - DmSpace.s24 * 2),
                               height: max(1, box.height - DmSpace.s24 * 2))
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(available.width / size.width, available.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    // MARK: - 信息栏

    /// 五段：文件 / 拍摄 / 相机 / 位置 / 内容。
    ///
    /// **位置一段这版不渲染**：条目上没有现成的地点值，要走 `Geocoding` v1 查，
    /// 而那个接口还没实测（规划第六节第 4 条）。取不到就整段不占位 —— 留一个
    /// 「位置：—」比不写更让人以为是没拍到。
    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DmSpace.s20) {
                if let item {
                    section("文件") {
                        row("大小", PhotoDate.bytes(item.filesize))
                        row("类型", item.kindText)
                        if let pixel = item.pixelText {
                            row("尺寸", "\(pixel) 像素")
                        }
                    }

                    section("拍摄") {
                        timeRow(item)
                    }

                    if !item.exif.isEmpty {
                        section("相机") {
                            if let value = item.exif.camera { row("机身", value) }
                            if let value = item.exif.lens { row("镜头", value) }
                            if let value = item.exif.aperture { row("光圈", value) }
                            if let value = item.exif.exposure { row("快门", value) }
                            if let value = item.exif.iso { row("感光度", value) }
                            if let value = item.exif.focal { row("焦距", value) }
                        }
                    }

                    section("内容") {
                        row("评分") {
                            // 信息栏里常驻可点（与曲库行悬停才亮不同：这里
                            // 一屏只有这一行评分，不需要「先悬停再点」）。
                            RatingStars(rating: item.rating, revealsEmpty: true,
                                        onRate: { value in
                                            Task { await state.setPhotoRating(value) }
                                        })
                        }
                        descriptionRow(item)
                    }
                }
            }
            .padding(DmSpace.s20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.infoWidth)
        .background(Color.dmPanel)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.dmLine2).frame(width: DmLine.base)
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DmSpace.s8) {
            Text(title)
                .font(.system(size: DmText.t11, weight: .bold))
                .foregroundColor(Color.dmInk3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 可编辑行的只读态：值 + 悬停浮出的铅笔。
    ///
    /// 不挂 `row()` —— 它尾端的 Spacer 会跟铺满的值区平分剩余宽度，铅笔落到
    /// 行中段而不是右缘（2026-10-21 用户指出）。
    private func editableRow(label: String, text: String?, placeholder: String,
                             onEdit: @escaping () -> Void) -> some View {
        HStack(spacing: DmSpace.s12) {
            rowLabel(label)
            EditableValueRow(text: text, placeholder: placeholder, onEdit: onEdit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 可编辑行的编辑态：标签列不动、输入框吃剩余宽度、两枚出口在框外右侧。
    ///
    /// 两枚图标放框外是用户定的：框内尾端那个位置是搜索框清除钮的语义位，
    /// ✗ 放进去会被读成「清空输入框」。失焦也算提交，但要先让一拍 ——
    /// 点 ✗ / ✓ 是先失焦后跑按钮动作，不等这一拍就会「点了取消照样写回去」。
    private func inlineEditor(label: String,
                              text: Binding<String>,
                              focus: FocusState<Bool>.Binding,
                              placeholder: String,
                              isActive: @escaping () -> Bool,
                              onCommit: @escaping () -> Void,
                              onCancel: @escaping () -> Void) -> some View {
        HStack(spacing: DmSpace.s12) {
            rowLabel(label)
            HStack(spacing: DmSpace.s6) {
                TextField(placeholder, text: text)
                    .focused(focus)
                    .formFieldRow()
                    .frame(maxWidth: .infinity)
                    .onSubmit(onCommit)
                    .onChange(of: focus.wrappedValue) { _, focused in
                        guard !focused else { return }
                        Task {
                            try? await Task.sleep(for: .milliseconds(120))
                            guard isActive(), !focus.wrappedValue else { return }
                            onCommit()
                        }
                    }
                IconButton(iconName: "x", compact: true, label: "取消", action: onCancel)
                IconButton(iconName: "check", compact: true, label: "保存", action: onCommit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 描述行：悬停出铅笔，点开变行内表单。保存走 `state.setPhotoDescription`，
    /// 成功就地改 `item.note`（写回通道 2026-10-21 实测定案：id 方括号串）。
    /// 出口四条：回车 / 失焦 / ✓ 提交，Esc / ✗ 取消；失焦提交走脏检查，
    /// 没改字只退出、不发请求。
    @ViewBuilder
    private func descriptionRow(_ item: PhotosAPI.Item) -> some View {
        if isEditingDescription {
            inlineEditor(label: "描述", text: $descriptionDraft,
                         focus: $isDescriptionFieldFocused,
                         placeholder: "给这张写点什么",
                         isActive: { isEditingDescription },
                         onCommit: { commitDescription() },
                         onCancel: { cancelDescription() })
        } else {
            editableRow(label: "描述", text: item.note, placeholder: "写点什么…") {
                descriptionDraft = item.note ?? ""
                descriptionOriginal = item.note ?? ""
                isEditingDescription = true
                isDescriptionFieldFocused = true
            }
        }
    }

    /// 拍摄时间行。点铅笔弹日历浮层：日期用自绘月历，时分是一枚 72 宽的
    /// 自有小输入框（只填 `20:46`）—— 原生 `stepperField` 不吃宽度提案，
    /// 加宽外壳只是留白，文字照样显示不全（2026-10-21 用户两轮截图）。
    /// 浮层点外面或按 Esc 收起，等同取消（草稿丢弃、不发请求）。
    @ViewBuilder
    private func timeRow(_ item: PhotosAPI.Item) -> some View {
        if isEditingTime {
            HStack(spacing: DmSpace.s12) {
                rowLabel("时间")
                HStack(spacing: DmSpace.s8) {
                    Text(PhotoDate.stamp(timeDraftDate))
                        .font(.system(size: DmText.t13))
                        .foregroundColor(Color.dmInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    LucideIcon("calendar-days", size: DmIcon.i14)
                        .foregroundColor(Color.dmInk3)
                }
                .formFieldRow()
                .frame(maxWidth: .infinity)
                .popover(isPresented: $isEditingTime, arrowEdge: .bottom) {
                    timePicker(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            editableRow(label: "时间", text: PhotoDate.stamp(item.time),
                        placeholder: "未设置") {
                timeDraftDate = item.time
                timeText = PhotoDate.clock(item.time)
                isEditingTime = true
            }
        }
    }

    /// 日历浮层。时分输入有改动就并进草稿（日历选日的「保留时分」才拿得到
    /// 新值）；解析不了先不动 —— 提交时统一校验并提示。
    private func timePicker(_ item: PhotosAPI.Item) -> some View {
        VStack(alignment: .leading, spacing: DmSpace.s16) {
            TimeCalendarGrid(selection: $timeDraftDate)

            HStack(spacing: DmSpace.s8) {
                Text("时间")
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk2)
                TextField("20:46", text: $timeText)
                    .formFieldRow()
                    .frame(width: 72)
                    .onSubmit { commitTime(item) }
                    .onChange(of: timeText) { mergeTimeText() }
                Spacer(minLength: 0)
                Button("取消") { isEditingTime = false }
                    .buttonStyle(SecondaryButtonStyle())
                Button("保存") { commitTime(item) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(DmSpace.s16)
        .frame(width: 336)
    }

    /// 把时分输入框的值并进草稿日期。解析不动就不并 —— 输到一半的
    /// 「2」不该把时间改成 02:00。
    private func mergeTimeText() {
        guard let clock = PhotoDate.parseClock(timeText) else { return }
        var comps = PhotoDate.utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: timeDraftDate)
        comps.hour = clock.hour
        comps.minute = clock.minute
        if let date = PhotoDate.utcCalendar.date(from: comps) {
            timeDraftDate = date
        }
    }

    /// 提交拍摄时间：时分校验不过就留在浮层里提示；改了才写回，成功后
    /// `setPhotoTime` 会把它挪到新的日期。秒数沿用原值（输入只到分钟）。
    private func commitTime(_ item: PhotosAPI.Item) {
        guard let clock = PhotoDate.parseClock(timeText) else {
            state.showToast("时分按「20:46」填", .err)
            return
        }
        var comps = PhotoDate.utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: item.time)
        comps.year = PhotoDate.utcCalendar.component(.year, from: timeDraftDate)
        comps.month = PhotoDate.utcCalendar.component(.month, from: timeDraftDate)
        comps.day = PhotoDate.utcCalendar.component(.day, from: timeDraftDate)
        comps.hour = clock.hour
        comps.minute = clock.minute
        let final = PhotoDate.utcCalendar.date(from: comps) ?? timeDraftDate
        isEditingTime = false
        guard Int(final.timeIntervalSince1970) != Int(item.time.timeIntervalSince1970) else { return }
        Task { await state.setPhotoTime(final) }
    }

    /// 提交描述：没改字就只退出、不发请求；空串按「清空」处理（写回通道：
    /// JSON 编码空串）。
    private func commitDescription() {
        let draft = descriptionDraft
        let changed = draft != descriptionOriginal
        isEditingDescription = false
        isDescriptionFieldFocused = false
        guard changed else { return }
        Task { await state.setPhotoDescription(draft) }
    }

    /// 取消：弃草稿，不发请求。
    private func cancelDescription() {
        isEditingDescription = false
        isDescriptionFieldFocused = false
    }

    /// 编辑中切了照片：两处编辑都退出、弃草稿（不替用户把半句话写到另一张上）。
    private func exitEditingIfNeeded(_ newID: Int) {
        if isEditingDescription {
            isEditingDescription = false
            isDescriptionFieldFocused = false
        }
        if isEditingTime {
            isEditingTime = false
        }
    }

    /// 标签定宽 44：六件相机字段的字头都是两个字，值对齐成一条线才扫得下去。
    private func row(_ label: String, _ value: String) -> some View {        row(label) {
            Text(value)
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 字段标签：定宽 44 / 11 号 / `ink-3`。只读行与编辑行共用同一份，
    /// 栅格才不会因为换态而错开。
    private func rowLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: DmText.t11))
            .foregroundColor(Color.dmInk3)
            .frame(width: 44, alignment: .leading)
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DmSpace.s12) {
            rowLabel(label)
            value()
            Spacer(minLength: 0)
        }
    }

    // MARK: - 取图

    private func load() async {
        teardownVideo()
        preview = nil
        full = nil
        guard let item else { return }
        if let data = await library.thumbnail(for: item, manager: state.sessionManager),
           let image = NSImage(data: data) {
            preview = image
        }
        // 视频不预取原片：`Download` 会把整段几十 MB 拉进内存，只为铺一张海报
        // 不划算 —— 海报就是缩略图（MOV 的首帧），播放按需取流。
        guard !item.isVideo else { return }
        if let data = await library.fullImage(for: item, manager: state.sessionManager),
           let image = NSImage(data: data) {
            full = image
        }
    }

    // MARK: - 翻页与退出

    private func step(_ direction: Int) async {
        guard !isStepping, let current = item else { return }
        isStepping = true
        defer { isStepping = false }
        if let next = library.neighbor(of: current, step: direction) {
            library.viewingID = next.id
        }
    }

    private func close() { library.closeViewer() }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 描述 / 时间编辑中：Esc 只收起当次编辑（其余键照常交给输入框或
            // 日历浮层），不然按 Esc 会把整个查看器关掉。
            if isEditingDescription || isEditingTime {
                if event.keyCode == 53 {
                    cancelDescription()
                    isEditingTime = false
                    return nil
                }
                return event
            }
            switch event.keyCode {
            case 123:  // ←
                Task { await step(-1) }
                return nil
            case 124:  // →
                Task { await step(1) }
                return nil
            case 49:   // 空格：只在视频上接管（照片屏按空格没有语义）
                guard isVideo else { return event }
                togglePlay()
                return nil
            case 53:   // Esc
                close()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// 只画画面的播放器层。
///
/// 不用 AVKit 的 `VideoPlayer`：它自带系统控件条，字体、间距、悬停行为与本产品线
/// 完全两套（第八节「系统语义字号全部退出」）。这里只要一个 `AVPlayerLayer`，
/// 控件由查看器自己画。
private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        view.attach(player)
        return view
    }

    func updateNSView(_ view: VideoLayerView, context: Context) {
        view.attach(player)
    }

    final class VideoLayerView: NSView {
        private let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

        func attach(_ player: AVPlayer) {
            if playerLayer.player !== player { playerLayer.player = player }
        }

        override func layout() {
            super.layout()
            // 关掉隐式动画：窗口缩放时画面跟着边缘走，而不是慢半拍地追。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// 可编辑字段的值行：有值显值、没值显灰占位；悬停浮出铅笔。
///
/// 铅笔挂**浮层**（overlay）而非进排版流：它 28 高，进了 HStack 会把行从
/// 文字高撑到控件高，基线跟着挪 —— 悬停瞬间整段内容跳一下（2026-10-21
/// 用户截图指出「悬浮时行错位」）。浮层不占布局，行高恒等于文字高。
private struct EditableValueRow: View {
    let text: String?
    let placeholder: String
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(hasText ? (text ?? "") : placeholder)
            .font(.system(size: DmText.t12))
            .foregroundColor(hasText ? Color.dmInk2 : Color.dmInk3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if isHovered {
                    IconButton(iconName: "pencil", label: "编辑") { onEdit() }
                }
            }
            .contentShape(Rectangle())
            .trackingHover($isHovered)
    }

    private var hasText: Bool { !(text ?? "").isEmpty }
}

/// 月历网格：自绘。原生 `.graphical` 档的格子大小跟着内建字号走、不吃宽度
/// 提案，信息栏的浮层里显得又小又挤（2026-10-21 用户截图两轮反馈）。
///
/// 口径与照片库同源：**UTC 墙钟**（`PhotoDate.utcCalendar`），选日期只动
/// 年月日、时分秒原样保留。单元格 40 宽 / 30 高，选中 `accent-fill` +
/// `on-accent`，悬停 `panel-3`，当月外的格子留白。
private struct TimeCalendarGrid: View {
    @Binding var selection: Date
    @State private var visibleMonth: Date
    @State private var hoveredDay: Date?

    private let calendar = PhotoDate.utcCalendar

    init(selection: Binding<Date>) {
        _selection = selection
        let comps = PhotoDate.utcCalendar.dateComponents([.year, .month],
                                                         from: selection.wrappedValue)
        _visibleMonth = State(initialValue:
            PhotoDate.utcCalendar.date(from: comps) ?? selection.wrappedValue)
    }

    var body: some View {
        VStack(spacing: DmSpace.s10) {
            HStack(spacing: DmSpace.s8) {
                Text(header)
                    .font(.system(size: DmText.t13, weight: .medium))
                    .foregroundColor(Color.dmInk)
                Spacer(minLength: 0)
                IconButton(iconName: "chevron-left", compact: true, label: "上个月") {
                    move(-1)
                }
                IconButton(iconName: "chevron-right", compact: true, label: "下个月") {
                    move(1)
                }
            }

            // 周日开头，与格子排布同序。
            HStack(spacing: DmSpace.s2) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { name in
                    Text(name)
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                        .frame(maxWidth: .infinity)
                }
            }

            let days = monthDays()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                         spacing: DmSpace.s2), count: 7),
                      spacing: DmSpace.s2) {
                ForEach(days.indices, id: \.self) { index in
                    if let date = days[index] {
                        dayCell(date)
                    } else {
                        Color.clear.frame(minHeight: 30)
                    }
                }
            }
        }
    }

    private var header: String {
        let c = calendar.dateComponents([.year, .month], from: visibleMonth)
        return String(format: "%d年%d月", c.year ?? 0, c.month ?? 0)
    }

    /// 当月的日子序列，周日前面的空位给 `nil`（留白，不放邻月日期）。
    private func monthDays() -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: visibleMonth),
              let count = calendar.range(of: .day, in: .month, for: interval.start)?.count
        else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        var cells: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for offset in 0..<count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        return cells
    }

    private func dayCell(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selection)
        let isHovered = hoveredDay.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        return Text(String(calendar.component(.day, from: date)))
            .font(.system(size: DmText.t12))
            .monospacedDigit()
            .foregroundColor(isSelected ? Color.dmOnAccent : Color.dmInk2)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r6)
                    .fill(isSelected ? Color.dmAccentFill
                          : isHovered ? Color.dmPanel3 : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hoveredDay = $0 ? date : nil }
            .onTapGesture { pick(date) }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("\(header)\(calendar.component(.day, from: date))日")
    }

    /// 选中某天：只换年月日，时分秒从当前草稿原样带过来。
    private func pick(_ date: Date) {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        let time = calendar.dateComponents([.hour, .minute, .second], from: selection)
        comps.hour = time.hour
        comps.minute = time.minute
        comps.second = time.second
        selection = calendar.date(from: comps) ?? date
    }

    private func move(_ delta: Int) {
        visibleMonth = calendar.date(byAdding: .month, value: delta,
                                     to: visibleMonth) ?? visibleMonth
    }
}

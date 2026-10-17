import SwiftUI
// 拖动改序的 `.onDrop(of: [.text], …)` 要 UTType —— 没 import 时错误不在这一行报，
// 整条修饰链的类型推断直接崩掉（错误落回 ForEach 的 indices 上，误导排查）。
import UniformTypeIdentifiers

/// 播放队列占主区（原型「队列」屏）：从播放条的队列按钮进出，侧栏没有这一项。
///
/// 列表结构与曲库一致；首列是**播放顺序**（不是 ID3 曲序），正在播放行 =
/// 浅底 + 主色字 + 均衡器（第八节浅底轨，均衡器区分选中与正在播放）。
/// 表头不参与排序 —— 这里的顺序就是播放顺序。评分列与曲库同款，且同样可点
/// （两处共用 `AppState.rate`，写的是同一个字段）。
struct QueueView: View {
    @Environment(AppState.self) private var state
    let engine: PlaybackEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DmPageHead("播放队列", subtitle: subtitle) {
                Button {
                    engine.toggleShuffle()
                } label: {
                    Label("随机播放", systemImage: "shuffle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!engine.hasQueue)

                Button {
                    engine.clearQueue()
                } label: {
                    // ⚠️ 这里给的是 **SF Symbols** 名（`Label` 走系统图标），不是 Lucide ——
                    // 原来写的 `trash-2` 是 Lucide 的名，SF 里没有，真机画的是空占位。
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!engine.hasQueue)
            }

            if engine.hasQueue {
                queueTable
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dmPanel)
    }

    private var subtitle: String {
        guard engine.hasQueue else { return "队列为空" }
        let from = engine.isShuffled ? " · 随机中" : ""
        return "\(engine.queue.count) 首\(from)"
    }

    // MARK: 表

    /// 拖动改序的现场状态。**随机播放开着时不给拖** —— 拖的是队列顺序，
    /// 随机模式下实际播放走打乱后的顺序，拖了也不照它放，等于骗人。
    @State private var draggingIndex: Int?
    @State private var dropTargetPosition: Int?

    private var queueTable: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    // 🔴 `playOrder.indices` 在新 SDK 里解析到 `indices(where:)` 函数
                    // 重载（ForEach 报 RangeSet 不可 conform，`Array(...)` 也救不回
                    // —— 属性查找本身歧义）。走 `enumerated()`，把「位置 → 队列下标」
                    // 一次拿齐，绕开这组重载。
                    ForEach(Array(engine.playOrder.enumerated()), id: \.offset) { position, songIndex in
                        let songIndex = engine.playOrder[position]
                        let song = engine.queue[songIndex]
                        QueueRow(
                            order: position + 1,
                            song: song,
                            isPlaying: engine.position == position,
                            isDropTarget: dropTargetPosition == position && draggingIndex != nil
                        ) {
                            engine.play(engine.queue, at: songIndex)
                        } onRate: { stars in
                            Task { await state.rate(song.id, to: stars) }
                        } onContextMenu: { point in
                            state.openQueueSongMenu(song, at: point, queueIndex: songIndex)
                        }
                        .onDrag {
                            draggingIndex = songIndex
                            return NSItemProvider(object: String(songIndex) as NSString)
                        }
                        // macOS 的 onDrop 的 isTargeted 是 **Binding<Bool>?**（iOS 才是
                        // 闭包）—— 落点要记「哪一行」用计算 Binding 折一下。
                        .onDrop(of: [.text], isTargeted: Binding(
                            get: { dropTargetPosition != nil },
                            set: { dropTargetPosition = $0 ? position : nil }
                        )) { providers in
                            guard let provider = providers.first else { return false }
                            provider.loadObject(ofClass: NSString.self) { object, _ in
                                guard let text = object as? String,
                                      let from = Int(text) else { return }
                                Task { @MainActor in
                                    engine.move(from: from, to: songIndex)
                                    draggingIndex = nil
                                    dropTargetPosition = nil
                                }
                            }
                            return true
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell("顺序", width: 56, alignment: .leading)
            cell("标题", width: nil, alignment: .leading)
            cell("艺术家", width: 96, alignment: .leading)
            cell("专辑", width: 96, alignment: .leading)
            cell("时长", width: 48, alignment: .trailing)
            cell("评分", width: TrackField.rating.fixedWidth, alignment: .trailing)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
    }

    @ViewBuilder
    private func cell(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        let label = Text(text)
            .font(.system(size: DmText.t11, weight: .bold))
            .kerning(0.33)
            .foregroundColor(Color.dmInk3)
            .padding(.horizontal, TrackMetrics.padH)
            .padding(.vertical, DmSpace.s8)
        if let width {
            label.frame(width: width, alignment: alignment)
        } else {
            label.frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DmSpace.s12) {
            LucideIcon("list-music", size: DmIcon.i24)
                .foregroundColor(Color.dmInk3)
            Text("队列里还没有歌")
                .font(.system(size: DmText.t15, weight: .semibold))
                .foregroundColor(Color.dmInk2)
            Text("回曲库双击一行，整张表就从这里接着放")
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
        }
        .padding(DmSpace.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 队列行。`TrackMetrics.padH` 借曲库表的列内边距，两边同一档。
private struct QueueRow: View {
    let order: Int
    let song: AudioSong
    let isPlaying: Bool
    /// 别的行正拖到这一行上（落点亮一档，与表头拖列序的落点竖线同一意图）。
    var isDropTarget: Bool = false
    let onPlay: () -> Void
    var onRate: ((Int) -> Void)?
    /// 右键（参数是指针位置，已在根视图坐标系里）。
    var onContextMenu: ((CGPoint) -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if isPlaying {
                    EqualizerBars()
                } else {
                    Text("\(order)")
                        .font(.system(size: DmText.t12))
                        .foregroundColor(Color.dmInk3)
                        .monospacedDigit()
                }
            }
            // ⚠️ 内边距必须在 `frame` **里面**：写在外面会让这一格变成
            // 56 + 20 = 76 宽，表头那格是 56，后面每一列都错位 20。
            .padding(.horizontal, TrackMetrics.padH)
            .frame(width: 56, alignment: .leading)

            HStack(spacing: DmSpace.s8) {
                DmCover(album: song.album, artist: song.albumArtist, folder: song.folder, size: 28)
                Text(song.title)
                    .font(.system(size: DmText.t13, weight: .medium))
                    .foregroundColor(ListRowState.primaryForeground(isSelected: isPlaying))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, TrackMetrics.padH)
            .frame(maxWidth: .infinity, alignment: .leading)

            plain(song.artist, width: 96)
            plain(song.album, width: 96)

            Text(song.durationText)
                .font(.system(size: DmText.t12))
                .foregroundColor(ListRowState.secondaryForeground(isSelected: isPlaying, hovered: isHovered))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, TrackMetrics.padH)
                .frame(width: 48, alignment: .trailing)

            RatingStars(
                rating: song.rating,
                isSelected: isPlaying,
                revealsEmpty: isHovered && onRate != nil,
                onRate: onRate
            )
            .padding(.trailing, DmSpace.s8)
            .frame(width: TrackField.rating.fixedWidth, alignment: .trailing)
        }
        .frame(height: 34)
        .background(ListRowState.background(isSelected: isPlaying, hovered: isHovered))
        .background(isDropTarget ? Color.dmPanel3 : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: onPlay)
        .overlay {
            if let onContextMenu {
                RightClickCatcher(onRightClick: onContextMenu)
            }
        }
    }

    @ViewBuilder
    private func plain(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: DmText.t13))
            .foregroundColor(ListRowState.foreground(isSelected: isPlaying, hovered: isHovered))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, TrackMetrics.padH)
            .frame(width: width, alignment: .leading)
    }
}

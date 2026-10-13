import SwiftUI

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
                    Label("清空", systemImage: "trash-2")
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

    private var queueTable: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(engine.playOrder.indices, id: \.self) { position in
                        let songIndex = engine.playOrder[position]
                        let song = engine.queue[songIndex]
                        QueueRow(
                            order: position + 1,
                            song: song,
                            isPlaying: engine.position == position
                        ) {
                            engine.play(engine.queue, at: songIndex)
                        } onRate: { stars in
                            Task { await state.rate(song.id, to: stars) }
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
            cell("评分", width: TrackColumn.rating, alignment: .trailing)
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
            .padding(.horizontal, TrackColumn.padH)
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

/// 队列行。`TrackColumn.padH` 借曲库表的列内边距，两边同一档。
private struct QueueRow: View {
    let order: Int
    let song: AudioSong
    let isPlaying: Bool
    let onPlay: () -> Void
    var onRate: ((Int) -> Void)?

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
            .frame(width: 56, alignment: .leading)
            .padding(.horizontal, TrackColumn.padH)

            Text(song.title)
                .font(.system(size: DmText.t13, weight: .medium))
                .foregroundColor(ListRowState.primaryForeground(isSelected: isPlaying))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, TrackColumn.padH)
                .frame(maxWidth: .infinity, alignment: .leading)

            plain(song.artist, width: 96)
            plain(song.album, width: 96)

            Text(song.durationText)
                .font(.system(size: DmText.t12))
                .foregroundColor(ListRowState.secondaryForeground(isSelected: isPlaying, hovered: isHovered))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, TrackColumn.padH)
                .frame(width: 48, alignment: .trailing)

            RatingStars(
                rating: song.rating,
                isSelected: isPlaying,
                revealsEmpty: isHovered && onRate != nil,
                onRate: onRate
            )
            .padding(.trailing, DmSpace.s8)
            .frame(width: TrackColumn.rating, alignment: .trailing)
        }
        .frame(height: 34)
        .background(ListRowState.background(isSelected: isPlaying, hovered: isHovered))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine).frame(height: DmLine.hairline)
        }
        .contentShape(Rectangle())
        .trackingHover($isHovered)
        .onTapGesture(perform: onPlay)
    }

    @ViewBuilder
    private func plain(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: DmText.t13))
            .foregroundColor(ListRowState.foreground(isSelected: isPlaying, hovered: isHovered))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, TrackColumn.padH)
            .frame(width: width, alignment: .leading)
    }
}

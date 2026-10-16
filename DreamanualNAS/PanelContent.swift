import SwiftUI

// ============ 状态栏面板内容 ============
//
// 2026-10-17 定版（设计稿 v2）：桌面小组件的图库提取通道系统侧失效，状态展示
// 改走状态栏图标点开的面板。三段：
//   · 状态区 —— 直接复用小组件的中组件视图 `NASStatusContent`，档位传
//     `.panel`：离线那组贴顶（小组件里居中）；在线三列的列内 kv 不做
//     两端对齐，块间空隙留给列间 Spacer（间距大而均匀、列宽稳定）；
//   · 播放区 —— 队列非空才渲染（用户拍板：没加歌就不该出现播放控制器）；
//   · 操作行 —— 打开主窗（实心主按钮）+ 退出。
//
// 骨架与投资监控的状态栏面板同一套：面板透明、内容圆角 r16 由外壳裁剪、
// 本 app 固定深色令牌。播放钮的图标与配色照 `PlayerBarView`（同一条播放
// 控制轨道，两处不长两样）。

struct PanelContent: View {
    /// 根视图挂上来之前是 nil —— 那会儿面板只剩离线态可看。
    let state: AppState?
    let onOpenMain: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NASStatusContent(display: display, family: .panel)
                .frame(height: 148)
            if let engine = state?.playback, engine.hasQueue {
                playbackBlock(engine).padding(.top, DmSpace.s10)
            }
            actionRow.padding(.top, DmSpace.s10)
        }
        .padding(DmSpace.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.dmPanel)
    }

    // MARK: 状态区（小组件同一份映射）

    /// 快照 → 小组件显示数据，走 `WidgetBridge` 那条现成映射（与桌面小组件
    /// 看到的一字不差）。没快照时按离线态摆，标题区分「没连上」与「连着但没读」。
    private var display: NASWidgetDisplay {
        guard let state else { return .offline(title: "未连接", lastOnline: nil) }
        if let snapshot = state.status.snapshot,
           let data = WidgetBridge.make(
               from: snapshot,
               endpointKey: state.qcID, qcID: state.qcID,
               directAddress: state.directAddress, username: state.username
           ) {
            return .make(from: data, date: Date(), family: .panel)
        }
        if state.status.phase.isBusy { return .offline(title: "正在读取", lastOnline: nil) }
        let title = state.isConnected ? "尚未读取" : "未连接"
        return .offline(title: title, lastOnline: WidgetBridge.read()?.takenAt)
    }

    // MARK: 播放区（hasQueue 才进来）

    private func playbackBlock(_ engine: PlaybackEngine) -> some View {
        HStack(spacing: DmSpace.s12) {
            VStack(alignment: .leading, spacing: DmSpace.s2) {
                Text(engine.currentSong?.title ?? "")
                    .font(.system(size: DmText.t13, weight: .semibold))
                    .foregroundColor(Color.dmInk)
                    .lineLimit(1)
                Text(engine.currentSong?.artist ?? "")
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
                    .lineLimit(1)
            }
            Spacer(minLength: DmSpace.s8)
            HStack(spacing: DmSpace.s10) {
                iconButton("skip-back", size: DmIcon.i18) { engine.previous() }
                playButton(engine)
                iconButton("skip-forward", size: DmIcon.i18) { engine.next() }
            }
        }
        .padding(DmSpace.s8)
        .background(RoundedRectangle(cornerRadius: DmRadius.r10).fill(Color.dmPanel2))
    }

    @State private var isPlayHovered = false

    private func playButton(_ engine: PlaybackEngine) -> some View {
        Button {
            engine.togglePlayPause()
        } label: {
            LucideIcon(engine.isPlaying ? "pause" : "play", size: DmIcon.i14)
                .foregroundColor(Color.dmOnAccent)
                .frame(width: DmControl.h32, height: DmControl.h32)
                .background(
                    Circle().fill(isPlayHovered ? Color.dmAccentFill2 : Color.dmAccentFill)
                )
        }
        .buttonStyle(.plain)
        .onHover { isPlayHovered = $0 }
        .animation(.easeInOut(duration: DmMotion.fast), value: isPlayHovered)
    }

    private func iconButton(
        _ name: String, size: CGFloat, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            LucideIcon(name, size: size)
                .foregroundColor(Color.dmInk2)
                .frame(width: DmControl.h28, height: DmControl.h28)
        }
        .buttonStyle(.plain)
    }

    // MARK: 操作行

    private var actionRow: some View {
        HStack(spacing: DmSpace.s8) {
            Button {
                onOpenMain()
            } label: {
                Text("打开主窗")
                    .font(.system(size: DmText.t12, weight: .medium))
                    .foregroundColor(Color.dmOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: DmControl.h32)
                    .background(RoundedRectangle(cornerRadius: DmRadius.r8).fill(Color.dmAccentFill))
            }
            .buttonStyle(.plain)
            Button {
                onQuit()
            } label: {
                Text("退出")
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk2)
                    .frame(maxWidth: .infinity)
                    .frame(height: DmControl.h32)
                    .background(RoundedRectangle(cornerRadius: DmRadius.r8).fill(Color.dmPanel2))
            }
            .buttonStyle(.plain)
        }
    }
}

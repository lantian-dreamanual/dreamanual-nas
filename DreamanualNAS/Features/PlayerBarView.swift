import SwiftUI

/// 底部常驻播放条：通栏挂在窗口底部，不属于任何模块 —— 切到文件管理或
/// 系统状态，播放与进度不中断（产品定义第二节「外壳」）。
///
/// 骨架阶段没有播放引擎，这一条是**空态**：进度条压平、控件禁用、左侧写
/// 「未在播放」。形态按设计原型落位（进度条贴上沿拉满整窗宽、悬停拉高到 8px），
/// 接上取流之后这一屏只换数据源，不动布局。
struct PlayerBarView: View {
    @State private var hoverProgress = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.dmLine)
                .frame(height: DmLine.hairline)

            // 进度条：贴上沿、拉满整窗宽。悬停拉高到 8（原型口径）。
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.dmPanel2)
                    Rectangle()
                        .fill(Color.dmAccent)
                        .frame(width: 0)
                }
                .frame(height: hoverProgress ? 8 : DmSpace.s4)
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onHover { hoverProgress = $0 }
                .animation(.easeOut(duration: DmMotion.fast), value: hoverProgress)
                .accessibilityHidden(geo.size.width == 0)
            }
            .frame(height: 8)

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
                Text("未在播放")
                    .font(.system(size: DmText.t13, weight: .medium))
                    .foregroundColor(Color.dmInk2)
                Text("从曲库选一首开始")
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
            }
        }
        .frame(width: 220, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: DmSpace.s12) {
            iconButton("shuffle", size: DmIcon.i16)
            iconButton("skip-back", size: DmIcon.i18)
            Button {
                // 播放控制接在听歌模块那一批（取流 + AVPlayer）。
            } label: {
                LucideIcon("play", size: DmIcon.i16)
                    .foregroundColor(Color.dmOnAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.dmAccentFill))
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.5)

            iconButton("skip-forward", size: DmIcon.i18)
            iconButton("list-music", size: DmIcon.i16)
        }
    }

    private func iconButton(_ name: String, size: CGFloat) -> some View {
        Button {
            // 见上：控制逻辑随播放引擎一起做。
        } label: {
            LucideIcon(name, size: size)
                .foregroundColor(Color.dmInk3)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(true)
    }

    private var volume: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon("volume-2", size: DmIcon.i16)
                .foregroundColor(Color.dmInk3)
            // 音量条：静音态先画一段空槽。
            RoundedRectangle(cornerRadius: DmRadius.r4)
                .fill(Color.dmPanel2)
                .frame(width: 80, height: 4)
        }
        .frame(width: 120, alignment: .trailing)
    }
}

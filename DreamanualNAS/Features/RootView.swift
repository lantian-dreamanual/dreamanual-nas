import SwiftUI

/// 外壳：侧栏（三个模块 + 设置）+ 主区 + 底部常驻播放条。
/// 布局与设计原型一致：侧栏 220 固定宽，主区自适应，播放条通栏、切到任何模块都不中断。
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.isConnected {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SidebarView()
                    Rectangle()
                        .fill(Color.dmLine)
                        .frame(width: DmLine.hairline)
                    MainAreaView()
                }
                .frame(maxHeight: .infinity)
                PlayerBarView()
            }
            .background(Color.dmBg)
        } else {
            ConnectView()
        }
    }
}

// ============ 侧栏 ============

private struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        WindowActiveReader { windowActive in
            VStack(alignment: .leading, spacing: 0) {
                brand
                VStack(spacing: DmSpace.s2) {
                    ForEach(AppState.Module.allCases) { module in
                        NavRow(
                            title: module.title,
                            icon: module.icon,
                            isSelected: state.module == module,
                            windowActive: windowActive
                        ) {
                            state.select(module)
                        }
                    }
                }
                .padding(.horizontal, DmSpace.s8)
                Spacer(minLength: 0)
                connectionFooter
            }
            .frame(width: 220)
            .background(Color.dmPanel)
        }
    }

    /// 品牌区顶部让出 DmLayout.titlebar —— 标题栏隐藏后红绿灯悬浮在这里。
    private var brand: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon("server", size: DmIcon.i16)
                .foregroundColor(Color.dmAccent)
            Text("Dreamanual NAS 助手")
                .font(.system(size: DmText.t13, weight: .semibold))
                .foregroundColor(Color.dmInk)
            Spacer(minLength: 0)
        }
        .padding(.top, DmLayout.titlebar)
        .padding(.horizontal, DmSpace.s16)
        .padding(.bottom, DmSpace.s14)
    }

    private var connectionFooter: some View {
        VStack(alignment: .leading, spacing: DmSpace.s6) {
            HStack(spacing: DmSpace.s6) {
                Circle()
                    .fill(Color.dmOk)
                    .frame(width: 6, height: 6)
                Text("已连接")
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk2)
            }
            Text(state.endpointLabel)
                .font(.system(size: DmText.t11))
                .foregroundColor(Color.dmInk3)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DmSpace.s16)
    }
}

/// 手写侧栏行：选中走「浅底 + 主色字」，悬停 `panel-2`，失焦降一档。
private struct NavRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let windowActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let look = SelectState.of(isSelected: isSelected, hovered: isHovered, windowActive: windowActive)
        HStack(spacing: DmSpace.s8) {
            LucideIcon(icon, size: DmIcon.i14)
                .foregroundColor(look.foreground)
            Text(title)
                .font(.system(size: DmText.t13, weight: isSelected ? .medium : .regular))
                .foregroundColor(look.foreground)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DmSpace.s8)
        .frame(height: DmControl.h32)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r6).fill(look.background)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
    }
}

// ============ 主区 ============

private struct MainAreaView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.module.title)
                .font(.system(size: DmText.t15, weight: .semibold))
                .foregroundColor(Color.dmInk)
                .padding(.top, DmLayout.titlebar)
                .padding(.horizontal, DmSpace.s20)
                .padding(.bottom, DmSpace.s14)

            switch state.module {
            case .music:
                ModulePlaceholder(
                    icon: "headphones",
                    title: "曲库",
                    note: "12331 首在 NAS 上，列表分页懒加载（一页 1000 首约 1.1 秒）",
                    next: ["列表与四维浏览（艺术家 / 专辑 / 流派）", "取流与播放（stream.cgi，支持 Range）", "歌词（内嵌直读 + 在线搜索兜底）"]
                )
            case .files:
                ModulePlaceholder(
                    icon: "folder",
                    title: "文件管理",
                    note: "8 个共享夹；目录树按名称正序，逐级懒加载",
                    next: ["目录树与文件列表", "搜索（带重试，服务端会随机假空）", "写操作（选目标弹窗 + 同名冲突处理）"]
                )
            case .status:
                ModulePlaceholder(
                    icon: "gauge",
                    title: "系统状态",
                    note: "关机与重启、读写开关机计划",
                    next: ["状态卡片（CPU / 内存 / 存储 / 温度）", "关机与重启", "开关机计划"]
                )
            case .settings:
                SettingsPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dmBg)
    }
}

/// 尚未实现的模块占位：写清「这里会有什么」，不写假的进度状态。
private struct ModulePlaceholder: View {
    let icon: String
    let title: String
    let note: String
    let next: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DmSpace.s14) {
            HStack(spacing: DmSpace.s8) {
                LucideIcon(icon, size: DmIcon.i16)
                    .foregroundColor(Color.dmAccent)
                Text(title)
                    .font(.system(size: DmText.t13, weight: .medium))
                    .foregroundColor(Color.dmInk)
            }
            Text(note)
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
            VStack(alignment: .leading, spacing: DmSpace.s6) {
                ForEach(next, id: \.self) { item in
                    HStack(alignment: .top, spacing: DmSpace.s8) {
                        Circle()
                            .fill(Color.dmInk3)
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(item)
                            .font(.system(size: DmText.t12))
                            .foregroundColor(Color.dmInk2)
                    }
                }
            }
            Text("这一屏还没接数据 —— 地基（连接 / 双会话 / 保活 / 外壳）已通。")
                .font(.system(size: DmText.t11))
                .foregroundColor(Color.dmInk3)
        }
        .padding(DmSpace.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dmPanel)
        .cornerRadius(DmRadius.r12)
        .padding(.horizontal, DmSpace.s20)
    }
}

private struct SettingsPane: View {
    @Environment(AppState.self) private var state

    @State private var heartbeatText = "刚启动"

    var body: some View {
        VStack(alignment: .leading, spacing: DmSpace.s14) {
            VStack(alignment: .leading, spacing: DmSpace.s8) {
                FormLabel("连接")
                Text(state.endpointLabel)
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk2)
                Text("每 4 分钟一次心跳；会话失效自动重登并重放当前请求。")
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
                Button("断开连接") {
                    Task { await state.disconnect() }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(DmSpace.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dmPanel)
            .cornerRadius(DmRadius.r12)
        }
        .padding(.horizontal, DmSpace.s20)
    }
}

import SwiftUI

/// 外壳：侧栏（三个模块 + 设置）+ 主区 + 底部常驻播放条。
/// 布局与设计原型一致：侧栏 220 固定宽，主区自适应，播放条通栏、切到任何模块都不中断。
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
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
        // 内容延伸进顶部安全区：hiddenTitleBar 后系统安全区（约 28pt）依然存在，
        // 不 ignore 的话侧栏会从安全区下才开始，顶部露出一条窗口底色的深带，
        // 且与品牌区的 DmLayout.titlebar padding 叠成双重让位 —— 侧栏顶上多出
        // 一块空白（2026-10-12 用户截图）。与视频下载根部同一条处理。
        .ignoresSafeArea(.container, edges: .top)
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
                .padding(.top, DmSpace.s10)

                Spacer(minLength: 0)
                connectionFooter
            }
            // 整块下移 `DmLayout.titlebar` 给悬浮的红绿灯让位，底色仍铺到窗口最上沿
            // —— 与视频下载 `SidebarView`、密码管理 `.sider` 同构。
            .padding(.top, DmLayout.titlebar)
            .frame(width: 220)
            // 侧栏比主内容区浅一档（Finder 式层级，第一节「侧栏单独一支」）。
            .background(Color.dmPanel2)
        }
    }

    /// 品牌区：标记 26·`r-8`、名称 13/semibold、内边距 16/14/12、底部 `line-2` 分隔。
    /// 规格抄密码管理 `.brand` ↔ 视频下载 `brandHeader`。
    private var brand: some View {
        HStack(spacing: DmSpace.s8) {
            DmBrandMark(size: 26)
            Text("Dreamanual NAS 助手")
                .font(.system(size: DmText.t13, weight: .semibold))
                .kerning(-0.13)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(Color.dmInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.top, DmSpace.s16)
        .padding(.bottom, DmSpace.s12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dmLine2).frame(height: DmLine.base)
        }
    }

    /// 底栏：顶部 `line-2` 分隔、内边距 8/16/10（与品牌区的上下留白同款）。
    private var connectionFooter: some View {
        VStack(alignment: .leading, spacing: DmSpace.s4) {
            HStack(spacing: DmSpace.s6) {
                Circle()
                    .fill(Color.dmOk)
                    .frame(width: 6, height: 6)
                Text("已连接")
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
            }
            Text(state.endpointLabel)
                .font(.system(size: DmText.t11))
                .foregroundColor(Color.dmInk3)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DmSpace.s16)
        .padding(.top, DmSpace.s8)
        .padding(.bottom, DmSpace.s10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.dmLine2).frame(height: DmLine.base)
        }
    }
}

/// 手写侧栏行：选中走实心主色底 + 白字（大面积轨道，`SelectState`），悬停 `panel-3`，
/// 失焦底掉 `accent-soft`、字不动。
/// 规格与视频下载 `SidebarRow` ↔ 密码管理 `.cat` 逐项一致：图标 16、字号 13、
/// 横向 8、行高钉控件档 32、圆角 8、行距 2、选中标签 semibold（第七节「侧栏行」）。
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
            LucideIcon(icon, size: DmIcon.i16)
                .foregroundColor(look.foreground)
            Text(title)
                .font(.system(size: DmText.t13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(look.foreground)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DmSpace.s8)
        .frame(height: DmControl.h32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r8).fill(look.background)
        )
        .contentShape(RoundedRectangle(cornerRadius: DmRadius.r8))
        .trackingHover($isHovered)
        .onTapGesture(perform: action)
    }
}

// ============ 主区 ============

private struct MainAreaView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.module == .music {
                LibraryView()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    DmPageHead(state.module.title)

                    switch state.module {
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
                    default:
                        SettingsPane()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 主内容区取 `panel`（第一节落位口径：主区 panel、卡片 panel-2、悬停 panel-3）。
        .background(Color.dmPanel)
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
                            .padding(.top, DmSpace.s6)
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
        .padding(DmSpace.s14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dmCard()
        .padding(.horizontal, DmSpace.s24)
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
            .padding(DmSpace.s14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dmCard()
        }
        .padding(.horizontal, DmSpace.s24)
    }
}

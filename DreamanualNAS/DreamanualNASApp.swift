import SwiftUI
import AppKit

/// 固定深色。放在 delegate 里而不是 SwiftUI 视图上：`NSApp.appearance` 能一并
/// 带上窗口标题栏、菜单、原生控件；只给根视图加 `.preferredColorScheme(.dark)`
/// 管不到这些。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 外壳（状态栏 + 关窗转后台）。`appState` 由根视图那边的 `.task` 挂上来，
    /// 状态栏菜单展开时才取值，启动头几百毫秒没挂不碍事。
    private let shell = AppShellController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DreamanualAppearance.apply()
        // 🔴 Dock 图标显式钉一次：Finder / 启动台能从 CFBundleIconFile 解析出
        // AppIcon.icns，但**运行中的进程**偶发只画通用白板（2026-10-13 用户抓的，
        // icns 本体、签名、LS 注册都核对过没毛病）。手动设 applicationIconImage
        // 强制 Dock 换图，跟缓存状态解耦。
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
        shell.install()
    }

    /// 关窗转后台：最后一个窗口关掉（理论上到不了，藏窗拦截在前）进程也不退，
    /// 播放与会话照跑 —— 这是兜底，不是主路径。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock 点图标唤起：有窗（藏着）就取出来置前；窗口真没了就交回 SwiftUI
    /// 重建 WindowGroup（返回 true 让 SwiftUI 的恢复机制接着跑）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shell.showMainWindow()
        return true
    }

    /// Dock 右键菜单：不开 app 界面也能唤起主窗。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开主窗", action: #selector(AppShellController.showClicked), keyEquivalent: "")
        open.target = shell
        menu.addItem(open)
        return menu
    }

    /// 根视图挂上 AppState（状态栏面板取状态快照与播放控制用）。
    func attachAppState(_ state: AppState) {
        shell.attachPanel(state)
    }

    /// `DM_SHELL=1`：外壳行为冒烟（藏窗 / 合成 ⌘W / 唤起），见 AppShellController。
    func runShellSmoke() async {
        await shell.smoke()
    }
}

@main
struct DreamanualNASApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Dreamanual NAS 助手", id: "main") {
            RootView()
                .environment(state)
                // 最小宽要装得下：应用侧栏 220 + 一根发丝 + 内容区侧栏 200
                // + 固定列 536 + 标题列保底 180 + 字段配置一格 32 = 1169。
                // ⚠️ 这一格字段配置是后来补的 —— 1140 那会儿漏算了它，于是窗口收到
                // 最小的那一段里，表头最右那格（竖三点）被裁掉半个（2026-10-13 用户抓到）。
                .frame(minWidth: 1170, minHeight: 620)
                .task {
                    // 状态栏菜单要用的状态挂上来（重建窗口时 .task 重跑，重复挂无害）。
                    appDelegate.attachAppState(state)
                    // 启动即重解析端点再自动登录（端点会变，不缓存到磁盘）。
                    await state.restoreAndAutoConnect()
                    // 键盘控制键（空格 / ←→）挂了才认，装一次就够。
                    state.installKeyMonitor()
                    // DM_UI=window=1170x680,songmenu,download：把窗口 / 右键菜单 /
                    // 下载摆到指定状态，供真机核对（AI 点不了 UI、拖不动窗口）。
                    if let ui = ProcessInfo.processInfo.environment["DM_UI"] {
                        await state.smokeUI(ui)
                    }
                    // DM_CONNECT=qc|direct：按连接页同一条路连一次（口令留空，
                    // 走本机已存凭据），连完打诊断 —— AI 点不了 UI，这条路只能
                    // 让程序自己走。
                    if let command = ProcessInfo.processInfo.environment["DM_CONNECT"] {
                        await state.smokeConnect(command)
                    }
                    // DM_INPUT=switch：切一次 ASCII 输入源、读回来、再还原。
                    // 焦点那半（进连接页输入框自动切）只能人工点验，这里验的是
                    // 「这条调用在 app 里真的生效」。
                    if ProcessInfo.processInfo.environment["DM_INPUT"] == "switch" {
                        await InputSource.smoke()
                    }
                    // 冒烟验证：DM_SMOKE=1 时自动播一首并打状态日志。
                    if ProcessInfo.processInfo.environment["DM_SMOKE"] == "1" {
                        await state.smokePlayFirst()
                    }
                    // DM_KEYS=space,right,left：把控制键逐个发一遍，打每步的引擎状态
                    // —— AI 按不了键盘，这条通路是核对控制键的唯一办法。
                    if let keys = ProcessInfo.processInfo.environment["DM_KEYS"] {
                        await state.smokeKeys(keys)
                    }
                    // DM_IMMERSIVE=<关键词>：搜一首、开播、进沉浸模式，供真机截图核对
                    // （AI 点不了 UI，只能让程序自己走到那一屏）。
                    if let keyword = ProcessInfo.processInfo.environment["DM_IMMERSIVE"] {
                        await state.smokeImmersive(keyword: keyword)
                    }
                    // DM_LIBRARY=<指令>：把曲库页摆到指定排序 / 列显隐 / 菜单展开
                    // 状态，供真机截图核对（同理由：AI 点不了 UI）。
                    // `click=` / `drag=` / `draghold=` 三个记号例外 —— 它们合成真鼠标
                    // 事件，走的是「点表头」「拖表头」这两条界面接线本身；
                    // `draghold=` 是拖到位不松手，好把「正在拖」那一帧截下来。
                    if let command = ProcessInfo.processInfo.environment["DM_LIBRARY"] {
                        await state.smokeLibrary(command)
                    }
                    // DM_FILES=<指令>：把文件管理页摆到指定目录 / 排序 / 树展开状态，
                    // 供真机截图核对。`click=` 与 `reveal=` 两个记号例外 —— 前者合成
                    // 真鼠标事件走「点表头 → 排序」这条接线，后者走曲库右键
                    // 「在文件管理中显示」那条接线。
                    if let command = ProcessInfo.processInfo.environment["DM_FILES"] {
                        await state.smokeFiles(command)
                    }
                    // DM_STATUS=<指令>：把系统状态页摆到指定状态，供真机截图核对。
                    // 与那两条同一理由：AI 点不了 UI，页头那个刷新钮也点不了。
                    if let command = ProcessInfo.processInfo.environment["DM_STATUS"] {
                        await state.smokeStatus(command)
                    }
                    // DM_SHELL=1：外壳行为冒烟（藏窗 / 合成 ⌘W / 唤起）。
                    if ProcessInfo.processInfo.environment["DM_SHELL"] == "1" {
                        await appDelegate.runShellSmoke()
                    }
                    // DM_WIDGET=feed|state：小组件共享快照的写入 / 回读冒烟。
                    if let command = ProcessInfo.processInfo.environment["DM_WIDGET"] {
                        await state.smokeWidget(command)
                    }
                }
        }
        // 标题栏隐藏：侧栏品牌区自己占顶部，与设计原型的窗口结构一致。
        .windowStyle(.hiddenTitleBar)
        // 最小宽要装得下：应用侧栏 220 + 内容区侧栏 200 + 固定列 536 + 标题列保底 180。
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

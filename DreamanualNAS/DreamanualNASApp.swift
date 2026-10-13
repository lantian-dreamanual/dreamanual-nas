import SwiftUI
import AppKit

/// 固定深色。放在 delegate 里而不是 SwiftUI 视图上：`NSApp.appearance` 能一并
/// 带上窗口标题栏、菜单、原生控件；只给根视图加 `.preferredColorScheme(.dark)`
/// 管不到这些。
final class AppDelegate: NSObject, NSApplicationDelegate {
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
                .frame(minWidth: 1140, minHeight: 620)
                .task {
                    // 启动即重解析端点再自动登录（端点会变，不缓存到磁盘）。
                    await state.restoreAndAutoConnect()
                    // 冒烟验证：DM_SMOKE=1 时自动播一首并打状态日志。
                    if ProcessInfo.processInfo.environment["DM_SMOKE"] == "1" {
                        await state.smokePlayFirst()
                    }
                    // DM_IMMERSIVE=<关键词>：搜一首、开播、进沉浸模式，供真机截图核对
                    // （AI 点不了 UI，只能让程序自己走到那一屏）。
                    if let keyword = ProcessInfo.processInfo.environment["DM_IMMERSIVE"] {
                        await state.smokeImmersive(keyword: keyword)
                    }
                    // DM_LIBRARY=<指令>：把曲库页摆到指定排序 / 列显隐 / 菜单展开
                    // 状态，供真机截图核对（同理由：AI 点不了 UI）。
                    if let command = ProcessInfo.processInfo.environment["DM_LIBRARY"] {
                        await state.smokeLibrary(command)
                    }
                }
        }
        // 标题栏隐藏：侧栏品牌区自己占顶部，与设计原型的窗口结构一致。
        .windowStyle(.hiddenTitleBar)
        // 最小宽要装得下：应用侧栏 220 + 内容区侧栏 200 + 固定列 536 + 标题列保底 180。
        .defaultSize(width: 1160, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

import SwiftUI
import AppKit

/// 固定深色。放在 delegate 里而不是 SwiftUI 视图上：`NSApp.appearance` 能一并
/// 带上窗口标题栏、菜单、原生控件；只给根视图加 `.preferredColorScheme(.dark)`
/// 管不到这些。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DreamanualAppearance.apply()
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
                .frame(minWidth: 980, minHeight: 620)
                .task {
                    // 启动即重解析端点再自动登录（端点会变，不缓存到磁盘）。
                    await state.restoreAndAutoConnect()
                }
        }
        // 标题栏隐藏：侧栏品牌区自己占顶部，与设计原型的窗口结构一致。
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

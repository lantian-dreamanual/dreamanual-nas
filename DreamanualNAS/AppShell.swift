import AppKit

/// 应用外壳：状态栏图标 + 关窗转后台（2026-10-15 用户定版，照网易云那套行为）。
///
/// 三条行为：
/// 1. **关窗不退出** —— 红点与 ⌘W 都走「藏窗」：`orderOut` 而不是真关。
///    SwiftUI 真收掉窗口会把视图树拆掉重建，页内状态（滚动、展开的菜单、
///    冒烟插桩）全丢；藏窗则一切原样保留，播放引擎与会话本来就不归窗口管。
/// 2. **Dock 唤起** —— 点 Dock 图标把藏着的窗口取出来置前。
/// 3. **状态栏图标** —— 菜单栏常驻，放曲名与播放控制；关窗后听歌控制就有
///    媒体键、控制中心、状态栏菜单、Dock 唤起四条路，全不依赖窗口开着。
///
/// 退出只留两处：⌘Q 与状态栏菜单的「退出」。菜单内容每次展开时重建
/// （`menuNeedsUpdate`），曲名与播放态永远现取，不用做观察刷新。
final class AppShellController: NSObject, NSMenuDelegate {
    /// 播放控制与曲名取自这里。根视图挂上来之前（启动头几百毫秒）是 nil，
    /// 菜单晚点展开没事 —— 内容是展开时才重建的。
    weak var appState: AppState?

    private var statusItem: NSStatusItem?
    private var cmdWMonitor: Any?

    // MARK: 安装

    func install() {
        installStatusItem()
        hookCloseButtons()
        swallowCmdW()
    }

    /// 状态栏图标。`externaldrive` 这枚符号 macOS 11 起就有，走模板渲染
    /// 跟随菜单栏深浅。
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Dreamanual NAS 助手")
            icon?.isTemplate = true
            button.image = icon
        }
        let menu = NSMenu()
        menu.delegate = self
        // 逐项手工定可用性（表头项是纯说明文字，不能让系统按 action 自动判）。
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    // MARK: 关窗转后台

    /// 主窗：SwiftUI 的 WindowGroup 窗。按「非面板 + 有标题栏样式」过滤，
    /// 状态栏窗口与各种浮层都排除在外（hiddenTitleBar 仍保留 .titled 位）。
    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0 is NSPanel == false && $0.styleMask.contains(.titled) }
    }

    /// 藏主窗（不销毁）。这就是本 app 的「关闭窗口」。
    func hideMainWindow() {
        mainWindow?.orderOut(nil)
    }

    /// 唤起主窗。窗口被真销毁的兜底路径交给 SwiftUI 自己的 reopen 重建
    /// （`restoreAndAutoConnect` / `installKeyMonitor` 都有幂等守卫，重建安全）。
    func showMainWindow() {
        guard let window = mainWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 红点按钮改走藏窗：SwiftUI 的窗口 delegate 归 SwiftUI 自己管（抢了会破
    /// 全屏与还原），改按钮的 action 是不碰 delegate 的唯一干净入口。
    /// 窗口是 SwiftUI 在首帧后才创建的，挂 `didBecomeMainNotification` 兜住
    /// 重建场景，装完顺手钩一次当下已有的。
    private func hookCloseButtons() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.hookCloseButton(of: note.object as? NSWindow)
            }
        }
        hookCloseButton(of: mainWindow)
    }

    private func hookCloseButton(of window: NSWindow?) {
        guard let window, window is NSPanel == false, window.styleMask.contains(.titled),
              let button = window.standardWindowButton(.closeButton) else { return }
        button.target = self
        button.action = #selector(closeButtonClicked(_:))
    }

    /// ⌘W 在进菜单分发前拦下（本地事件监视器先于按键等价物跑）。App 状态层
    /// 的监视器对 ⌘ 组合一律放行，两边不打架。
    private func swallowCmdW() {
        cmdWMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 13, modifiers == .command else { return event }
            MainActor.assumeIsolated {
                self?.hideMainWindow()
            }
            return nil
        }
    }

    @objc private func closeButtonClicked(_ sender: Any?) {
        hideMainWindow()
    }

    // MARK: 状态栏菜单（展开时整单重建）

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let engine = MainActor.assumeIsolated { appState?.playback }

        let head: NSMenuItem
        if let song = MainActor.assumeIsolated({ engine?.currentSong }) {
            head = NSMenuItem(title: "正在播放：\(song.title) · \(song.artist)",
                              action: nil, keyEquivalent: "")
        } else {
            head = NSMenuItem(title: "未在播放", action: nil, keyEquivalent: "")
        }
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        let isPlaying = MainActor.assumeIsolated { engine?.isPlaying ?? false }
        menu.addItem(item(isPlaying ? "暂停" : "播放", action: #selector(playPauseClicked), key: " "))
        menu.addItem(item("上一首", action: #selector(previousClicked), key: ""))
        menu.addItem(item("下一首", action: #selector(nextClicked), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("打开主窗", action: #selector(showClicked), key: ""))
        menu.addItem(.separator())
        let quit = item("退出 Dreamanual NAS 助手", action: #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = nil
        menu.addItem(quit)
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? nil : self
        return item
    }

    @objc private func playPauseClicked(_ sender: Any?) {
        MainActor.assumeIsolated { appState?.playback?.togglePlayPause() }
    }

    @objc private func previousClicked(_ sender: Any?) {
        MainActor.assumeIsolated { appState?.playback?.previous() }
    }

    @objc private func nextClicked(_ sender: Any?) {
        MainActor.assumeIsolated { appState?.playback?.next() }
    }

    @objc func showClicked(_ sender: Any?) {
        showMainWindow()
    }

    // MARK: 冒烟验证

    /// `DM_SHELL=1`：把外壳三条行为各走一遍并打日志 —— 藏窗前后窗口可见性、
    /// 合成 ⌘W（走真通路：本地监视器在 `NSApp.sendEvent` 里被调）、再唤起。
    /// 播放引擎与会话不受窗口影响这一点，由「藏窗期间 keep-alive 照跑」侧证。
    @MainActor func smoke() async {
        func visibility(_ tag: String) {
            for window in NSApp.windows where window is NSPanel == false {
                NSLog("[shell] %@ 窗口 %@ visible=%@ frame=%@",
                      tag, String(window.windowNumber),
                      window.isVisible ? "是" : "否", NSStringFromRect(window.frame))
            }
        }
        visibility("起手")
        guard let window = mainWindow else {
            NSLog("[shell] 没找到主窗，冒烟到此为止")
            return
        }
        hideMainWindow()
        try? await Task.sleep(nanoseconds: 600_000_000)
        visibility("藏窗后")
        NSLog("[shell] 引擎还在吗 → %@", appState?.playback != nil ? "在" : "没了")
        // 合成 ⌘W：走 sendEvent 进本地监视器这条真通路，验监视器拦截本身。
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [.command], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "w", charactersIgnoringModifiers: "w",
                                        isARepeat: false, keyCode: 13) {
            NSApp.sendEvent(event)
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSLog("[shell] 合成 ⌘W 后 visible=%@（应为否 —— 已藏，或本来就没开）",
                  mainWindow?.isVisible == true ? "是" : "否")
        }
        showMainWindow()
        try? await Task.sleep(nanoseconds: 600_000_000)
        visibility("唤起后")
        NSLog("[shell] 冒烟完")
    }
}

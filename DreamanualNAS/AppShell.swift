import AppKit
import SwiftUI
import SwiftUI

/// 应用外壳：状态栏图标 + 状态面板 + 关窗转后台。
///
/// 四条行为：
/// 1. **关窗不退出** —— 红点与 ⌘W 都走「藏窗」：`orderOut` 而不是真关。
///    SwiftUI 真收掉窗口会把视图树拆掉重建，页内状态（滚动、展开的菜单、
///    冒烟插桩）全丢；藏窗则一切原样保留，播放引擎与会话本来就不归窗口管。
/// 2. **Dock 唤起** —— 点 Dock 图标把藏着的窗口取出来置前。
/// 3. **状态栏图标 → 面板** —— 左键点图标弹面板：NAS 状态（复用小组件的
///    中组件视图）+ 播放控制（有队列才出现）+ 打开主窗 / 退出。2026-10-17
///    替代桌面小组件与旧的状态栏菜单。打开即刷一次系统状态，开着期间 30s
///    一拍；点面板外任意处收起。
/// 4. **右键只留退出** —— 图标右键一个菜单项（设计稿 v2 拍板）。
///
/// 面板骨架照投资监控 `MenuBarController`：可聚焦的非激活 NSPanel、面板
/// 透明 + 内容圆角裁剪、延迟 0.3s 装点外点击监视器（防弹出的那一击瞬关）。
final class AppShellController: NSObject {
    /// 播放控制与状态快照取自这里。根视图挂上来之前（启动头几百毫秒）是 nil，
    /// 面板显示离线态，晚点挂不碍事。
    weak var appState: AppState?

    private var statusItem: NSStatusItem?
    private var panel: FocusablePanel?
    private var refreshTimer: Timer?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var cmdWMonitor: Any?

    /// 面板尺寸两档（设计稿 v2）：无队列 214（状态区 + 操作行），有队列
    /// 多一段播放区 276。开面板时定档；开着期间队列变化保持当前档，下次
    /// 打开按新档走。
    private static let panelWidth: CGFloat = 400
    private static let panelHeightCompact: CGFloat = 214
    private static let panelHeightTall: CGFloat = 276

    // MARK: 安装

    func install() {
        installStatusItem()
        setupPanel()
        hookCloseButtons()
        swallowCmdW()
    }

    /// 根视图把 AppState 挂上来后换一次面板内容（面板在 install 时就建好，
    /// 那会儿 AppState 还没出生），顺带启动连接态的图标观察。
    func attachPanel(_ state: AppState) {
        appState = state
        MainActor.assumeIsolated {
            observeConnectionState()
            refreshPanelContent()
        }
    }

    private func makePanelContent(state: AppState?) -> PanelContent {
        PanelContent(
            state: state,
            onOpenMain: { [weak self] in self?.showMainWindow() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    /// 面板内容重摆。AppState 是 @Observable，但面板是**常驻隐藏的 NSPanel**
    /// —— 隐藏期间 SwiftUI 的 observation 刷新不落地（2026-10-18 用户实抓：
    /// 主窗已连接，面板停在挂上那一刻的「未连接」）。所以不依赖自动刷新：
    /// 状态一变（见 `observeConnectionState`）或打开面板（`showPanel`）时都
    /// 重摆一次 rootView，内容永远按当下状态现渲染。
    @MainActor private func refreshPanelContent() {
        guard let hosting = panel?.contentView as? NSHostingView<PanelContent> else { return }
        hosting.rootView = makePanelContent(state: appState)
    }

    /// 状态栏图标。随连接态在 Lucide `server` / `server-off` 两枚之间切
    /// （2026-10-16 用户定）：挂上 AppState 前一律离线态。左键 / 右键在
    /// action 里按 `NSApp.currentEvent` 分流。
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MainActor.assumeIsolated { statusIcon(online: false) }
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Lucide 图标栅格化成模板图。走 `LucideIcon` 这层统一入口（现在画的是
    /// SF 兜底，图标资产补齐后状态栏自动跟上真 Lucide 形态）；`isTemplate`
    /// 让 AppKit 拿 alpha 当遮罩，颜色跟随菜单栏深浅。
    @MainActor private func statusIcon(online: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: LucideIcon(online ? "server" : "server-off", size: DmIcon.i16))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }

    /// 连接态变了换图标、重摆面板。AppState 是 @Observable，外壳不是视图
    /// 吃不到自动刷新，用观察追踪链手动续：`phase` / 状态快照一变回主线程
    /// 重注册并重画。挂上 AppState 才有得追，调用点在 `attachPanel`。
    @MainActor private func observeConnectionState() {
        guard let state = appState else { return }
        updateStatusIcon()
        if panel?.isVisible == true { refreshPanelContent() }
        withObservationTracking {
            _ = state.phase
            // 快照也追：面板开着期间「打开即刷」的取数回来，那一拍要重摆。
            _ = state.status.phase
            _ = state.status.snapshot
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observeConnectionState() }
            }
        }
    }

    @MainActor private func updateStatusIcon() {
        statusItem?.button?.image = statusIcon(online: appState?.isConnected == true)
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else {
            MainActor.assumeIsolated { togglePanel() }
            return
        }
        if event.type == .rightMouseUp {
            closePanel()
            statusItem?.popUpMenu(buildContextMenu())
        } else {
            MainActor.assumeIsolated { togglePanel() }
        }
    }

    /// 右键菜单只留退出（设计稿 v2）。菜单项文字就两个字 —— 菜单是贴着
    /// 状态栏图标弹的，上下文已经指明是哪个 app，不必再带应用名。
    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "退出",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = nil
        menu.addItem(quit)
        return menu
    }

    // MARK: 状态栏面板

    private func setupPanel() {
        let hosting = NSHostingView(rootView: makePanelContent(state: nil))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeightCompact)
        // 圆角裁剪：面板本身透明，内容视图裁出圆角（投资监控同款，r16）。
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = DmRadius.r16
        hosting.layer?.masksToBounds = true

        let p = FocusablePanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hosting
        panel = p
    }

    @MainActor private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    /// 按钮 action 与冒烟都发生在主线程；隔离标注让 AppState 的访问过编译。
    @MainActor private func showPanel() {
        guard let panel, let button = statusItem?.button else { return }
        // 高度定档：队列非空多一段播放区。
        let height = appState?.playback?.hasQueue == true
            ? Self.panelHeightTall : Self.panelHeightCompact
        if let hosting = panel.contentView as? NSHostingView<PanelContent> {
            hosting.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: height)
        }
        panel.setContentSize(NSSize(width: Self.panelWidth, height: height))
        // 先按当下状态重摆内容再亮出来（见 `refreshPanelContent`：隐藏期间
        // 自动刷新不落地，打开这一下必须现渲染）。
        refreshPanelContent()

        // 打开即刷：连着才发，一次全量。与状态页的刷新按钮同一入口。
        if let state = appState, state.isConnected {
            Task { await state.status.load(on: state.sessionManager, force: true) }
        }

        // 定位到状态栏按钮下方居中，屏幕边界内钳制。
        let size = NSSize(width: Self.panelWidth, height: height)
        let btnFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? button.bounds
        var x = btnFrame.midX - size.width / 2
        let y = btnFrame.minY - size.height - 4
        if let screen = button.window?.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        startRefreshTimer()
        // 延迟启动监视器，避免触发弹出的那次点击被 monitor 捕获导致面板瞬关。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard self?.panel?.isVisible == true else { return }
            self?.startMonitoring()
        }
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        stopMonitoring()
        stopRefreshTimer()
    }

    /// 面板开着期间 30s 一拍刷新（连着才发），收起即停。
    private func startRefreshTimer() {
        stopRefreshTimer()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true,
                      let state = self.appState, state.isConnected else { return }
                Task { await state.status.load(on: state.sessionManager, force: true) }
            }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: 点外关闭

    private func startMonitoring() {
        stopMonitoring()
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleOutsideClick() }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleOutsideClick()
            return event
        }
    }

    private func stopMonitoring() {
        if let m = globalEventMonitor { NSEvent.removeMonitor(m); globalEventMonitor = nil }
        if let m = localEventMonitor { NSEvent.removeMonitor(m); localEventMonitor = nil }
    }

    /// 点击面板外部时关闭；点击状态栏按钮区域交给 toggle 逻辑处理，不在此关闭。
    private func handleOutsideClick() {
        guard let panel, panel.isVisible else { return }
        let mouseLoc = NSEvent.mouseLocation
        if let button = statusItem?.button, let win = button.window {
            let btnFrame = win.convertToScreen(button.convert(button.bounds, to: nil))
                .insetBy(dx: -4, dy: -4)
            if btnFrame.contains(mouseLoc) { return }
        }
        if panel.frame.contains(mouseLoc) { return }
        // 点击落在本 app 的其他窗口（弹层、主窗）时不关闭。
        if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(mouseLoc) }) { return }
        closePanel()
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

    @objc func showClicked(_ sender: Any?) {
        showMainWindow()
    }

    // MARK: 冒烟验证（面板）

    /// `DM_PANEL=1`：面板显示冒烟 —— 等连接落定，程序化开面板，开前 / 开后
    /// 各打一轮状态（phase / isConnected / 快照有无），供日志与真机截图核对
    /// 面板显示档位（在线三列 / 尚未读取 / 未连接）。AI 点不了状态栏图标，
    /// 开面板只能走代码路径。
    @MainActor func smokePanel() async {
        guard let state = appState else {
            NSLog("[panel] 没挂上 AppState，冒烟到此为止")
            return
        }
        // 等连接落定 ≤30s（与其他冒烟同一口径；指令在落定前跑会白跑）。
        for _ in 0..<60 {
            if state.isConnected { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        NSLog("[panel] 开面板前 phase=%@ isConnected=%@ 快照=%@",
              String(describing: state.phase),
              state.isConnected ? "是" : "否",
              state.status.snapshot != nil ? "有" : "无")
        showPanel()
        // 停 3.5s —— 给「打开即刷」的取数链路走完（中继一趟要秒级）。
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        NSLog("[panel] 开面板后 快照=%@ 状态页=%@ 面板可见=%@",
              state.status.snapshot != nil ? "有" : "无",
              String(describing: state.status.phase),
              panel?.isVisible == true ? "是" : "否")
        NSLog("[panel] 冒烟完（面板保持开着，供截图）")
    }

    // MARK: 冒烟验证

    /// `DM_SHELL=1`：把外壳各条行为走一遍并打日志 —— 藏窗前后窗口可见性、
    /// 合成 ⌘W（走真通路：本地监视器在 `NSApp.sendEvent` 里被调）、再唤起，
    /// 最后面板程序化开合一次（AI 点不了 UI，开合走代码路径）。
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
        // 面板：程序化开合，核可见性与收起。停 2.5s —— 给打开即刷的快照
        // 走完链路（中继一趟要秒级），抓图才能拍到在线态。
        showPanel()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        NSLog("[shell] 面板开 → visible=%@（应为是）", panel?.isVisible == true ? "是" : "否")
        closePanel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSLog("[shell] 面板收 → visible=%@（应为否）", panel?.isVisible == true ? "是" : "否")
        NSLog("[shell] 冒烟完")
    }
}

/// 可聚焦的 NSPanel（照投资监控同款）：nonactivatingPanel 默认 canBecomeKey
/// 为 false，覆写后点进面板才能收键盘事件；保持非激活特性，弹面板不抢主
/// app 的焦点。
final class FocusablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

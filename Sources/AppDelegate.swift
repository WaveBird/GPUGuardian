import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: MainPanelController!

    // Status menu items we update live
    private var menuItemStatus: NSMenuItem!
    private var menuItemIGPU: NSMenuItem!
    private var menuItemDGPU: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ── 1. Status-bar item ──────────────────────────────────────────────
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🌿 iGPU"

        let menu = NSMenu()
        menu.delegate = self

        // Live GPU summary at top (updated in updateStatusBarTitle)
        menuItemStatus = NSMenuItem(title: "正在读取显卡状态…", action: nil, keyEquivalent: "")
        menuItemStatus.isEnabled = false
        menu.addItem(menuItemStatus)

        menuItemIGPU = NSMenuItem(title: "🌿 核显: —", action: nil, keyEquivalent: "")
        menuItemIGPU.isEnabled = false
        menu.addItem(menuItemIGPU)

        menuItemDGPU = NSMenuItem(title: "⚡ 独显: —", action: nil, keyEquivalent: "")
        menuItemDGPU.isEnabled = false
        menu.addItem(menuItemDGPU)

        menu.addItem(.separator())

        // ── GPU Switch submenu ──────────────────────────────────────────────
        let switchMenu = NSMenu(title: "全局切换")
        let miIntegrated = NSMenuItem(title: "仅核显 (Integrated)", action: #selector(onMenuSwitchIntegrated), keyEquivalent: "")
        miIntegrated.target = self
        let miDynamic    = NSMenuItem(title: "自动切换 (Dynamic)",  action: #selector(onMenuSwitchDynamic),    keyEquivalent: "")
        miDynamic.target = self
        let miDiscrete   = NSMenuItem(title: "仅独显 (Discrete)",   action: #selector(onMenuSwitchDiscrete),  keyEquivalent: "")
        miDiscrete.target = self
        switchMenu.addItem(miIntegrated)
        switchMenu.addItem(miDynamic)
        switchMenu.addItem(miDiscrete)

        let switchItem = NSMenuItem(title: "全局显卡切换", action: nil, keyEquivalent: "")
        switchItem.submenu = switchMenu
        menu.addItem(switchItem)

        menu.addItem(.separator())

        // ── Main window ─────────────────────────────────────────────────────
        let miShow = NSMenuItem(title: "显示主面板", action: #selector(showPanel), keyEquivalent: "g")
        miShow.target = self
        miShow.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(miShow)

        menu.addItem(.separator())

        // ── About & Quit ─────────────────────────────────────────────────────
        let miAbout = NSMenuItem(title: "关于 GPU Guardian", action: #selector(onAbout), keyEquivalent: "")
        miAbout.target = self
        menu.addItem(miAbout)

        menu.addItem(.separator())

        let miQuit = NSMenuItem(title: "退出 GPU Guardian", action: #selector(onQuit), keyEquivalent: "q")
        miQuit.target = self
        miQuit.keyEquivalentModifierMask = .command
        menu.addItem(miQuit)

        statusItem.menu = menu

        // ── 2. Control panel ─────────────────────────────────────────────────
        panelController = MainPanelController()
        panelController.onStatusUpdated = { [weak self] hw, procs in
            self?.updateStatusBarTitle(hw: hw, procs: procs)
        }

        showPanel()
        panelController.refreshNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // MARK: - Live status update

    private func updateStatusBarTitle(hw: GPUHardwareStatus, procs: [GPUProcessInfo]) {
        let activeStr = withUnsafePointer(to: hw.activeGPU) {
            $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
        }
        let lockCount  = procs.filter { $0.hasDiscreteOpenGLLock || $0.hasDiscreteFramebuffer }.count
        let dgpuActive = (activeStr == "GFX0" || hw.dgpuPowered)

        // Status-bar button title
        if dgpuActive {
            var title = "🔥 dGPU"
            if lockCount > 0 { title += "(\(lockCount))" }
            if hw.dgpuUtilPct >= 0 { title += " \(hw.dgpuUtilPct)%" }
            if hw.dgpuTempC >= 0   { title += " \(hw.dgpuTempC)°C" }
            statusItem.button?.title = title
        } else {
            let igpuPct = hw.igpuUtilPct >= 0 ? hw.igpuUtilPct : max(0, hw.igpuUnit0UtilPct)
            statusItem.button?.title = "🌿 iGPU \(igpuPct)%"
        }

        // Live menu top items
        menuItemStatus.title = dgpuActive
            ? "⚡ 当前使用：AMD Radeon R9 M370X (独显)"
            : "🌿 当前使用：Intel Iris Pro (核显)"

        // iGPU row
        let igpuPct = hw.igpuUtilPct >= 0 ? hw.igpuUtilPct : max(0, hw.igpuUnit0UtilPct)
        var igpuStr = "🌿 核显: \(igpuPct)%"
        if hw.igpuUsedMemBytes > 0 {
            igpuStr += "  共享显存 \(hw.igpuUsedMemBytes / (1024*1024)) MB"
        }
        menuItemIGPU.title = igpuStr

        // dGPU row
        if dgpuActive {
            var dgpuStr = "🔥 独显: \(max(0, hw.dgpuUtilPct))%"
            if hw.dgpuTempC >= 0 { dgpuStr += "  \(hw.dgpuTempC)°C" }
            if hw.dgpuUsedVRAMBytes > 0 {
                let used  = hw.dgpuUsedVRAMBytes / (1024*1024)
                let total = (hw.dgpuUsedVRAMBytes + hw.dgpuFreeVRAMBytes) / (1024*1024)
                dgpuStr += "  显存 \(used)/\(total) MB"
            }
            if lockCount > 0 { dgpuStr += "  🔒×\(lockCount)" }
            menuItemDGPU.title = dgpuStr
        } else {
            menuItemDGPU.title = "⚡ 独显: 已断电休眠"
        }
    }

    // MARK: - Menu actions

    @objc private func onMenuSwitchIntegrated() {
        _ = GPUProcessMonitor.switchGlobalMode(.integratedOnly, persistWithPmset: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.panelController.refreshNow()
        }
    }

    @objc private func onMenuSwitchDynamic() {
        _ = GPUProcessMonitor.switchGlobalMode(.dynamicSwitching, persistWithPmset: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.panelController.refreshNow()
        }
    }

    @objc private func onMenuSwitchDiscrete() {
        _ = GPUProcessMonitor.switchGlobalMode(.discreteOnly, persistWithPmset: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.panelController.refreshNow()
        }
    }

    @objc func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panelController.showWindow(nil)
        panelController.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func onAbout() {
        let alert = NSAlert()
        alert.messageText = "GPU Guardian 1.0"
        alert.informativeText = """
            实时双显卡监控与切换工具
            适用于搭载 Intel + AMD 双显卡的 MacBook Pro（OCLP 环境兼容）

            功能：
            · 实时查看 iGPU/dGPU 负载、温度、显存
            · 显著标出锁定独显的进程
            · 系统级全局显卡切换 (AppleMuxControl + pmset)
            · 直接退出/强杀锁独显进程

            数据来源：IOKit IOUserClientCreator + PerformanceStatistics
            作者：Jame · 2026
            """
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func onQuit() {
        NSApp.terminate(nil)
    }
}

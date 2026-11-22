import Cocoa

final class MainPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    // Mode header (compact, secondary)
    private var statusDotView: NSView!
    private var statusTitleLabel: NSTextField!
    private var statusDetailLabel: NSTextField!  // hidden, compat only

    // iGPU card
    private var igpuCardView: NSStackView!       // for border color update
    private var igpuBadgeLabel: NSTextField!     // "● 活跃" / "● 空闲"
    private var igpuBigLabel: NSTextField!       // "25%"  30pt bold
    private var igpuLoadBar: NSProgressIndicator!
    private var igpuSubLabel: NSTextField!       // detail stats

    // dGPU card
    private var dgpuCardView: NSStackView!
    private var dgpuBadgeLabel: NSTextField!     // "● 活跃" / "● 休眠"
    private var dgpuBigLabel: NSTextField!       // "52%" / "休眠"  30pt bold
    private var dgpuLoadBar: NSProgressIndicator!
    private var dgpuSubLabel: NSTextField!

    // compat aliases used in refreshNow
    private var igpuLoadLabel: NSTextField { igpuBigLabel }
    private var dgpuLoadLabel: NSTextField { dgpuBigLabel }

    private var btnIntegrated: NSButton!
    private var btnDynamic: NSButton!
    private var btnDiscrete: NSButton!
    private var chkPersistPmset: NSButton!
    private var btnCleanLocks: NSButton!

    private var statsLabel: NSTextField!
    private var chkOnlyDiscrete: NSButton!
    private var chkAutoRefresh: NSButton!
    private var footerLabel: NSTextField!

    private var tableView: NSTableView!
    private var allProcesses: [GPUProcessInfo] = []
    private var displayedProcesses: [GPUProcessInfo] = []
    private var refreshTimer: Timer?

    var onStatusUpdated: ((GPUHardwareStatus, [GPUProcessInfo]) -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1010, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GPU Guardian — 显卡切换与进程监控"
        window.minSize = NSSize(width: 900, height: 460)
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        setupUI()
        refreshNow()
        startTimer()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])

        // 1. Mode header — single compact line above the two cards
        let modeRow = NSStackView()
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 6

        statusDotView = NSView()
        statusDotView.wantsLayer = true
        statusDotView.layer?.cornerRadius = 4
        statusDotView.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDotView.translatesAutoresizingMaskIntoConstraints = false
        statusDotView.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDotView.heightAnchor.constraint(equalToConstant: 8).isActive = true

        statusTitleLabel = NSTextField(labelWithString: "读取中...")
        statusTitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusTitleLabel.textColor = NSColor.secondaryLabelColor

        statusDetailLabel = NSTextField(labelWithString: "")
        statusDetailLabel.isHidden = true

        modeRow.addArrangedSubview(statusDotView)
        modeRow.addArrangedSubview(statusTitleLabel)
        rootStack.addArrangedSubview(modeRow)
        modeRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -32).isActive = true

        // 2. Two GPU cards side by side
        let cardsRow = NSStackView()
        cardsRow.orientation = .horizontal
        cardsRow.distribution = .fillEqually
        cardsRow.spacing = 10

        // ── iGPU Card ─────────────────────────────────────────────────────────
        igpuCardView = NSStackView()
        igpuCardView.orientation = .vertical
        igpuCardView.alignment = .leading
        igpuCardView.spacing = 4
        igpuCardView.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        igpuCardView.wantsLayer = true
        igpuCardView.layer?.cornerRadius = 10
        igpuCardView.layer?.borderWidth = 1.5
        igpuCardView.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.35).cgColor
        igpuCardView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // identity row: big GPU type name + badge on the right
        let igpuTypeLabel = NSTextField(labelWithString: "核显")
        igpuTypeLabel.font = NSFont.systemFont(ofSize: 22, weight: .heavy)
        igpuTypeLabel.textColor = NSColor.systemGreen

        igpuBadgeLabel = NSTextField(labelWithString: "● --")
        igpuBadgeLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        igpuBadgeLabel.textColor = NSColor.systemGreen

        let igpuIdRow = NSStackView()
        igpuIdRow.orientation = .horizontal
        igpuIdRow.alignment = .centerY
        igpuIdRow.spacing = 8
        igpuIdRow.addArrangedSubview(igpuTypeLabel)
        igpuIdRow.addArrangedSubview(igpuBadgeLabel)

        let igpuChipLabel = NSTextField(labelWithString: "Intel Iris Pro")
        igpuChipLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        igpuChipLabel.textColor = NSColor.tertiaryLabelColor

        // big load number
        igpuBigLabel = NSTextField(labelWithString: "--")
        igpuBigLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .bold)
        igpuBigLabel.textColor = NSColor.systemGreen

        // progress bar
        igpuLoadBar = NSProgressIndicator()
        igpuLoadBar.isIndeterminate = false
        igpuLoadBar.minValue = 0; igpuLoadBar.maxValue = 100; igpuLoadBar.doubleValue = 0
        igpuLoadBar.controlSize = .regular
        igpuLoadBar.translatesAutoresizingMaskIntoConstraints = false

        // sub stats
        igpuSubLabel = NSTextField(labelWithString: "")
        igpuSubLabel.font = NSFont.systemFont(ofSize: 10)
        igpuSubLabel.textColor = NSColor.secondaryLabelColor
        igpuSubLabel.lineBreakMode = .byTruncatingTail

        igpuCardView.addArrangedSubview(igpuIdRow)
        igpuCardView.addArrangedSubview(igpuChipLabel)
        igpuCardView.addArrangedSubview(igpuBigLabel)
        igpuCardView.addArrangedSubview(igpuLoadBar)
        igpuCardView.addArrangedSubview(igpuSubLabel)
        igpuCardView.setCustomSpacing(8, after: igpuChipLabel)

        // ── dGPU Card ─────────────────────────────────────────────────────────
        dgpuCardView = NSStackView()
        dgpuCardView.orientation = .vertical
        dgpuCardView.alignment = .leading
        dgpuCardView.spacing = 4
        dgpuCardView.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        dgpuCardView.wantsLayer = true
        dgpuCardView.layer?.cornerRadius = 10
        dgpuCardView.layer?.borderWidth = 1.5
        dgpuCardView.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.2).cgColor
        dgpuCardView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let dgpuTypeLabel = NSTextField(labelWithString: "独显")
        dgpuTypeLabel.font = NSFont.systemFont(ofSize: 22, weight: .heavy)
        dgpuTypeLabel.textColor = NSColor.systemRed.withAlphaComponent(0.5)

        dgpuBadgeLabel = NSTextField(labelWithString: "● 休眠")
        dgpuBadgeLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        dgpuBadgeLabel.textColor = NSColor.tertiaryLabelColor

        let dgpuIdRow = NSStackView()
        dgpuIdRow.orientation = .horizontal
        dgpuIdRow.alignment = .centerY
        dgpuIdRow.spacing = 8
        dgpuIdRow.addArrangedSubview(dgpuTypeLabel)
        dgpuIdRow.addArrangedSubview(dgpuBadgeLabel)

        // store type label for later color updates
        dgpuTypeLabel.tag = 1001

        let dgpuChipLabel = NSTextField(labelWithString: "AMD Radeon R9 M370X")
        dgpuChipLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        dgpuChipLabel.textColor = NSColor.tertiaryLabelColor

        dgpuBigLabel = NSTextField(labelWithString: "休眠")
        dgpuBigLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .bold)
        dgpuBigLabel.textColor = NSColor.tertiaryLabelColor

        dgpuLoadBar = NSProgressIndicator()
        dgpuLoadBar.isIndeterminate = false
        dgpuLoadBar.minValue = 0; dgpuLoadBar.maxValue = 100; dgpuLoadBar.doubleValue = 0
        dgpuLoadBar.controlSize = .regular
        dgpuLoadBar.translatesAutoresizingMaskIntoConstraints = false

        dgpuSubLabel = NSTextField(labelWithString: "独显已断电 · 省电模式")
        dgpuSubLabel.font = NSFont.systemFont(ofSize: 10)
        dgpuSubLabel.textColor = NSColor.tertiaryLabelColor
        dgpuSubLabel.lineBreakMode = .byTruncatingTail

        dgpuCardView.addArrangedSubview(dgpuIdRow)
        dgpuCardView.addArrangedSubview(dgpuChipLabel)
        dgpuCardView.addArrangedSubview(dgpuBigLabel)
        dgpuCardView.addArrangedSubview(dgpuLoadBar)
        dgpuCardView.addArrangedSubview(dgpuSubLabel)
        dgpuCardView.setCustomSpacing(8, after: dgpuChipLabel)

        cardsRow.addArrangedSubview(igpuCardView)
        cardsRow.addArrangedSubview(dgpuCardView)
        rootStack.addArrangedSubview(cardsRow)
        cardsRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -32).isActive = true
        igpuLoadBar.widthAnchor.constraint(equalTo: igpuCardView.widthAnchor, constant: -32).isActive = true
        dgpuLoadBar.widthAnchor.constraint(equalTo: dgpuCardView.widthAnchor, constant: -32).isActive = true

        // 2. Global GPU Switch Controls
        let switchRow = NSStackView()
        switchRow.orientation = .horizontal
        switchRow.alignment = .centerY
        switchRow.spacing = 8

        let switchLabel = NSTextField(labelWithString: "全局切换:")
        switchLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        btnIntegrated = NSButton(title: "仅核显 (Integrated)", target: self, action: #selector(onSwitchIntegrated))
        btnIntegrated.bezelStyle = .rounded

        btnDynamic = NSButton(title: "自动切换 (Dynamic)", target: self, action: #selector(onSwitchDynamic))
        btnDynamic.bezelStyle = .rounded

        btnDiscrete = NSButton(title: "仅独显 (Discrete)", target: self, action: #selector(onSwitchDiscrete))
        btnDiscrete.bezelStyle = .rounded

        chkPersistPmset = NSButton(checkboxWithTitle: "写入系统 pmset (需授权)", target: nil, action: nil)
        chkPersistPmset.state = .on
        chkPersistPmset.font = NSFont.systemFont(ofSize: 11)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        btnCleanLocks = NSButton(title: "一键退出可关闭的独显锁进程", target: self, action: #selector(onCleanLockProcesses))
        btnCleanLocks.bezelStyle = .rounded

        switchRow.addArrangedSubview(switchLabel)
        switchRow.addArrangedSubview(btnIntegrated)
        switchRow.addArrangedSubview(btnDynamic)
        switchRow.addArrangedSubview(btnDiscrete)
        switchRow.addArrangedSubview(chkPersistPmset)
        switchRow.addArrangedSubview(spacer)
        switchRow.addArrangedSubview(btnCleanLocks)

        rootStack.addArrangedSubview(switchRow)
        switchRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -32).isActive = true

        // 3. Filter & Stats Bar
        let filterRow = NSStackView()
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 12

        statsLabel = NSTextField(labelWithString: "进程统计: ...")
        statsLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)

        chkOnlyDiscrete = NSButton(checkboxWithTitle: "仅看独显进程", target: self, action: #selector(onFilterChanged))
        chkOnlyDiscrete.state = .off

        chkAutoRefresh = NSButton(checkboxWithTitle: "自动刷新 (2s)", target: self, action: #selector(onAutoRefreshToggled))
        chkAutoRefresh.state = .on

        let btnRefresh = NSButton(title: "立即刷新", target: self, action: #selector(onManualRefresh))
        btnRefresh.bezelStyle = .rounded

        filterRow.addArrangedSubview(statsLabel)
        filterRow.addArrangedSubview(spacer2)
        filterRow.addArrangedSubview(chkOnlyDiscrete)
        filterRow.addArrangedSubview(chkAutoRefresh)
        filterRow.addArrangedSubview(btnRefresh)

        rootStack.addArrangedSubview(filterRow)
        filterRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -32).isActive = true

        // 4. Process TableView
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 32
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self

        let colApp = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        colApp.title = "应用 / 进程"
        colApp.width = 230
        colApp.minWidth = 160

        let colPid = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pid"))
        colPid.title = "PID"
        colPid.width = 65
        colPid.minWidth = 55

        let colCPU = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cpu"))
        colCPU.title = "CPU"
        colCPU.width = 70
        colCPU.minWidth = 60

        let colMem = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mem"))
        colMem.title = "内存"
        colMem.width = 80
        colMem.minWidth = 65

        let colGPU = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("gpu"))
        colGPU.title = "显卡状态"
        colGPU.width = 160
        colGPU.minWidth = 140

        let colDetail = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
        colDetail.title = "上下文详情"
        colDetail.width = 180
        colDetail.minWidth = 130

        let colAction = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        colAction.title = "操作"
        colAction.width = 155
        colAction.minWidth = 145

        tableView.addTableColumn(colApp)
        tableView.addTableColumn(colPid)
        tableView.addTableColumn(colCPU)
        tableView.addTableColumn(colMem)
        tableView.addTableColumn(colGPU)
        tableView.addTableColumn(colDetail)
        tableView.addTableColumn(colAction)

        scrollView.documentView = tableView
        rootStack.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -32).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        // 5. Footer
        footerLabel = NSTextField(labelWithString: "就绪")
        footerLabel.font = NSFont.systemFont(ofSize: 11)
        footerLabel.textColor = NSColor.secondaryLabelColor
        rootStack.addArrangedSubview(footerLabel)
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        // Timer scheduled on the default mode pauses while the user tracks a
        // mouse drag, types, or a modal (e.g. the quit confirmation) is up.
        // Common modes keep the list fresh during normal interaction.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func refreshNow() {
        let hw = GPUProcessMonitor.readHardwareStatus()
        let pmsetSwitch = GPUProcessMonitor.readPmsetGPUSwitch()
        let procs = GPUProcessMonitor.fetchProcesses(dgpuPowered: hw.dgpuPowered)

        allProcesses = procs
        applyFilterAndReload()

        let activeStr = withUnsafePointer(to: hw.activeGPU) {
            $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
        }
        let isDiscreteActive = (activeStr == "GFX0" || hw.dgpuPowered)

        // ── Compact mode header line ──────────────────────────────────────────
        let pmsetDesc: String
        switch pmsetSwitch {
        case 0: pmsetDesc = "仅核显"
        case 1: pmsetDesc = "仅独显"
        default: pmsetDesc = "自动切换"
        }
        if activeStr == "GFX0" {
            statusDotView.layer?.backgroundColor = NSColor.systemRed.cgColor
            statusTitleLabel.stringValue = "当前主显卡: 独显 (AMD R9 M370X)  ·  pmset: \(pmsetDesc)"
            statusTitleLabel.textColor = NSColor.systemRed
        } else {
            statusDotView.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusTitleLabel.stringValue = "当前主显卡: 核显 (Intel Iris Pro)  ·  pmset: \(pmsetDesc)  ·  独显供电: \(hw.dgpuPowered ? "通电" : "休眠")"
            statusTitleLabel.textColor = NSColor.secondaryLabelColor
        }

        // ── iGPU card ─────────────────────────────────────────────────────────
        let igpuPct = max(0, min(100, hw.igpuUtilPct >= 0 ? hw.igpuUtilPct : max(0, hw.igpuUnit0UtilPct)))
        igpuLoadBar.doubleValue = Double(igpuPct)
        igpuBigLabel.stringValue = "\(igpuPct)%"

        // badge: 活跃 or 空闲
        if igpuPct > 2 {
            igpuBadgeLabel.stringValue = "● 活跃"
            igpuBadgeLabel.textColor = NSColor.systemGreen
        } else {
            igpuBadgeLabel.stringValue = "● 空闲"
            igpuBadgeLabel.textColor = NSColor.tertiaryLabelColor
        }

        var igpuSub: [String] = []
        if hw.igpuUnit0UtilPct >= 0 && hw.igpuUnit0UtilPct != igpuPct {
            igpuSub.append("Unit0: \(hw.igpuUnit0UtilPct)%")
        }
        let igpuMemMB = hw.igpuUsedMemBytes / (1024 * 1024)
        if igpuMemMB > 0 { igpuSub.append("共享显存: \(igpuMemMB) MB") }
        igpuSubLabel.stringValue = igpuSub.joined(separator: "  ·  ")

        // ── dGPU card ─────────────────────────────────────────────────────────
        // Find the dGPU type label (tagged 1001) to update its color
        func findDgpuTypeLabel() -> NSTextField? {
            func search(_ v: NSView) -> NSTextField? {
                if let lbl = v as? NSTextField, lbl.tag == 1001 { return lbl }
                for sub in v.subviews { if let found = search(sub) { return found } }
                return nil
            }
            return search(dgpuCardView)
        }
        let dgpuTypeLbl = findDgpuTypeLabel()

        if isDiscreteActive {
            let dgpuPct = max(0, min(100, hw.dgpuUtilPct >= 0 ? hw.dgpuUtilPct : 0))
            dgpuLoadBar.doubleValue = Double(dgpuPct)
            dgpuBigLabel.stringValue = "\(dgpuPct)%"

            // 温度/负载颜色
            let hot = dgpuPct >= 60 || hw.dgpuTempC >= 85
            let warm = dgpuPct >= 30 || hw.dgpuTempC >= 70
            dgpuBigLabel.textColor = hot ? NSColor.systemRed : (warm ? NSColor.systemOrange : NSColor.systemRed)

            dgpuBadgeLabel.stringValue = "● 活跃"
            dgpuBadgeLabel.textColor = NSColor.systemRed
            dgpuTypeLbl?.textColor = NSColor.systemRed
            dgpuCardView.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.5).cgColor

            var dgpuSub: [String] = []
            if hw.dgpuTempC >= 0 { dgpuSub.append("\(hw.dgpuTempC)°C") }
            if hw.dgpuCoreClockMHz > 0 { dgpuSub.append("\(hw.dgpuCoreClockMHz) MHz") }
            if hw.dgpuUsedVRAMBytes > 0 {
                let usedMB = hw.dgpuUsedVRAMBytes / (1024 * 1024)
                let totalMB = (hw.dgpuUsedVRAMBytes + hw.dgpuFreeVRAMBytes) / (1024 * 1024)
                dgpuSub.append("显存: \(usedMB)/\(totalMB) MB")
            }
            dgpuSubLabel.stringValue = dgpuSub.joined(separator: "  ·  ")
            dgpuSubLabel.textColor = NSColor.secondaryLabelColor
        } else {
            dgpuLoadBar.doubleValue = 0
            dgpuBigLabel.stringValue = "休眠"
            dgpuBigLabel.textColor = NSColor.tertiaryLabelColor
            dgpuBadgeLabel.stringValue = "● 休眠"
            dgpuBadgeLabel.textColor = NSColor.tertiaryLabelColor
            dgpuTypeLbl?.textColor = NSColor.systemRed.withAlphaComponent(0.4)
            dgpuCardView.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.2).cgColor
            dgpuSubLabel.stringValue = "独显已断电 · 省电模式"
            dgpuSubLabel.textColor = NSColor.tertiaryLabelColor
        }

        let lockCount = procs.filter { $0.hasDiscreteOpenGLLock || $0.hasDiscreteFramebuffer }.count
        let dgpuCount = procs.filter { $0.isActivelyUsingDiscrete }.count
        let igpuCount = procs.filter { !$0.isActivelyUsingDiscrete }.count

        statsLabel.stringValue = "共 \(procs.count) 个进程  |  🔥 独显锁: \(lockCount)  |  ⚡ 独显活跃: \(dgpuCount)  |  🌿 核显: \(igpuCount)"

        let cleanableLocks = procs.filter { ($0.hasDiscreteOpenGLLock || $0.hasDiscreteFramebuffer) && !$0.isProtected }
        btnCleanLocks.isEnabled = !cleanableLocks.isEmpty

        onStatusUpdated?(hw, procs)
    }

    private func applyFilterAndReload() {
        if chkOnlyDiscrete.state == .on {
            displayedProcesses = allProcesses.filter { $0.isActivelyUsingDiscrete }
        } else {
            displayedProcesses = allProcesses
        }
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func onSwitchIntegrated() {
        performGlobalSwitch(.integratedOnly)
    }

    @objc private func onSwitchDynamic() {
        performGlobalSwitch(.dynamicSwitching)
    }

    @objc private func onSwitchDiscrete() {
        performGlobalSwitch(.discreteOnly)
    }

    private func performGlobalSwitch(_ mode: GPUMode) {
        let persist = (chkPersistPmset.state == .on)
        let res = GPUProcessMonitor.switchGlobalMode(mode, persistWithPmset: persist)
        footerLabel.stringValue = res.message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshNow()
        }
    }

    @objc private func onCleanLockProcesses() {
        let targets = allProcesses.filter { ($0.hasDiscreteOpenGLLock || $0.hasDiscreteFramebuffer) && !$0.isProtected }
        guard !targets.isEmpty else { return }

        let names = targets.map { "• \($0.name) (PID \($0.pid))" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "确认退出以下 \(targets.count) 个锁死独显的进程？"
        alert.informativeText = names
        alert.addButton(withTitle: "全部退出")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            for proc in targets {
                _ = GPUProcessMonitor.terminateProcess(pid: proc.pid, force: false)
            }
            footerLabel.stringValue = "已向 \(targets.count) 个独显锁进程发送退出请求"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshNow()
            }
        }
    }

    @objc private func onFilterChanged() {
        applyFilterAndReload()
    }

    @objc private func onAutoRefreshToggled() {
        if chkAutoRefresh.state == .on {
            startTimer()
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    @objc private func onManualRefresh() {
        refreshNow()
        footerLabel.stringValue = "已刷新进程与显卡状态"
    }

    @objc private func onQuitRowProcess(_ sender: NSButton) {
        let pid = Int32(sender.tag)
        let res = GPUProcessMonitor.terminateProcess(pid: pid, force: false)
        footerLabel.stringValue = res.message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshNow()
        }
    }

    @objc private func onForceKillRowProcess(_ sender: NSButton) {
        let pid = Int32(sender.tag)
        let res = GPUProcessMonitor.terminateProcess(pid: pid, force: true)
        footerLabel.stringValue = res.message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshNow()
        }
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return displayedProcesses.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        let item = displayedProcesses[row]
        if item.hasDiscreteOpenGLLock || item.hasDiscreteFramebuffer {
            rowView.backgroundColor = NSColor.systemRed.withAlphaComponent(0.10)
        } else if item.isActivelyUsingDiscrete {
            rowView.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.06)
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier.rawValue else { return nil }
        let item = displayedProcesses[row]

        switch colId {
        case "app":
            let cell = NSView()
            let imgView = NSImageView(image: item.icon)
            imgView.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: item.name)
            label.lineBreakMode = .byTruncatingTail
            label.font = (item.hasDiscreteOpenGLLock || item.hasDiscreteFramebuffer)
                ? NSFont.systemFont(ofSize: 12, weight: .bold)
                : NSFont.systemFont(ofSize: 12, weight: .regular)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imgView)
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                imgView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imgView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imgView.widthAnchor.constraint(equalToConstant: 20),
                imgView.heightAnchor.constraint(equalToConstant: 20),
                label.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell

        case "pid":
            let label = NSTextField(labelWithString: "\(item.pid)")
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = NSColor.secondaryLabelColor
            return label

        case "cpu":
            let label = NSTextField(labelWithString: item.cpuText)
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            if let p = item.cpuPercent, p >= 50 {
                label.textColor = NSColor.systemOrange
            } else {
                label.textColor = NSColor.secondaryLabelColor
            }
            return label

        case "mem":
            let label = NSTextField(labelWithString: item.memoryText)
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = NSColor.secondaryLabelColor
            return label

        case "gpu":
            let container = NSView()
            let badge = NSTextField(labelWithString: " \(item.gpuBadgeText) ")
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 5
            badge.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            badge.translatesAutoresizingMaskIntoConstraints = false
            if item.hasDiscreteOpenGLLock || item.hasDiscreteFramebuffer {
                badge.layer?.backgroundColor = NSColor.systemRed.cgColor
                badge.textColor = NSColor.white
            } else if item.isActivelyUsingDiscrete {
                badge.layer?.backgroundColor = NSColor.systemOrange.cgColor
                badge.textColor = NSColor.white
            } else {
                badge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.18).cgColor
                badge.textColor = NSColor.labelColor
            }
            container.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                badge.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                badge.heightAnchor.constraint(equalToConstant: 20)
            ])
            return container

        case "detail":
            let label = NSTextField(labelWithString: item.detailText)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = NSColor.secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            return label

        case "action":
            let container = NSView()
            if item.isProtected {
                let protectedLabel = NSTextField(labelWithString: "系统关键进程")
                protectedLabel.font = NSFont.systemFont(ofSize: 11)
                protectedLabel.textColor = NSColor.tertiaryLabelColor
                protectedLabel.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(protectedLabel)
                NSLayoutConstraint.activate([
                    protectedLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
                    protectedLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
            } else {
                let btnQuit = NSButton(title: "退出", target: self, action: #selector(onQuitRowProcess(_:)))
                btnQuit.bezelStyle = .rounded
                btnQuit.controlSize = .small
                btnQuit.tag = Int(item.pid)
                btnQuit.translatesAutoresizingMaskIntoConstraints = false

                let btnKill = NSButton(title: "强杀", target: self, action: #selector(onForceKillRowProcess(_:)))
                btnKill.bezelStyle = .rounded
                btnKill.controlSize = .small
                btnKill.tag = Int(item.pid)
                btnKill.translatesAutoresizingMaskIntoConstraints = false

                container.addSubview(btnQuit)
                container.addSubview(btnKill)
                NSLayoutConstraint.activate([
                    btnQuit.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                    btnQuit.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                    btnKill.leadingAnchor.constraint(equalTo: btnQuit.trailingAnchor, constant: 6),
                    btnKill.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
            }
            return container

        default:
            return nil
        }
    }
}

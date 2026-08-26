import AppKit
import IOKit.ps
import ApplicationServices

final class ScreenUnit {
    let screen: NSScreen
    let window: DesktopWindow
    let host: AnimationHost
    /// 状态卡独立成窗，挂在图标层之上，不受动画窗口层级牵连；原生绘制，不用 WebView
    let hudWindow: HUDWindow
    let hudView: HUDView
    var rendering = true
    var hudSize = CGSize(width: 232, height: 86)

    init(screen: NSScreen, animation: String, levelOverride: Int? = nil, small: Bool = false) {
        self.screen = screen
        window = DesktopWindow(screen: screen, levelOverride: levelOverride, small: small)
        host = AnimationHost()
        host.webView.frame = window.contentView?.bounds ?? screen.frame
        window.contentView?.addSubview(host.webView)
        host.load(animation)
        window.orderFront(nil)

        hudWindow = HUDWindow(screen: screen)
        hudView = HUDView(frame: hudWindow.contentView?.bounds ?? .zero)
        hudView.autoresizingMask = [.width, .height]
        hudWindow.contentView = hudView
        hudWindow.orderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var units: [ScreenUnit] = []
    private var statusItem: NSStatusItem!
    private let probe = ClaudeStateProbe()
    private var timer: Timer?
    private var state = ClaudeState()
    private var animation = UserDefaults.standard.string(forKey: "animation") ?? "jarvis.html"
    private var manuallyPaused = false

    // 诊断
    private var lastCoverage: Double = 0
    private var lastOccluded = false
    private var coverageMillis: Double = 0
    private var diagHandle: FileHandle?
    private var lastVis = "?"
    private var lastFrames = 0
    private var prevFrames = 0
    private var pauseSignal: DispatchSourceSignal?
    private var cycleSignal: DispatchSourceSignal?
    private let logDiagnostics = CommandLine.arguments.contains("--log")
    // 测量用：绕开自动闸门，保证各动画在同一条件下可比
    private let forceRender = CommandLine.arguments.contains("--force-render")
    private let forcePause  = CommandLine.arguments.contains("--force-pause")
    private let noProbe     = CommandLine.arguments.contains("--no-probe")

    func applicationDidFinishLaunching(_ n: Notification) {
        if let idx = CommandLine.arguments.firstIndex(of: "--animation"),
           idx + 1 < CommandLine.arguments.count { animation = CommandLine.arguments[idx + 1] }

        rebuildScreens()
        units.forEach { $0.hudWindow.setClickThrough(UserDefaults.standard.bool(forKey: "hudClickThrough")) }
        units.forEach { $0.hudView.update(state); $0.hudSize = $0.hudView.cardSize }
        layoutHUDs()
        installMouseTracking()
        buildStatusItem()
        if logDiagnostics { openDiagLog() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildScreens),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)

        // 便于自动化测量：kill -USR1 <pid> 切换渲染开关
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.togglePause() }
        src.resume()
        pauseSignal = src

        // 菜单栏图标在刘海屏上可能被挤掉，命令行必须能独立控制
        signal(SIGUSR2, SIG_IGN)
        let src2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        src2.setEventHandler { [weak self] in self?.cycleAnimation() }
        src2.resume()
        cycleSignal = src2

        tick()

        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                guard let u = self?.units.first else { return }
                u.host.webView.evaluateJavaScript(
                    "JSON.stringify({diag: window.__ldDiag(), 动画页残留HUD: !!document.getElementById('ld-hud')})"
                ) { r, e in
                    FileHandle.standardError.write("[selftest 动画页] \(r as? String ?? "nil") err=\(e?.localizedDescription ?? "-")\n".data(using: .utf8)!)
                }
                let tl = self?.state.recentTools.prefix(6).map { "\($0.tool)/\($0.project)/-\($0.agoSeconds)s" }.joined(separator: "  ") ?? ""
                FileHandle.standardError.write("[selftest 工具流] \(tl)\n".data(using: .utf8)!)
                let f = u.hudWindow.frame
                FileHandle.standardError.write(
                    "[selftest HUD窗] 原生绘制 卡片=\(Int(u.hudSize.width))x\(Int(u.hudSize.height)) 窗口=\(Int(f.width))x\(Int(f.height)) @\(Int(f.minX)),\(Int(f.minY))\n".data(using: .utf8)!)
            }
        }
    }

    @objc private func rebuildScreens() {
        units.forEach { $0.window.orderOut(nil) }
        let oldUnits = units
        _ = oldUnits
        var lv: Int? = nil
        if let i = CommandLine.arguments.firstIndex(of: "--level"), i+1 < CommandLine.arguments.count {
            lv = Int(CommandLine.arguments[i+1])
        }
        let small = CommandLine.arguments.contains("--small")
        units = NSScreen.screens.map { ScreenUnit(screen: $0, animation: animation, levelOverride: lv, small: small) }
    }

    // MARK: - 每秒一拍：探测状态 + 决定是否渲染

    // MARK: - HUD 定位（现在是窗口定位，不再是页面内 CSS 定位）

    private var hudEditing = false
    private var hudEditTimer: Timer?
    private var hudMoveObserver: Any?

    private func pushHudState(to u: ScreenUnit) {
        u.hudView.update(state)
        let newSize = u.hudView.cardSize
        guard newSize != u.hudSize else { return }
        u.hudSize = newSize
        // 拖动中只改尺寸不动位置，否则会把窗口从用户手里拽走
        if dragOffset != nil || hudEditing {
            u.hudWindow.setContentSize(newSize)
        } else {
            layoutHUDs()
        }
    }

    /// 自由坐标只对主屏生效，其余屏回落到 anchor
    private var programmaticMove = false
    private var saveTimer: Timer?
    private var dragTimer: Timer?
    private var wasPressed = false
    private var dragOffset: CGSize?
    private var loggedFirstHit = false

    private func layoutHUDs() {
        programmaticMove = true
        defer { DispatchQueue.main.async { self.programmaticMove = false } }
        let d = UserDefaults.standard
        let hasFree = d.object(forKey: "hudX") != nil
        for (i, u) in units.enumerated() {
            let size = u.hudSize
            var origin: CGPoint
            if hasFree && i == 0 {
                origin = CGPoint(x: d.double(forKey: "hudX"), y: d.double(forKey: "hudY"))
            } else {
                origin = anchorOrigin(d.string(forKey: "hudAnchor") ?? "br", u.screen, size)
            }
            // 夹回屏内，避免改分辨率/拔显示器后跑到看不见的地方
            let vf = u.screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - size.width))
            origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - size.height))
            u.hudWindow.setFrame(CGRect(origin: origin, size: size), display: true)
        }
    }

    /// 不允许把卡片拖出屏幕 —— 拖丢了就再也找不回来
    private func clampToScreen(_ p: CGPoint, size: CGSize, screen: NSScreen) -> CGPoint {
        let vf = screen.visibleFrame
        return CGPoint(x: min(max(p.x, vf.minX), max(vf.minX, vf.maxX - size.width)),
                       y: min(max(p.y, vf.minY), max(vf.minY, vf.maxY - size.height)))
    }

    private func anchorOrigin(_ anchor: String, _ screen: NSScreen, _ size: CGSize) -> CGPoint {
        let m: CGFloat = 24
        let f = screen.visibleFrame     // 用 visibleFrame 自动避开菜单栏与 Dock
        let v = anchor.first ?? "b", h = anchor.last ?? "r"
        let x: CGFloat = h == "l" ? f.minX + m : (h == "r" ? f.maxX - size.width - m : f.midX - size.width / 2)
        let y: CGFloat = v == "b" ? f.minY + m : (v == "t" ? f.maxY - size.height - m : f.midY - size.height / 2)
        return CGPoint(x: x, y: y)
    }

    /// 轮询鼠标状态驱动拖动。
    /// 桌面层窗口收不到常规鼠标事件；而 addGlobalMonitorForEvents 在未取得输入监听权限时
    /// 同样一个事件都收不到。NSEvent.mouseLocation / pressedMouseButtons 是静态属性，
    /// 读取不需要任何权限，因此这是此处唯一稳妥的路子。
    private func installMouseTracking() {
        let trusted = AXIsProcessTrusted()
        FileHandle.standardError.write("[mouse] 轮询已启动，辅助功能权限=\(trusted)（本方案不依赖它）\n".data(using: .utf8)!)
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.pollMouse()
        }
        RunLoop.main.add(t, forMode: .common)
        dragTimer = t
    }

    private func pollMouse() {
        guard let u = units.first else { return }
        let pressed = (NSEvent.pressedMouseButtons & 1) != 0
        let p = NSEvent.mouseLocation
        defer { wasPressed = pressed }

        if pressed && !wasPressed {                       // 刚按下
            guard !UserDefaults.standard.bool(forKey: "hudClickThrough") else { return }
            let f = u.hudWindow.frame
            guard f.contains(p) else { return }
            dragOffset = CGSize(width: p.x - f.minX, height: p.y - f.minY)
            u.hudView.setDragging(true)
            if !loggedFirstHit {
                loggedFirstHit = true
                FileHandle.standardError.write("[mouse] 命中状态卡，开始拖动\n".data(using: .utf8)!)
            }
        } else if pressed, let off = dragOffset {          // 拖动中
            let o = clampToScreen(CGPoint(x: p.x - off.width, y: p.y - off.height),
                                  size: u.hudWindow.frame.size, screen: u.screen)
            u.hudWindow.setFrameOrigin(o)
        } else if !pressed, dragOffset != nil {            // 松手
            dragOffset = nil
            u.hudView.setDragging(false)
            let f = u.hudWindow.frame
            UserDefaults.standard.set(Double(f.minX), forKey: "hudX")
            UserDefaults.standard.set(Double(f.minY), forKey: "hudY")
            FileHandle.standardError.write("[mouse] 拖动保存 \(Int(f.minX)),\(Int(f.minY))\n".data(using: .utf8)!)
        }
    }

    private func setClickThrough(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "hudClickThrough")
        units.forEach { $0.hudWindow.setClickThrough(on) }
    }

    private func startHudEdit() {
        guard let u = units.first, !hudEditing else { return }
        hudEditing = true
        u.hudWindow.setEditing(true)
        u.hudView.setDragging(true)
        hudMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: u.hudWindow, queue: .main
        ) { [weak self] _ in self?.scheduleHudEditFinish(1.5) }   // 松手静止 1.5s 即保存
        scheduleHudEditFinish(20)                                  // 完全没动则 20s 自动退出
    }

    private func scheduleHudEditFinish(_ delay: TimeInterval) {
        hudEditTimer?.invalidate()
        hudEditTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.finishHudEdit()
        }
    }

    private func finishHudEdit() {
        guard hudEditing, let u = units.first else { return }
        hudEditing = false
        hudEditTimer?.invalidate(); hudEditTimer = nil
        if let o = hudMoveObserver { NotificationCenter.default.removeObserver(o); hudMoveObserver = nil }
        let f = u.hudWindow.frame
        UserDefaults.standard.set(Double(f.minX), forKey: "hudX")
        UserDefaults.standard.set(Double(f.minY), forKey: "hudY")
        u.hudWindow.setEditing(false)
        u.hudView.setDragging(false)
        layoutHUDs()
        FileHandle.standardError.write("[hud] 位置已保存 \(Int(f.minX)),\(Int(f.minY))\n".data(using: .utf8)!)
    }

    private func setHudAnchor(_ a: String) {
        let d = UserDefaults.standard
        d.removeObject(forKey: "hudX"); d.removeObject(forKey: "hudY")
        d.set(a, forKey: "hudAnchor")
        layoutHUDs()
    }

    // MARK: - 控制文件（菜单栏在刘海屏可能不可用，命令行必须能全权控制）

    private let cmdPath = NSHomeDirectory() + "/.live-desktop.cmd"

    private func processCommands() {
        guard let txt = try? String(contentsOfFile: cmdPath, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: cmdPath)
        for line in txt.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard let cmd = parts.first else { continue }
            switch cmd {
            case "hud":
                let arg = parts.count > 1 ? parts[1] : "br"
                switch arg {
                case "edit":    startHudEdit()
                case "through": setClickThrough(true)
                case "drag":    setClickThrough(false)
                default:        setHudAnchor(arg)
                }
            case "next":  cycleAnimation()
            case "pause": togglePause()
            default: break
            }
        }
    }

    private func tick() {
        processCommands()
        if !noProbe { state = probe.probe() }

        let t0 = Date()
        let cov = units.enumerated().map { i, _ in
            DesktopCoverage.occludedFraction(of: NSScreen.screens[min(i, NSScreen.screens.count - 1)])
        }
        coverageMillis = Date().timeIntervalSince(t0) * 1000
        lastCoverage = cov.max() ?? 0

        for (i, unit) in units.enumerated() {
            unit.host.push(state: state)
            pushHudState(to: unit)
            let occluded = !unit.window.occlusionState.contains(.visible)
            if i == 0 { lastOccluded = occluded }
            let coverage = i < cov.count ? cov[i] : 0
            // 三道闸门：手动暂停 > AppKit 遮挡判定 > 几何覆盖率兜底
            let shouldRender: Bool
            if forceRender      { shouldRender = true }
            else if forcePause  { shouldRender = false }
            else                { shouldRender = !manuallyPaused && !occluded && coverage < 0.98 }
            if shouldRender != unit.rendering {
                unit.rendering = shouldRender
                unit.host.setRendering(shouldRender)
            }
        }
        units.first?.host.queryDiag { [weak self] d in
            guard let self else { return }
            self.lastVis = d["vis"] as? String ?? "?"
            self.prevFrames = self.lastFrames
            self.lastFrames = d["frames"] as? Int ?? 0
        }
        updateStatusIcon()
        if logDiagnostics { writeDiagLine() }
    }

    // MARK: - 电源

    private var onBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let s = d[kIOPSPowerSourceStateKey] as? String { return s == kIOPSBatteryPowerValue }
        }
        return false
    }

    // MARK: - 菜单栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()

        // 刘海屏菜单栏挤爆时系统会静默隐藏图标，这里把真实位置打出来便于判断
        if let w = statusItem.button?.window {
            let f = w.frame
            let msg = "[status] button=yes visible=\(statusItem.isVisible) frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) 屏宽=\(Int(NSScreen.main?.frame.width ?? 0))\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("[status] button 为 nil —— 菜单栏项未能创建\n".data(using: .utf8)!)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let b = self.statusItem?.button, let w = b.window else { return }
            let f = w.frame
            let msg = "[status+3s] frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) image=\(b.image != nil) visible=\(self.statusItem.isVisible)\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
        }
    }

    /// 菜单栏图标随状态变化本身就是产品功能的一部分
    private func updateStatusIcon() {
        let symbol: String, tint: NSColor?
        switch state.phase {
        case .idle:     symbol = "circle.dashed";        tint = nil
        case .thinking: symbol = "sparkles";             tint = NSColor.systemPurple
        case .running:  symbol = "bolt.horizontal.fill"; tint = NSColor.systemTeal
        case .waiting:  symbol = "bell.badge.fill";      tint = NSColor.systemOrange
        }
        guard let b = statusItem?.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude 状态")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true            // template + contentTintColor 才是染色的正道
        b.image = img
        b.contentTintColor = tint
        if img == nil {                   // SF Symbol 取不到时退回文字，保证一定看得见
            b.image = nil
            b.title = "◐"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let phaseLabel: [ClaudePhase: String] = [
            .idle: "空闲", .waiting: "等你输入", .thinking: "思考中", .running: "执行工具"
        ]
        var head = "Claude：\(phaseLabel[state.phase] ?? "?")"
        if let t = state.tool { head += " · \(t)" }
        if let p = state.project { head += " · \(p)" }
        menu.addItem(NSMenuItem(title: head, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "活跃会话 \(state.sessions.count) 个", action: nil, keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "切换动画", action: nil, keyEquivalent: ""))
        for name in units.first?.host.availableAnimations ?? [] {
            let it = NSMenuItem(title: "   " + name.replacingOccurrences(of: ".html", with: ""),
                                action: #selector(pickAnimation(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = name
            it.state = (name == animation) ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let hudItem = NSMenuItem(title: "状态卡位置", action: nil, keyEquivalent: "")
        menu.addItem(hudItem)
        let drag = NSMenuItem(title: "   拖动到任意位置…", action: #selector(beginHudEdit), keyEquivalent: "")
        drag.target = self
        menu.addItem(drag)
        let cur = UserDefaults.standard.object(forKey: "hudX") != nil
            ? "" : (UserDefaults.standard.string(forKey: "hudAnchor") ?? "br")
        for (code, name) in [("tl","左上"),("tr","右上"),("bl","左下"),("br","右下")] {
            let it = NSMenuItem(title: "   " + name, action: #selector(pickHudAnchor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = code
            it.state = (code == cur) ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let fps = units.first?.host.reportedFPS ?? 0
        menu.addItem(NSMenuItem(title: String(format: "渲染 %@ · %.0f fps", units.first?.rendering == true ? "开" : "停", fps), action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(format: "遮挡 occlusionState=%@ · 覆盖率 %.0f%%", lastOccluded ? "遮住" : "可见", lastCoverage * 100), action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(format: "探测 %.1fms · 覆盖计算 %.1fms · %@", state.probeMillis, coverageMillis, onBattery ? "电池" : "外接电源"), action: nil, keyEquivalent: ""))

        menu.addItem(.separator())
        let pause = NSMenuItem(title: manuallyPaused ? "恢复动画" : "暂停动画",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func pickAnimation(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        animation = name
        UserDefaults.standard.set(name, forKey: "animation")
        units.forEach { $0.host.load(name) }
    }

    @objc private func togglePause() { manuallyPaused.toggle(); tick() }
    @objc private func beginHudEdit() { startHudEdit() }
    @objc private func pickHudAnchor(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? String else { return }
        setHudAnchor(a)
    }

    private func cycleAnimation() {
        let all = units.first?.host.availableAnimations ?? []
        guard !all.isEmpty else { return }
        let next = all[((all.firstIndex(of: animation) ?? -1) + 1) % all.count]
        animation = next
        UserDefaults.standard.set(next, forKey: "animation")
        units.forEach { $0.host.load(next) }
        FileHandle.standardError.write("[anim] 切换到 \(next)\n".data(using: .utf8)!)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 诊断日志

    private func openDiagLog() {
        let path = FileManager.default.currentDirectoryPath + "/diag.csv"
        FileManager.default.createFile(atPath: path, contents:
            "ts,phase,tool,sessions,occluded,coverage,rendering,fps,probeMs,coverageMs,battery,vis,realFps\n".data(using: .utf8))
        diagHandle = FileHandle(forWritingAtPath: path)
        diagHandle?.seekToEndOfFile()
        FileHandle.standardError.write("[diag] 写入 \(path)\n".data(using: .utf8)!)
    }

    private func writeDiagLine() {
        let line = String(format: "%@,%@,%@,%d,%d,%.3f,%d,%.0f,%.2f,%.2f,%d,%@,%d\n",
                          ISO8601DateFormatter().string(from: Date()),
                          state.phase.rawValue, state.tool ?? "", state.sessions.count,
                          lastOccluded ? 1 : 0, lastCoverage,
                          units.first?.rendering == true ? 1 : 0,
                          units.first?.host.reportedFPS ?? 0,
                          state.probeMillis, coverageMillis, onBattery ? 1 : 0,
                          lastVis, max(0, lastFrames - prevFrames))
        diagHandle?.write(line.data(using: .utf8)!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

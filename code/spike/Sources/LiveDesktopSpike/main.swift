import AppKit
import IOKit.ps
import ApplicationServices

final class ScreenUnit {
    /// 显示器参数变化时会换成新的 NSScreen 对象，身份认 displayID
    private(set) var screen: NSScreen
    let displayID: CGDirectDisplayID
    let window: DesktopWindow
    let host: AnimationHost
    /// 状态卡独立成窗，挂在图标层之上，不受动画窗口层级牵连；原生绘制，不用 WebView
    let hudWindow: HUDWindow
    let hudView: HUDView
    var rendering = true
    var hudSize = CGSize(width: 232, height: 86)
    private let small: Bool

    init(screen: NSScreen, animation: String, levelOverride: Int? = nil, small: Bool = false) {
        self.screen = screen
        self.displayID = ScreenUnit.displayID(of: screen)
        self.small = small
        window = DesktopWindow(screen: screen, levelOverride: levelOverride, small: small)
        host = AnimationHost()
        host.webView.frame = window.contentView?.bounds ?? screen.frame
        window.contentView?.addSubview(host.webView)
        host.load(animation)
        host.pushConfig(Prefs.config(skin: animation))     // 页面就绪时连同状态一起补发
        host.visibleInsets = ScreenUnit.insets(of: screen)
        window.orderFront(nil)

        hudWindow = HUDWindow(screen: screen)
        hudView = HUDView(frame: hudWindow.contentView?.bounds ?? .zero)
        hudView.autoresizingMask = [.width, .height]
        hudWindow.contentView = hudView
        hudWindow.orderFront(nil)
    }

    /// 可见桌面相对屏幕 frame 的四边内缩量（点，页面坐标系 y 向下：top 是菜单栏、bottom 通常是 Dock）
    static func insets(of s: NSScreen) -> [String: Double] {
        let f = s.frame, v = s.visibleFrame
        return ["top": f.maxY - v.maxY, "bottom": v.minY - f.minY, "left": v.minX - f.minX, "right": f.maxX - v.maxX]
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// 显示器还在、只是参数变了（分辨率 / 排列 / Dock）：重贴 frame 即可，不重建 WebView
    func refit(to newScreen: NSScreen) {
        screen = newScreen
        host.visibleInsets = ScreenUnit.insets(of: newScreen)   // Dock 挪了 / 菜单栏高度变了，页面里的"桌面边缘"跟着变
        guard !small, window.frame != newScreen.frame else { return }
        window.setFrame(newScreen.frame, display: true)
    }

    /// 显示器拔掉了：两个窗口都要真正下线。
    /// 只 orderOut 不够——窗口对象仍被 NSApp 持有，HUD 卡会继续留在屏上，WKWebView 的 WebContent 进程也不会退出。
    func tearDown() {
        hudWindow.orderOut(nil)
        hudWindow.close()
        host.shutdown()
        window.orderOut(nil)
        window.close()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var units: [ScreenUnit] = []
    private var statusItem: NSStatusItem!
    private let probe = ClaudeStateProbe()
    private let quotaProbe = QuotaProbe()
    private let systemProbe = SystemProbe()
    private let alerts = AlertEngine()
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
    private var sigtermSource: DispatchSourceSignal?
    private let logDiagnostics = CommandLine.arguments.contains("--log")
    // 测量用：绕开自动闸门，保证各动画在同一条件下可比
    private let forceRender = CommandLine.arguments.contains("--force-render")
    private let forcePause  = CommandLine.arguments.contains("--force-pause")
    private let noProbe     = CommandLine.arguments.contains("--no-probe")

    func applicationDidFinishLaunching(_ n: Notification) {
        if let idx = CommandLine.arguments.firstIndex(of: "--animation"),
           idx + 1 < CommandLine.arguments.count { animation = CommandLine.arguments[idx + 1] }

        AnimationHost.ensureUserSkinsDir(webDirectory: AnimationHost.bundledWebDirectory)   // 自定义皮肤目录 + 运行时同步
        // 旁听桌面上的左键点击（全局监视器只"看"发给别的 App 的事件，不拦截；我们的窗口本来就点击穿透，点击照常落到 Finder）
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.pushMouse(NSEvent.mouseLocation, down: true) }
        ModelServer.ensureUserModelsDir()                                                     // 自定义 3D 模型目录
        reconcileScreens()
        installMouseTracking()
        buildStatusItem()
        if logDiagnostics { openDiagLog() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // 系统休眠唤醒：FSEvents 长睡后可能丢事件、WebContent 可能已被回收、屏幕排列可能变了——醒来立刻全量对账一次，
        // 不等 30s 的定期自愈。（快速用户切换 / 息屏不用通知：闸门里每拍现查，见 tick）
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)

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
        // SIGTERM（./ld stop 的 pkill 默认信号）走温和退出：exit 0，launchd 的「异常才拉起」不会缠着重启
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        sigtermSource = term

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
                let ss = self?.state.sessions.map { "\($0.name ?? $0.project)[\($0.kind)]/\($0.parked ? "parked" : $0.stalled ? "stalled" : $0.phase.rawValue)/\($0.tool ?? "-")/\($0.idleSeconds)s" }.joined(separator: "  ") ?? ""
                FileHandle.standardError.write("[selftest 会话] 全局=\(self?.state.phase.rawValue ?? "?")  \(ss)\n".data(using: .utf8)!)
                for unit in self?.units ?? [] {
                    let f = unit.hudWindow.frame
                    FileHandle.standardError.write(
                        "[selftest HUD窗] 屏\(unit.displayID) 窗口=\(Int(f.width))x\(Int(f.height)) @\(Int(f.minX)),\(Int(f.minY)) 屏内偏移=\(Int(f.minX - unit.screen.frame.minX)),\(Int(f.minY - unit.screen.frame.minY))\n".data(using: .utf8)!)
                }
            }
        }
    }

    // MARK: - 休眠唤醒 / 退出

    @objc private func systemDidWake() {
        FileHandle.standardError.write("[power] 系统唤醒：强制对账一次\n".data(using: .utf8)!)
        probe.requestHeal()                                   // 下一拍全量 mtime 对账 + 注册表重读
        screenParametersDidChange()                           // 屏幕集合 / 排列可能在睡眠期间变了（合并防抖后处理）
        units.forEach { $0.host.setRendering($0.rendering) }  // 把渲染开关再推一次：页面若在睡眠期被重建，靠 ready 补推；没重建的也无害
        tick()
    }

    /// 注销 / 关机 / 菜单退出：把该关的关掉。以前没有这一步，diag.csv 最后一行可能被截断，WebContent 全靠系统回收
    func applicationWillTerminate(_ n: Notification) {
        try? diagHandle?.close()
        diagHandle = nil
        units.forEach { $0.tearDown() }
        units.removeAll()
    }

    /// 快速用户切换到别的账户后，我们的窗口留在后台登录会话里，occlusionState 未必判不可见——按 CGSession 的 on-console 位兜底。
    /// 读不到字典（极少见）当在前台，宁可多渲染也别把桌面搞黑
    private static var sessionOnConsole: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (d[kCGSessionOnConsoleKey as String] as? Bool) ?? true
    }

    // MARK: - 屏幕变化

    private var screenReconcileTimer: Timer?

    /// 接拔显示器 / 休眠唤醒时这条通知会成串到来（实测半小时内 109 次），
    /// 且回调当下 NSScreen.screens 未必已是最终值 —— 所以只合并，延后统一处理。
    @objc private func screenParametersDidChange() {
        screenReconcileTimer?.invalidate()
        let t = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in self?.reconcileScreens() }
        RunLoop.main.add(t, forMode: .common)
        screenReconcileTimer = t
    }

    /// 按 displayID 对账：还在的显示器只重贴 frame，拔掉的彻底下线，新接的才新建。
    /// 早先每次通知整套重建、又不下线旧 HUD 窗口，半小时漏出 109 张状态卡 + 110 个 WebContent 进程。
    private func reconcileScreens() {
        var lv: Int? = nil
        if let i = CommandLine.arguments.firstIndex(of: "--level"), i+1 < CommandLine.arguments.count {
            lv = Int(CommandLine.arguments[i+1])
        }
        let small = CommandLine.arguments.contains("--small")
        let screens = NSScreen.screens
        var kept: [ScreenUnit] = []
        var created = 0
        for s in screens {
            let id = ScreenUnit.displayID(of: s)
            if let u = units.first(where: { $0.displayID == id }) {
                u.refit(to: s)
                kept.append(u)
            } else {
                let unit = ScreenUnit(screen: s, animation: animation, levelOverride: lv, small: small)
                // 皮肤页面加载时会上报自己声明的设置项 schema，按当时加载的皮肤名登记
                unit.host.onPrefsSchema = { [weak self, weak unit] schema in
                    guard let self, let unit else { return }
                    self.registerSkinSchema(unit.host.currentAnimation, schema)
                }
                kept.append(unit)
                created += 1
            }
        }
        let gone = units.filter { u in !kept.contains { $0 === u } }
        gone.forEach { $0.tearDown() }
        units = kept
        if created > 0 || !gone.isEmpty {
            let through = UserDefaults.standard.bool(forKey: "hudClickThrough")
            let float = UserDefaults.standard.bool(forKey: "hudFloat")
            units.forEach { $0.hudWindow.setFloating(float); $0.hudWindow.setClickThrough(through) }
            FileHandle.standardError.write("[screens] 显示器 \(screens.count) 个：新建 \(created) 下线 \(gone.count)\n".data(using: .utf8)!)
        }
        // 新建的单元要立刻拿到当前状态与尺寸，否则要等下一拍才会从 (0,0) 挪到正确位置
        units.forEach { $0.hudView.update(state); $0.hudSize = $0.hudView.cardSize }
        // 拖动中 / 编辑中不重排，否则会把卡从用户手里拽走
        if dragOffset == nil && !hudEditing { layoutHUDs() }
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
    private var dragTimer: Timer?
    private var wasPressed = false
    private var dragOffset: CGSize?
    private var loggedFirstHit = false

    private func layoutHUDs() {
        programmaticMove = true
        defer { DispatchQueue.main.async { self.programmaticMove = false } }
        let d = UserDefaults.standard
        // 每块屏各自存位置（相对本屏原点的偏移）：早先自由坐标只给主屏，副屏拖完一秒内就被拽回锚点
        let saved = d.dictionary(forKey: "hudPositions") ?? [:]
        for (i, u) in units.enumerated() {
            let size = u.hudSize
            var origin: CGPoint
            // 宽容解析：runtime 存的是数字，手工 defaults write 进来的是字符串，都认
            if let arr = saved[String(u.displayID)] as? [Any], arr.count == 2,
               let dx = Self.num(arr[0]), let dy = Self.num(arr[1]) {
                origin = CGPoint(x: u.screen.frame.minX + dx, y: u.screen.frame.minY + dy)
            } else if i == 0, d.object(forKey: "hudX") != nil {
                // 旧格式（主屏绝对坐标）兼容，保存过一次新格式后就不再走这里
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

    private static func num(_ v: Any) -> Double? {
        (v as? NSNumber)?.doubleValue ?? Double(v as? String ?? "")
    }

    /// 按 displayID 记录该屏状态卡相对屏原点的偏移
    private func saveHudPosition(_ u: ScreenUnit) {
        let f = u.hudWindow.frame
        var saved = UserDefaults.standard.dictionary(forKey: "hudPositions") as? [String: [Double]] ?? [:]
        saved[String(u.displayID)] = [Double(f.minX - u.screen.frame.minX), Double(f.minY - u.screen.frame.minY)]
        UserDefaults.standard.set(saved, forKey: "hudPositions")
        FileHandle.standardError.write("[hud] 位置已保存 屏\(u.displayID) 偏移 \(Int(f.minX - u.screen.frame.minX)),\(Int(f.minY - u.screen.frame.minY))\n".data(using: .utf8)!)
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

    private var dragUnit: ScreenUnit?
    private var wasRightPressed = false

    /// 把全局鼠标位置换算成"光标所在屏"的页面坐标推给该屏页面；其他屏推一次 nil。只推给闸门开着（真在渲染）的屏——
    /// 桌面被盖住时页面看不见也不跑帧，推了白耗电。这是被动感知：不改窗口层级、不接管任何事件（决策 006）
    private func pushMouse(_ p: CGPoint, down: Bool) {
        for u in units {
            let f = u.screen.frame
            if u.rendering, f.contains(p) { u.host.pushMouse(p.x - f.minX, f.maxY - p.y, down: down) }
            else { u.host.pushMouse(nil, nil) }
        }
    }

    private func pollMouse() {
        let pressed = (NSEvent.pressedMouseButtons & 1) != 0
        let rightPressed = (NSEvent.pressedMouseButtons & 2) != 0
        let p = NSEvent.mouseLocation
        defer { wasPressed = pressed; wasRightPressed = rightPressed }
        pushMouse(p, down: false)

        // 右键状态卡 → 打开设置。菜单栏在刘海屏上可能被挤掉，状态卡是唯一一直看得见的入口
        if rightPressed && !wasRightPressed, units.contains(where: { $0.hudWindow.frame.contains(p) }) {
            openSettings()
            return
        }

        if pressed && !wasPressed {                       // 刚按下：命中任意一块屏的状态卡都算
            guard !UserDefaults.standard.bool(forKey: "hudClickThrough") else { return }
            guard let u = units.first(where: { $0.hudWindow.frame.contains(p) }) else { return }
            dragUnit = u
            let f = u.hudWindow.frame
            dragOffset = CGSize(width: p.x - f.minX, height: p.y - f.minY)
            u.hudView.setDragging(true)
            if !loggedFirstHit {
                loggedFirstHit = true
                FileHandle.standardError.write("[mouse] 命中状态卡（屏\(u.displayID)），开始拖动\n".data(using: .utf8)!)
            }
        } else if pressed, let off = dragOffset, let u = dragUnit {   // 拖动中
            let o = clampToScreen(CGPoint(x: p.x - off.width, y: p.y - off.height),
                                  size: u.hudWindow.frame.size, screen: u.screen)
            u.hudWindow.setFrameOrigin(o)
        } else if !pressed, dragOffset != nil {            // 松手：存到该屏名下
            if let u = dragUnit { u.hudView.setDragging(false); saveHudPosition(u) }
            dragOffset = nil
            dragUnit = nil
        }
    }

    func setClickThrough(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "hudClickThrough")
        units.forEach { $0.hudWindow.setClickThrough(on) }
    }

    /// 状态卡置顶悬浮：全局状态指引，不该只在桌面露出时才看得见
    func setHudFloat(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "hudFloat")
        units.forEach { $0.hudWindow.setFloating(on) }
        FileHandle.standardError.write("[hud] 置顶悬浮 \(on ? "开" : "关")\n".data(using: .utf8)!)
    }

    private func startHudEdit() {
        guard !units.isEmpty, !hudEditing else { return }
        hudEditing = true
        units.forEach { $0.hudWindow.setEditing(true); $0.hudView.setDragging(true) }   // 每块屏的卡都进入编辑
        hudMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, self.units.contains(where: { $0.hudWindow === n.object as? HUDWindow }) else { return }
            self.scheduleHudEditFinish(1.5)                        // 松手静止 1.5s 即保存
        }
        scheduleHudEditFinish(20)                                  // 完全没动则 20s 自动退出
    }

    private func scheduleHudEditFinish(_ delay: TimeInterval) {
        hudEditTimer?.invalidate()
        hudEditTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.finishHudEdit()
        }
    }

    private func finishHudEdit() {
        guard hudEditing, !units.isEmpty else { return }
        hudEditing = false
        hudEditTimer?.invalidate(); hudEditTimer = nil
        if let o = hudMoveObserver { NotificationCenter.default.removeObserver(o); hudMoveObserver = nil }
        for u in units {
            saveHudPosition(u)
            u.hudWindow.setEditing(false)
            u.hudView.setDragging(false)
        }
        layoutHUDs()
    }

    private func setHudAnchor(_ a: String) {
        let d = UserDefaults.standard
        d.removeObject(forKey: "hudX"); d.removeObject(forKey: "hudY")
        d.removeObject(forKey: "hudPositions")     // 吸附四角 = 清掉所有屏的自由位置
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
                case "float":   setHudFloat(true)
                case "desktop": setHudFloat(false)
                default:        setHudAnchor(arg)
                }
            case "celebrate":   // 手动触发一次庆祝动作（预览），转给所有屏的动画页面
                for u in units { u.host.webView.evaluateJavaScript("window.__ldCelebrate&&window.__ldCelebrate()") }
            case "next":  cycleAnimation()
            case "pause": togglePause()
            case "settings": openSettings()
            case "widget":   // widget <id> <slot>
                if parts.count > 2, Prefs.setWidget(parts[1], slot: parts[2]) { pushPrefs() }
            case "fx":       // fx <id> on|off
                if parts.count > 2, Prefs.setReaction(parts[1], on: parts[2] == "on") { pushPrefs() }
            case "model":    // model <内置名 | user/文件名>（文件名可含空格）
                if parts.count > 1, Prefs.setModel(parts.dropFirst().joined(separator: " ")) { pushPrefs() }
            case "skin":     // skin <id> <value> 改当前皮肤自声明的设置项；skin reset 恢复默认
                if parts.count == 2, parts[1] == "reset" { Prefs.resetSkin(animation); pushPrefs() }
                else if parts.count > 2 { Prefs.setSkinValue(animation, id: parts[1], value: Prefs.parseSkinValue(parts.dropFirst(2).joined(separator: " "))); pushPrefs() }
            default: break
            }
        }
    }

    private func tick() {
        processCommands()
        // 显示器集合对账兜底：拔线时 didChangeScreenParameters 不可靠（2026-08-27 实测两轮拔插
        // 都拖到插回才触发对账，残窗留了 24–29s），每拍比对 displayID 集合，不一致走既有防抖路径
        let current = Set(NSScreen.screens.map { ScreenUnit.displayID(of: $0) })
        if current != Set(units.map { $0.displayID }) { screenParametersDidChange() }
        if !noProbe { state = probe.probe() }
        state.quota = quotaProbe.read()
        systemProbe.sample(&state)      // 整机资源 + 各会话进程树占比 → state.system / sessions[].cpuPct
        alerts.tick(state)
        settings?.pushState(state)      // 设置预览喂的就是桌面这份真实状态

        let t0 = Date()
        let cov = units.map { DesktopCoverage.occludedFraction(of: $0.screen) }
        coverageMillis = Date().timeIntervalSince(t0) * 1000
        lastCoverage = cov.max() ?? 0

        let onConsole = Self.sessionOnConsole
        for (i, unit) in units.enumerated() {
            unit.host.push(state: state)
            pushHudState(to: unit)
            let occluded = !unit.window.occlusionState.contains(.visible)
            if i == 0 { lastOccluded = occluded }
            let coverage = i < cov.count ? cov[i] : 0
            // 该屏是否已息屏（屏保 / 节能 / 合盖）。WebKit 自己也会停 rAF（实测 0fps），这里是宿主侧的明确闸门
            let displayAsleep = CGDisplayIsAsleep(unit.displayID) != 0
            // 闸门：手动暂停 > AppKit 遮挡判定 > 几何覆盖率兜底 > 不在前台登录会话 / 息屏
            let shouldRender: Bool
            if forceRender      { shouldRender = true }
            else if forcePause  { shouldRender = false }
            else                { shouldRender = !manuallyPaused && !occluded && coverage < 0.98 && onConsole && !displayAsleep }
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)   // 要放得下等待数
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

    /// 菜单栏图标：自绘实色圆盘（阶段色）+ 反应堆式内环与核心，**非模板图**，任何菜单栏外观下都是一块彩色。
    /// 有会话在等你时，圆盘右侧直接显示等待数（橙色）——真实数据，也是菜单栏最该喊出来的一件事。
    /// 早先用 SF Symbol 模板图（15pt 细线、随阶段换形状），在十几个系统图标里根本认不出是谁的
    private func updateStatusIcon() {
        guard let b = statusItem?.button else { return }
        let color: NSColor = state.phase == .idle ? NSColor(white: 0.62, alpha: 1) : HUDView.accent(state.phase)
        let waiting = state.sessions.filter { $0.phase == .waiting }.count
        // 等待数直接画进同一张图：按钮自己排图 + 文字时基线对不齐，只有画在一起才能保证与圆盘垂直居中
        let badge: NSAttributedString? = waiting > 0 ? NSAttributedString(
            string: "\(waiting)",
            attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
                         .foregroundColor: HUDView.accent(.waiting)]) : nil
        let badgeW = badge.map { ceil($0.size().width) + 4 } ?? 0
        let h: CGFloat = 18
        let img = NSImage(size: NSSize(width: h + badgeW, height: h), flipped: false) { rect in
            let disc = CGRect(x: 1, y: 1, width: h - 2, height: h - 2)
            color.setFill()
            NSBezierPath(ovalIn: disc).fill()
            // 反应堆：深色内环 + 核心
            let ink = NSColor(white: 0.08, alpha: 0.85)
            ink.setStroke()
            let ring = NSBezierPath(ovalIn: disc.insetBy(dx: 4, dy: 4))
            ring.lineWidth = 1.6
            ring.stroke()
            ink.setFill()
            NSBezierPath(ovalIn: disc.insetBy(dx: 6.6, dy: 6.6)).fill()
            if let badge {
                let sz = badge.size()
                // 数字的视觉中心比排版框中心略低（数字没有下伸部），上抬 0.5 让它与圆盘居中
                badge.draw(at: CGPoint(x: h + 3, y: (h - sz.height) / 2 + 0.5))
            }
            return true
        }
        img.isTemplate = false
        b.image = img
        b.imagePosition = .imageOnly
        b.title = ""
        b.toolTip = "live-desktop · \(waiting > 0 ? "\(waiting) 个会话等你输入" : "Claude Code 状态")"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let phaseLabel: [ClaudePhase: String] = [
            .idle: "空闲", .waiting: "等你输入", .thinking: "思考中", .running: "执行工具"
        ]
        var head = "Claude：\(phaseLabel[state.phase] ?? "?")"
        if let t = state.tool { head += " · \(t)" }
        if let p = state.name ?? state.project { head += " · \(p)" }
        if !state.claudeDetected && state.sessions.isEmpty { head = "未检测到 Claude Code 会话记录（~/.claude 下没有 sessions / projects）" }
        menu.addItem(NSMenuItem(title: head, action: nil, keyEquivalent: ""))
        // 第二行把菜单栏图标旁那个数字解释清楚：它就是等你输入的会话数
        let waitingCount = state.sessions.filter { $0.phase == .waiting }.count
        menu.addItem(NSMenuItem(title: "活跃会话 \(state.sessions.count) 个" + (waitingCount > 0 ? " · \(waitingCount) 个等你输入（图标旁的数字）" : ""),
                                action: nil, keyEquivalent: ""))
        // 每个会话一行：等你输入的排最前
        let order: [ClaudePhase: Int] = [.waiting: 0, .running: 1, .thinking: 2, .idle: 3]
        for s in state.sessions.sorted(by: { (order[$0.phase] ?? 9, $0.kind == "bg" ? 1 : 0) < (order[$1.phase] ?? 9, $1.kind == "bg" ? 1 : 0) }) {
            var name = (s.nameIsUserSet ? s.name : nil) ?? s.project
            if s.kind == "bg" { name += "（后台）" }
            menu.addItem(NSMenuItem(title: "   \(name)  —  \(HUDView.statusText(s))", action: nil, keyEquivalent: ""))
        }
        if let q = state.quota, let f = q.fiveHour {
            var s = "额度 5h 已用 \(Int(f.usedPercentage.rounded()))%"
            if let r = f.resetsAt { s += r > Date() ? " · \(Self.hms(r.timeIntervalSinceNow)) 后重置" : " · 已重置" }
            if let w = q.sevenDay { s += " · 7d 已用 \(Int(w.usedPercentage.rounded()))%" }
            let age = Date().timeIntervalSince(q.recordedAt)
            if age > 600 { s += "（\(Int(age / 60)) 分钟前）" }
            menu.addItem(NSMenuItem(title: s, action: nil, keyEquivalent: ""))
        } else if state.quota == nil {
            // 没数据也不藏这一行：未接入给入口，已接入说明还在等数据（menuNeedsUpdate 只在开菜单时跑，读一次配置无妨）
            let st = QuotaInstaller.inspect()
            let title: String
            if st.installed     { title = "额度：已接入，等 Claude Code 刷新状态栏出数" }
            else if st.hasRecord { title = "额度：接入被顶掉 · 点击打开设置处理" }
            else                { title = "额度：未接入 · 点击打开设置接入" }
            let it = NSMenuItem(title: title,
                                action: st.installed ? nil : #selector(openSettings), keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }

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

        // 小工具：每个小工具一个子菜单选槽位；事件反应：逐项开关。改动即推给所有皮肤页面
        menu.addItem(.separator())
        let widgetRoot = NSMenuItem(title: "小工具", action: nil, keyEquivalent: "")
        let widgetMenu = NSMenu()
        let slots = Prefs.widgetSlots
        for w in Prefs.widgets {
            let item = NSMenuItem(title: "\(w.name)  ·  \(Prefs.slots.first { $0.id == slots[w.id] }?.name ?? "?")", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for s in Prefs.slots {
                let it = NSMenuItem(title: s.name, action: #selector(pickWidgetSlot(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = "\(w.id) \(s.id)"
                it.state = slots[w.id] == s.id ? .on : .off
                sub.addItem(it)
            }
            item.submenu = sub
            widgetMenu.addItem(item)
        }
        widgetRoot.submenu = widgetMenu
        menu.addItem(widgetRoot)
        let fxRoot = NSMenuItem(title: "事件反应", action: nil, keyEquivalent: "")
        let fxMenu = NSMenu()
        let flags = Prefs.reactionFlags
        for r in Prefs.reactions {
            let it = NSMenuItem(title: r.name, action: #selector(toggleReaction(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = r.id
            it.state = flags[r.id] == true ? .on : .off
            fxMenu.addItem(it)
        }
        fxRoot.submenu = fxMenu
        menu.addItem(fxRoot)

        menu.addItem(.separator())
        let hudItem = NSMenuItem(title: "状态卡位置", action: nil, keyEquivalent: "")
        menu.addItem(hudItem)
        let drag = NSMenuItem(title: "   拖动到任意位置…", action: #selector(beginHudEdit), keyEquivalent: "")
        drag.target = self
        menu.addItem(drag)
        let float = NSMenuItem(title: "   置顶悬浮（盖在所有窗口之上）", action: #selector(toggleHudFloat), keyEquivalent: "")
        float.target = self
        float.state = UserDefaults.standard.bool(forKey: "hudFloat") ? .on : .off
        menu.addItem(float)
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
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let pause = NSMenuItem(title: manuallyPaused ? "恢复动画" : "暂停动画",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private static func hms(_ t: TimeInterval) -> String {
        let s = max(0, Int(t)); return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    @objc private func pickAnimation(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        applyAnimation(name)
    }

    func pushPrefs() {
        units.forEach { $0.host.pushConfig(Prefs.config(skin: animation)) }
        settings?.pushConfig()
    }

    // MARK: - 皮肤自声明设置项：schema 来自页面运行时上报（桌面窗口或设置预览都可能先报），按皮肤名登记
    private var skinSchemas: [String: [[String: Any]]] = [:]
    func registerSkinSchema(_ skin: String, _ schema: [[String: Any]]) {
        skinSchemas[skin] = schema
        settings?.skinSchemaChanged(skin)
    }
    func skinSchema(for skin: String) -> [[String: Any]] { skinSchemas[skin] ?? [] }

    // MARK: - 设置窗口

    private var settings: SettingsWindowController?
    var currentAnimation: String { animation }
    var alertEngine: AlertEngine { alerts }     // 设置页显示 / 刷新系统通知授权状态

    @objc func openSettings() {
        if settings == nil { settings = SettingsWindowController(app: self) }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func settingsClosed() { settings = nil }

    /// 换皮肤的唯一入口：桌面各屏 + 设置预览一起换
    func applyAnimation(_ name: String) {
        animation = name
        UserDefaults.standard.set(name, forKey: "animation")
        units.forEach { $0.host.load(name); $0.host.pushConfig(Prefs.config(skin: name)) }   // 新皮肤的自声明设置值随就绪补发
        settings?.reloadSkin(name)
    }

    @objc private func pickWidgetSlot(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let p = s.split(separator: " ").map(String.init)
        guard p.count == 2, Prefs.setWidget(p[0], slot: p[1]) else { return }
        pushPrefs()
    }

    @objc private func toggleReaction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.setReaction(id, on: sender.state != .on)
        pushPrefs()
    }

    @objc private func togglePause() { manuallyPaused.toggle(); tick() }
    @objc private func beginHudEdit() { startHudEdit() }
    @objc private func toggleHudFloat() { setHudFloat(!UserDefaults.standard.bool(forKey: "hudFloat")) }
    @objc private func pickHudAnchor(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? String else { return }
        setHudAnchor(a)
    }

    private func cycleAnimation() {
        let all = units.first?.host.availableAnimations ?? []
        guard !all.isEmpty else { return }
        let next = all[((all.firstIndex(of: animation) ?? -1) + 1) % all.count]
        applyAnimation(next)
        FileHandle.standardError.write("[anim] 切换到 \(next)\n".data(using: .utf8)!)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 诊断日志

    // diag.csv 每秒一行、约 5.7 MB/天，是 P0 判据（./ld report）的唯一数据源：不能清空（重启 / launchd 拉起都要追加），
    // 也不能无限长（2026-08-28 已 12.5 MB，一年 2 GB）。按**本地日期**轮转：当前文件永远叫 diag.csv（report.py 与老习惯不变），
    // 跨天时改名为 diag-<最后一行的日期>.csv 归档，只保留最近 diagRetentionDays 天；report.py 会把归档一起读。
    // 写入用会抛 Swift 错误的 write(contentsOf:)：老的 write(_:) 在磁盘满时抛 ObjC 异常，Swift 接不住、进程直接崩
    private static let diagRetentionDays = 30
    private static let diagHeader = "ts,phase,tool,sessions,occluded,coverage,rendering,fps,probeMs,coverageMs,battery,vis,realFps\n"
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private var diagDay = ""                                   // 当前 diag.csv 对应的本地日期
    private var diagDir: String { FileManager.default.currentDirectoryPath }
    private var diagPath: String { diagDir + "/diag.csv" }

    private func openDiagLog() {
        let fm = FileManager.default
        let today = Self.dayFormatter.string(from: Date())
        // 上次运行留下的文件若属于更早的日期（mtime = 最后一行写入的那天），先归档再开新的
        if fm.fileExists(atPath: diagPath),
           let m = (try? fm.attributesOfItem(atPath: diagPath))?[.modificationDate] as? Date {
            let day = Self.dayFormatter.string(from: m)
            if day != today { archiveDiag(as: day) }
        }
        if !fm.fileExists(atPath: diagPath) {
            fm.createFile(atPath: diagPath, contents: Self.diagHeader.data(using: .utf8))
        }
        diagHandle = FileHandle(forWritingAtPath: diagPath)
        diagDay = today
        if let h = diagHandle {
            _ = try? h.seekToEnd()
            FileHandle.standardError.write("[diag] 写入 \(diagPath)\n".data(using: .utf8)!)
        } else {
            // 以前这里静默：cwd 不可写（如双击 .app 时 cwd=/）诊断就悄悄没了
            FileHandle.standardError.write("[diag] 打不开 \(diagPath)（目录不可写？），诊断日志停用\n".data(using: .utf8)!)
        }
        pruneDiagArchives()
    }

    /// diag.csv → diag-<day>.csv；同名已存在就加序号，绝不覆盖
    private func archiveDiag(as day: String) {
        let fm = FileManager.default
        var dst = diagDir + "/diag-\(day).csv"
        var n = 1
        while fm.fileExists(atPath: dst) { dst = diagDir + "/diag-\(day)-\(n).csv"; n += 1 }
        do {
            try fm.moveItem(atPath: diagPath, toPath: dst)
            FileHandle.standardError.write("[diag] 已归档 \(dst)\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("[diag] 归档失败：\(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }

    /// 删掉超过保留期的归档。文件名里的 yyyy-MM-dd 字典序即时间序
    private func pruneDiagArchives() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: diagDir) else { return }
        let cutoff = Self.dayFormatter.string(from: Date(timeIntervalSinceNow: -Double(Self.diagRetentionDays) * 86400))
        for n in names where n.hasPrefix("diag-") && n.hasSuffix(".csv") {
            let day = String(n.dropFirst("diag-".count).prefix(10))
            if day < cutoff { try? fm.removeItem(atPath: diagDir + "/" + n) }
        }
    }

    private func writeDiagLine() {
        guard diagHandle != nil else { return }
        let today = Self.dayFormatter.string(from: Date())
        if today != diagDay {                                  // 跨天：关掉、归档昨天的、开今天的
            try? diagHandle?.close()
            diagHandle = nil
            archiveDiag(as: diagDay)
            openDiagLog()
            guard diagHandle != nil else { return }
        }
        let line = String(format: "%@,%@,%@,%d,%d,%.3f,%d,%.0f,%.2f,%.2f,%d,%@,%d\n",
                          ISO8601DateFormatter().string(from: Date()),
                          state.phase.rawValue, state.tool ?? "", state.sessions.count,
                          lastOccluded ? 1 : 0, lastCoverage,
                          units.first?.rendering == true ? 1 : 0,
                          units.first?.host.reportedFPS ?? 0,
                          state.probeMillis, coverageMillis, onBattery ? 1 : 0,
                          lastVis, max(0, lastFrames - prevFrames))
        do {
            try diagHandle?.write(contentsOf: line.data(using: .utf8)!)
        } catch {
            // 磁盘满 / 文件被挪走：停掉诊断，主功能不受影响，也不再每秒重试
            FileHandle.standardError.write("[diag] 写入失败（\(error.localizedDescription)），诊断日志停用\n".data(using: .utf8)!)
            try? diagHandle?.close()
            diagHandle = nil
        }
    }
}

// 命令行模式：接入 / 卸载 / 查看额度数据源，不启动 UI（./ld quota on|off|status 调用这里）
if let i = CommandLine.arguments.firstIndex(of: "--quota") {
    exit(QuotaInstaller.run(Array(CommandLine.arguments[(i + 1)...])))
}

// 命令行模式：接入 / 卸载 / 查看 Notification hook 精细态数据源（./ld hooks on|off|status）
if let i = CommandLine.arguments.firstIndex(of: "--hooks") {
    exit(HooksInstaller.run(Array(CommandLine.arguments[(i + 1)...])))
}

// bundle id 去掉 .spike 后的一次性迁移（在一切 UserDefaults 读取之前）
Prefs.migrateFromSpikeDomain()
Autostart.migrateFromSpikeLabel()

// 命令行模式：探测一次并打印 JSON，不启动 UI。配 CLAUDE_CONFIG_DIR 可指向沙箱目录，测注册表缺失的回退路径
if CommandLine.arguments.contains("--probe-once") {
    var st = ClaudeStateProbe().probe()
    // 系统资源采两拍（隔 1s）：CPU / 磁盘吞吐是差分量，单拍只有 null
    let sys = SystemProbe(); sys.sample(&st); Thread.sleep(forTimeInterval: 1); sys.sample(&st)
    let obj = st.jsonObject
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write("状态序列化失败：某个数值字段是 NaN / Inf（键：\(obj.keys.sorted().joined(separator: ",")))\n".data(using: .utf8)!)
        exit(1)
    }
    print(text)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

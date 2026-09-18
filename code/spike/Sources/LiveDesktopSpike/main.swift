import AppKit
import IOKit.ps
import ApplicationServices

final class ScreenUnit {
    /// 显示器参数变化时会换成新的 NSScreen 对象，身份认 displayID
    private(set) var screen: NSScreen
    let displayID: CGDirectDisplayID
    let window: DesktopWindow
    let host: AnimationHost
    var rendering = true
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

    /// 显示器拔掉了：窗口要真正下线。
    /// 只 orderOut 不够——窗口对象仍被 NSApp 持有，WKWebView 的 WebContent 进程也不会退出。
    /// （状态卡不在这里：它全局只有一张、归 AppDelegate 管，决策 010）
    func tearDown() {
        host.shutdown()
        window.orderOut(nil)
        window.close()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var units: [ScreenUnit] = []
    /// 状态卡全局唯一一张（决策 010）：独立成窗、挂图标层之上、原生绘制；生命周期与显示器无关，
    /// 住在用户最后放它的那块屏（hudScreen），那块屏不在时临时落到主屏，插回即归位
    private lazy var hud = HUDController(onOpenSettings: { [weak self] in self?.openSettings() })
    private var statusBar: StatusItemController?
    private let probe = ClaudeStateProbe()
    private let quotaProbe = QuotaProbe()
    private let systemProbe = SystemProbe()
    private let alerts = AlertEngine()
    private var timer: Timer?
    private var state = ClaudeState()
    private var animation = Prefs.animation
    private var manuallyPaused = false

    // 诊断
    private var lastCoverage: Double = 0
    private var lastOccluded = false
    private var coverageMillis: Double = 0
    private var diag: DiagLogger?
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
        hud.layout()
        reconcileScreens()
        installMouseTracking()
        buildStatusBar()
        if logDiagnostics { diag = DiagLogger(); diag?.open() }

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

        // 首启引导：第一次运行弹一次欢迎面板（介绍入口 + 通知授权）。老用户升级也会看到一次，无妨
        if Prefs.consumeFirstLaunch() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showWelcome() }
        }

        if let i = CommandLine.arguments.firstIndex(of: "--settings") {     // 调试：启动即开设置窗，可带页码（截图验证用）
            let page = i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openSettings()
                if let page { self?.settings?.selectPage(page - 1) }
            }
        }

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
                if let line = self?.hud.selftestLine() {
                    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
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
        diag?.close()
        diag = nil
        units.forEach { $0.tearDown() }
        units.removeAll()
        hud.close()
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
            FileHandle.standardError.write("[screens] 显示器 \(screens.count) 个：新建 \(created) 下线 \(gone.count)\n".data(using: .utf8)!)
        }
        // 状态卡的家屏可能刚拔掉（临时落主屏）或刚插回（归位）；拖动中 / 编辑中不重排，否则会把卡从用户手里拽走
        hud.relayoutIfIdle()
    }

    // MARK: - 每秒一拍：探测状态 + 决定是否渲染

    // MARK: - 鼠标轮询（状态卡交互 + 被动输入感知共用这一条 30Hz 轮询）

    private var mouseTimer: Timer?

    /// 桌面层窗口收不到常规鼠标事件；而 addGlobalMonitorForEvents 在未取得输入监听权限时
    /// 同样一个事件都收不到。NSEvent.mouseLocation / pressedMouseButtons 是静态属性，
    /// 读取不需要任何权限，因此这是此处唯一稳妥的路子。
    /// 采到的位置分两路：状态卡交互（HUDController）与推给皮肤页面的被动感知（决策 006）。
    private func installMouseTracking() {
        let trusted = AXIsProcessTrusted()
        FileHandle.standardError.write("[mouse] 轮询已启动，辅助功能权限=\(trusted)（本方案不依赖它）\n".data(using: .utf8)!)
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            self.hud.handleMouse(at: p,
                                 leftDown: (NSEvent.pressedMouseButtons & 1) != 0,
                                 rightDown: (NSEvent.pressedMouseButtons & 2) != 0)
            self.pushMouse(p, down: false)
        }
        RunLoop.main.add(t, forMode: .common)
        mouseTimer = t
    }

    /// 把全局鼠标位置换算成"光标所在屏"的页面坐标推给该屏页面；其他屏推一次 nil。只推给闸门开着（真在渲染）的屏——
    /// 桌面被盖住时页面看不见也不跑帧，推了白耗电。这是被动感知：不改窗口层级、不接管任何事件（决策 006）
    private func pushMouse(_ p: CGPoint, down: Bool) {
        for u in units {
            let f = u.screen.frame
            if u.rendering, f.contains(p) { u.host.pushMouse(p.x - f.minX, f.maxY - p.y, down: down) }
            else { u.host.pushMouse(nil, nil) }
        }
    }

    // 状态卡的对外入口（菜单栏 / 设置页 / ./ld 命令共用），实现都在 HUDController
    func setClickThrough(_ on: Bool) { hud.setClickThrough(on) }
    func setHudFloat(_ on: Bool) { hud.setFloating(on) }
    func setHudAutoFloat(_ on: Bool) { hud.setAutoFloat(on) }

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
                case "edit":    hud.beginEdit()
                case "through": setClickThrough(true)
                case "drag":    setClickThrough(false)
                case "float":   setHudFloat(true)
                case "desktop": setHudFloat(false)
                case "auto":    if parts.count > 2 { setHudAutoFloat(parts[2] == "on") }
                default:        hud.setAnchor(arg)
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
        hud.update(state)
        for (i, unit) in units.enumerated() {
            unit.host.push(state: state)
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
        statusBar?.updateIcon(state)
        if logDiagnostics { writeDiagLine() }
    }

    // MARK: - 菜单栏（构建在 StatusItemController，这里只提供一份只读快照）

    private func buildStatusBar() {
        statusBar = StatusItemController(target: self) { [weak self] in
            guard let self else { return StatusItemController.Context(
                state: ClaudeState(), animations: [], currentAnimation: "", rendering: false, fps: 0,
                occluded: false, coverage: 0, coverageMillis: 0, onBattery: false, paused: false) }
            return StatusItemController.Context(
                state: self.state,
                animations: self.units.first?.host.availableAnimations ?? [],
                currentAnimation: self.animation,
                rendering: self.units.first?.rendering == true,
                fps: self.units.first?.host.reportedFPS ?? 0,
                occluded: self.lastOccluded,
                coverage: self.lastCoverage,
                coverageMillis: self.coverageMillis,
                onBattery: self.onBattery,
                paused: self.manuallyPaused)
        }
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


    private static func hms(_ t: TimeInterval) -> String {
        let s = max(0, Int(t)); return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    @objc func pickAnimation(_ sender: NSMenuItem) {
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
    private var welcome: WelcomeWindowController?

    /// 首启引导 / 使用说明（P2）：菜单「使用说明…」也走这里
    @objc func showWelcome() {
        if welcome == nil { welcome = WelcomeWindowController(app: self) }
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        if settings == nil { settings = SettingsWindowController(app: self) }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 深链接：打开设置并滚到某区块（菜单栏「点击接入」/ 欢迎面板用）。不与 openSettings 同名——#selector(openSettings) 会二义
    func revealSettings(_ section: String) {
        openSettings()
        settings?.reveal(section)
    }
    @objc func openSettingsForQuota() { revealSettings("quota") }
    @objc func openSettingsForHooks() { revealSettings("hooks") }

    func settingsClosed() { settings = nil }

    /// 换皮肤的唯一入口：桌面各屏 + 设置预览一起换
    func applyAnimation(_ name: String) {
        animation = name
        Prefs.setAnimation(name)
        units.forEach { $0.host.load(name); $0.host.pushConfig(Prefs.config(skin: name)) }   // 新皮肤的自声明设置值随就绪补发
        settings?.reloadSkin(name)
    }

    @objc func pickWidgetSlot(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let p = s.split(separator: " ").map(String.init)
        guard p.count == 2, Prefs.setWidget(p[0], slot: p[1]) else { return }
        pushPrefs()
    }

    @objc func toggleReaction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.setReaction(id, on: sender.state != .on)
        pushPrefs()
    }

    @objc func togglePause() { manuallyPaused.toggle(); tick() }
    @objc func beginHudEdit() { hud.beginEdit() }
    @objc func toggleHudFloat() { hud.setFloating(!Prefs.hudFloat) }
    @objc func toggleHudAutoFloat() { hud.setAutoFloat(!Prefs.hudAutoFloat) }
    @objc func pickHudAnchor(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? String else { return }
        hud.setAnchor(a)
    }

    private func cycleAnimation() {
        let all = units.first?.host.availableAnimations ?? []
        guard !all.isEmpty else { return }
        let next = all[((all.firstIndex(of: animation) ?? -1) + 1) % all.count]
        applyAnimation(next)
        FileHandle.standardError.write("[anim] 切换到 \(next)\n".data(using: .utf8)!)
    }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - 诊断日志（实现在 DiagLogger，这里只负责每拍取样）

    private func writeDiagLine() {
        diag?.write(DiagLogger.Sample(
            phase: state.phase.rawValue, tool: state.tool ?? "", sessions: state.sessions.count,
            occluded: lastOccluded, coverage: lastCoverage,
            rendering: units.first?.rendering == true,
            fps: units.first?.host.reportedFPS ?? 0,
            probeMillis: state.probeMillis, coverageMillis: coverageMillis,
            onBattery: onBattery, visibility: lastVis,
            realFrames: max(0, lastFrames - prevFrames)))
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

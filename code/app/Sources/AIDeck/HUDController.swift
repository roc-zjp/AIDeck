import AppKit

/// 状态卡这一张牌的全部：窗口与视图、定位（家屏 + 屏内偏移 / 四角吸附）、拖动与单击直达、
/// 编辑模式、按需浮现（决策 011）。**全局唯一一张**（决策 010），生命周期与显示器无关。
///
/// 从 AppDelegate 抽出来（2026-09-18）：这几件事共用一份「卡现在在哪、是不是正被用户操作」的状态，
/// 彼此耦合紧、与屏幕单元 / 菜单栏 / 探测器都无关，是一个完整的概念。
///
/// 事件来源：桌面层窗口收不到常规鼠标事件（见 issues.md），所以宿主 30Hz 轮询后经 `handleMouse` 喂进来。
final class HUDController {
    private let window = HUDWindow()
    private let view = HUDView(frame: CGRect(x: 0, y: 0, width: 260, height: 100))
    private var size = CGSize(width: 232, height: 86)
    private let onOpenSettings: () -> Void
    private var state = ClaudeState()

    /// 拖动 / 编辑进行中：屏幕对账与浮现都不该在这时动窗口，否则会把卡从用户手里拽走
    var isBusy: Bool { dragOffset != nil || editing }

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.setFloating(Prefs.hudFloat)
        window.setClickThrough(Prefs.hudClickThrough)
        window.orderFront(nil)
    }

    func close() { window.close() }

    // MARK: - 每拍

    /// 刷新内容与尺寸，并判断按需浮现。由 AppDelegate.tick 驱动
    func update(_ state: ClaudeState) {
        self.state = state
        view.update(state)
        let newSize = view.cardSize
        if newSize != size {
            size = newSize
            // 拖动中只改尺寸不动位置，否则会把窗口从用户手里拽走
            if isBusy { window.setContentSize(newSize) } else { layout() }
        }
        updateElevation()
    }

    // MARK: - 定位（决策 010：家屏 displayID + 屏内偏移）

    /// 家屏：用户最后把它放在哪块屏。没存过、或那块屏此刻不在，落到主屏
    /// （NSScreen.screens.first 是带菜单栏的主显示器，不随键盘焦点变）。家屏拔掉时不改写偏好，插回即归位
    private func homeScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let id = Prefs.hudScreenID,
           let s = screens.first(where: { Double(ScreenUnit.displayID(of: $0)) == id }) { return s }
        return screens.first
    }

    /// 位置 = 家屏 + 屏内偏移，改分辨率 / 重排屏幕后仍落在同一块屏的同一位置；
    /// 没有自由位置就按 hudAnchor 吸附家屏四角。最后夹回屏内，避免家屏换成更小的屏后跑到看不见的地方
    func layout() {
        guard let screen = homeScreen() else { return }
        let origin: CGPoint
        if let off = Prefs.hudOffset {
            origin = CGPoint(x: screen.frame.minX + off.x, y: screen.frame.minY + off.y)
        } else if let legacy = Prefs.legacyHudOrigin(screenID: ScreenUnit.displayID(of: screen),
                                                     screenOrigin: screen.frame.origin) {
            origin = legacy
        } else {
            origin = anchorOrigin(Prefs.hudAnchor, screen, size)
        }
        window.setFrame(CGRect(origin: clamp(origin, size: size, screen: screen), size: size), display: true)
    }

    /// 屏幕接拔 / 参数变化后重排；正被用户操作时跳过
    func relayoutIfIdle() { if !isBusy { layout() } }

    /// 松手 / 编辑结束：卡现在压在哪块屏（NSWindow.screen = 重叠最多的那块），就把那块屏记成家屏
    private func savePosition() {
        guard let screen = window.screen ?? homeScreen() else { return }
        let f = window.frame
        let id = ScreenUnit.displayID(of: screen)
        let offset = CGPoint(x: f.minX - screen.frame.minX, y: f.minY - screen.frame.minY)
        Prefs.setHudPosition(screenID: id, offset: offset)
        log("[hud] 位置已保存 家屏\(id) 偏移 \(Int(offset.x)),\(Int(offset.y))")
    }

    /// 不允许把卡片拖出屏幕 —— 拖丢了就再也找不回来
    private func clamp(_ p: CGPoint, size: CGSize, screen: NSScreen) -> CGPoint {
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

    // MARK: - 鼠标（宿主 30Hz 轮询喂进来；桌面层窗口收不到常规事件）

    private var wasLeft = false
    private var wasRight = false
    private var dragOffset: CGSize?
    private var pressPoint: CGPoint?                   // 按下位置：抬起时位移 < 4pt 算单击（直达终端），否则算拖动
    private var loggedFirstHit = false
    private var lastMousePos = NSEvent.mouseLocation   // 鼠标活动检测（决策 011「人回来了」）
    private var lastMouseActivity = Date()
    private var returnedFromIdle = false

    func handleMouse(at p: CGPoint, leftDown: Bool, rightDown: Bool) {
        defer { wasLeft = leftDown; wasRight = rightDown }

        // 鼠标从长时间静止转为活动 = 人回来了：给按需浮现一次重新展示的机会（决策 011）
        if p != lastMousePos || leftDown {
            if Date().timeIntervalSince(lastMouseActivity) >= TimeInterval(Prefs.hudAutoFloatIdleGapSeconds) {
                returnedFromIdle = true
            }
            lastMouseActivity = Date()
            lastMousePos = p
        }

        // 右键状态卡 → 打开设置。菜单栏在刘海屏上可能被挤掉，状态卡是唯一一直看得见的入口
        if rightDown && !wasRight, window.frame.contains(p) {
            onOpenSettings()
            return
        }

        if leftDown && !wasLeft {                          // 刚按下：命中状态卡
            guard !Prefs.hudClickThrough else { return }
            guard window.frame.contains(p) else { return }
            let f = window.frame
            dragOffset = CGSize(width: p.x - f.minX, height: p.y - f.minY)
            pressPoint = p
            view.setDragging(true)
            if !loggedFirstHit {
                loggedFirstHit = true
                log("[hud] 命中状态卡，开始拖动")
            }
        } else if leftDown, let off = dragOffset {          // 拖动中：光标在哪块屏就夹在哪块屏内——卡跟着光标跨屏，但不会卡在两屏之间的缝里
            let target = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? window.screen ?? NSScreen.screens.first
            if let s = target {
                window.setFrameOrigin(clamp(CGPoint(x: p.x - off.width, y: p.y - off.height),
                                            size: window.frame.size, screen: s))
            }
        } else if !leftDown, dragOffset != nil {            // 松手：位移 < 4pt 算单击（直达等待中的会话），否则按拖动收尾记家屏
            view.setDragging(false)
            if let start = pressPoint, hypot(p.x - start.x, p.y - start.y) < 4 {
                activateWaitingSession()
            } else {
                savePosition()
            }
            pressPoint = nil
            dragOffset = nil
        }
    }

    /// 单击状态卡 → 直达最该处理的会话所在终端（确认框优先，其次等最久的；与通知点击同一条路径）。
    /// 没有等待中的会话时单击不做任何事——状态卡不抢普通点击的语义。回退模式（无注册表）没有 pid，同样不动作
    private func activateWaitingSession() {
        let target = state.sessions
            .filter { $0.phase == .waiting && !$0.parked && $0.pid > 0 }
            .max { a, b in (a.attention != nil ? 1 : 0, a.idleSeconds) < (b.attention != nil ? 1 : 0, b.idleSeconds) }
        guard let target else { return }
        AlertEngine.activateApp(owning: target.pid)
        log("[hud] 单击直达 \(target.project)（pid \(target.pid)）")
    }

    // MARK: - 层级偏好

    func setClickThrough(_ on: Bool) {
        Prefs.setHudClickThrough(on)
        window.setClickThrough(on)
    }

    /// 置顶悬浮：全局状态指引，不该只在桌面露出时才看得见
    func setFloating(_ on: Bool) {
        Prefs.setHudFloat(on)
        window.setFloating(on)
        log("[hud] 置顶悬浮 \(on ? "开" : "关")")
    }

    func setAnchor(_ a: String) {
        Prefs.setHudAnchor(a)
        layout()
    }

    /// 关掉按需浮现时立即收回，不等下一拍
    func setAutoFloat(_ on: Bool) {
        Prefs.setHudAutoFloat(on)
        updateElevation()
    }

    // MARK: - 按需浮现（决策 011）

    private var elevated = false
    private var elevationDeadline: Date?          // 本轮浮现保持到此刻；新触发顺延，等待清空即失效
    private var elevationShown: Set<String> = []  // 本次等待已浮现过的会话（同 AlertEngine.waitingNotified 的跨越语义）

    /// 有会话等你（普通等待满宽限期；卡在确认框 / 表单立即）时，把状态卡临时升到悬浮层「拍一下肩膀」，
    /// 保持一小段时间或直到你回复。不无限压在窗口上——长期不回的等待由菜单栏与阈值通知兜底（决策 003）。
    /// 离开后回来（鼠标静止超过 idleGap 再动）时若仍有会话在等，再展示一轮。纯内存判断
    private func updateElevation() {
        var want = false
        if Prefs.hudAutoFloat, !Prefs.hudFloat {
            let grace = Prefs.hudAutoFloatGraceSeconds
            let qualifying = state.sessions.filter {
                $0.phase == .waiting && !$0.parked && ($0.attention != nil || $0.idleSeconds >= grace)
            }
            let fresh = qualifying.filter { !elevationShown.contains($0.id) }
            if !fresh.isEmpty || (returnedFromIdle && !qualifying.isEmpty) {
                elevationDeadline = Date().addingTimeInterval(TimeInterval(Prefs.hudAutoFloatHoldSeconds))
                fresh.forEach { elevationShown.insert($0.id) }
                if !fresh.isEmpty { view.flashAttention() }
            }
            // 等待结束（回复了 / 会话关了）出组，下次等待重新算「新」
            elevationShown.formIntersection(Set(state.sessions.filter { $0.phase == .waiting && !$0.parked }.map(\.id)))
            if qualifying.isEmpty { elevationDeadline = nil }
            want = elevationDeadline.map { Date() < $0 } ?? false
        }
        returnedFromIdle = false
        // 拖动 / 编辑进行中不切层级（会把卡从用户手里拽走），下一拍重试
        guard want != elevated, !isBusy else { return }
        elevated = want
        window.setElevated(want)
        log("[hud] 按需浮现\(want ? "升起" : "收回")")
    }

    // MARK: - 编辑模式（「我把它拖哪去了」时找回来）

    private var editing = false
    private var editTimer: Timer?
    private var moveObserver: Any?

    func beginEdit() {
        guard !editing else { return }
        editing = true
        window.setEditing(true); view.setDragging(true)
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.scheduleEditFinish(1.5)                       // 松手静止 1.5s 即保存
        }
        scheduleEditFinish(20)                                  // 完全没动则 20s 自动退出
    }

    private func scheduleEditFinish(_ delay: TimeInterval) {
        editTimer?.invalidate()
        editTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.finishEdit()
        }
    }

    private func finishEdit() {
        guard editing else { return }
        editing = false
        editTimer?.invalidate(); editTimer = nil
        if let o = moveObserver { NotificationCenter.default.removeObserver(o); moveObserver = nil }
        savePosition()
        window.setEditing(false)
        view.setDragging(false)
        layout()
    }

    // MARK: - 诊断

    /// `--selftest` 自报：窗口落在哪块屏、屏内偏移多少、全局是不是只有一张卡
    func selftestLine() -> String? {
        guard let home = homeScreen() else { return nil }
        let f = window.frame
        return "[selftest HUD窗] 家屏\(ScreenUnit.displayID(of: home)) 窗口=\(Int(f.width))x\(Int(f.height)) @\(Int(f.minX)),\(Int(f.minY)) 屏内偏移=\(Int(f.minX - home.frame.minX)),\(Int(f.minY - home.frame.minY)) 显示器=\(NSScreen.screens.count) 状态卡窗口数=\(NSApp.windows.filter { $0 is HUDWindow }.count)"
    }

    private func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}

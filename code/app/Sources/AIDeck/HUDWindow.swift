import AppKit

/// 状态卡窗口：**全局唯一一张**（决策 010，不按显示器复制），挂在**桌面图标层之上**，因此永远不会被图标压住；
/// 但仍低于普通应用窗口，所以只在桌面露出时可见——这正是它该有的行为。
/// 位置归 HUDController 管（家屏 + 屏内偏移），可跨屏拖到任意一块显示器。
final class HUDWindow: NSWindow {
    private var normalLevel: NSWindow.Level = .normal
    private var userFloat = false     // 常驻置顶（用户偏好，./ld hud float）
    private var elevated = false      // 按需浮现（决策 011）：有会话等你时宿主临时抬起
    private var hidden = false        // 总开关关闭（用户偏好，./ld hud off）：窗口下线，但位置与层级照常维护

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 260, height: 100),
                   styleMask: [.borderless], backing: .buffered, defer: false)

        normalLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        level = normalLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        // 默认就能直接用鼠标拖 —— 状态卡是桌面小组件，"要先敲命令才能移动"不合理。
        // 代价是它覆盖的那一小块点不到下面的图标，可用 ./ld hud through 换回穿透。
        ignoresMouseEvents = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        canHide = false
        isReleasedWhenClosed = false
    }

    /// 置顶悬浮（常驻，用户偏好）：状态卡是全局状态指引，可选择盖在所有应用窗口之上（低于菜单栏与 Dock），
    /// 并允许出现在全屏 App 的 Space 里；关闭则回到桌面图标层之上、只在桌面露出时可见。
    func setFloating(_ on: Bool) { userFloat = on; applyLevel() }

    /// 按需浮现（决策 011）：有会话等你时由宿主临时抬到悬浮层，回复后放下；与常驻置顶偏好互不覆盖
    func setElevated(_ on: Bool) { elevated = on; applyLevel() }

    /// 总开关：关掉即窗口下线（不是缩到看不见，是真的不在屏幕上）。
    /// 偏好与位置都不动，再打开回到原处；此后一切 orderFront 都要先过 hidden 这道闸
    func setHidden(_ on: Bool) { hidden = on; applyLevel() }

    /// 常驻置顶或按需浮现任一生效即上浮。
    /// 编辑模式进行中不动 level，结束时 setEditing(false) 会回到这里算出的 normalLevel。
    private func applyLevel() {
        let on = userFloat || elevated
        normalLevel = on ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, on ? .fullScreenAuxiliary : .fullScreenNone]
        if level != .floating || !on { level = normalLevel }
        guard !hidden else { orderOut(nil); return }
        if on { orderFrontRegardless() } else { orderFront(nil) }
    }

    /// 点击穿透开关：开启后状态卡不再拦截鼠标，但也就不能直接拖了
    func setClickThrough(_ on: Bool) {
        ignoresMouseEvents = on
        isMovableByWindowBackground = !on
    }

    /// 编辑模式：临时抬到浮动层并高亮，用于「我把它拖哪去了」时找回来。
    /// 平时不需要它——默认就能直接拖。
    func setEditing(_ on: Bool) {
        if on {
            level = .floating
            ignoresMouseEvents = false
            isMovableByWindowBackground = true
            orderFrontRegardless()
        } else {
            level = normalLevel
            let through = Prefs.hudClickThrough
            setClickThrough(through)
            if hidden { orderOut(nil) } else { orderFront(nil) }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

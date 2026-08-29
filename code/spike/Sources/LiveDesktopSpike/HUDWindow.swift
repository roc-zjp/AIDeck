import AppKit

/// 透明拖拽层，压在 WKWebView 之上。
/// 没有它，铺满窗口的 WebView 会吃掉 mouseDown，isMovableByWindowBackground 形同虚设。
/// 只负责在穿透关闭时"接住"点击，不让它落到下面的 Finder 桌面；
/// 实际拖动由 AppDelegate 的全局鼠标监听驱动 —— 桌面层窗口不参与正常事件路由，
/// performDrag / isMovableByWindowBackground 在这里都是失效的。
final class DragOverlay: NSView {
    override func mouseDown(with event: NSEvent) { /* 消费掉即可 */ }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard window?.ignoresMouseEvents == false else { return nil }
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// 状态卡窗口：**全局唯一一张**（决策 010，不按显示器复制），挂在**桌面图标层之上**，因此永远不会被图标压住；
/// 但仍低于普通应用窗口，所以只在桌面露出时可见——这正是它该有的行为。
/// 位置归 AppDelegate 管（家屏 + 屏内偏移），可跨屏拖到任意一块显示器。
final class HUDWindow: NSWindow {
    private var normalLevel: NSWindow.Level = .normal

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

    /// 置顶悬浮：状态卡是全局状态指引，可选择盖在所有应用窗口之上（低于菜单栏与 Dock），
    /// 并允许出现在全屏 App 的 Space 里；关闭则回到桌面图标层之上、只在桌面露出时可见。
    /// 编辑模式进行中不动 level，结束时 setEditing(false) 会回到这里设的 normalLevel。
    func setFloating(_ on: Bool) {
        normalLevel = on ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, on ? .fullScreenAuxiliary : .fullScreenNone]
        if level != .floating || !on { level = normalLevel }
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
            let through = UserDefaults.standard.bool(forKey: "hudClickThrough")
            setClickThrough(through)
            orderFront(nil)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

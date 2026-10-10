import AppKit

/// 每块显示器一个：动画窗口（图标层之下）+ 皮肤宿主。身份认 displayID，参数变化只重贴 frame，拔掉才下线
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

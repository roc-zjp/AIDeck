import AppKit
import WebKit

/// 动画宿主。动画本身是一个自包含 HTML 文件，切换动画 = 换文件。
/// 与页面的契约只有三个方法：
///   window.__ld.setState(obj)    宿主推送 Claude 状态
///   window.__ld.setRunning(bool) 宿主控制渲染开关（省电的关键闸门）
///   __ldReport({fps})            页面回报帧率（宿主用来验证闸门真的生效）
final class AnimationHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var currentAnimation: String = ""
    private(set) var reportedFPS: Double = 0
    private var pendingState: [String: Any]?
    private var ready = false
    /// HUD 页面量出的内容尺寸（含阴影余量），宿主据此调整窗口大小
    var onHudSize: ((Double, Double) -> Void)?
    /// 页面就绪（含每次切换动画后重新加载）
    var onReady: (() -> Void)?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = false
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        // 三管齐下：老 hack 在 macOS 26 上已不足以让 WebView 完全透明，
        // 否则窗口里会露出一块比内容大一圈的背景板
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.layer?.isOpaque = false
        super.init()
        // 必须注册到 webView.configuration：WKWebView 会拷贝传入的 configuration，
        // 往原对象上加 handler 页面里拿不到（window.webkit.messageHandlers.ld 为 undefined）
        webView.configuration.userContentController.add(self, name: "ld")
        webView.navigationDelegate = self
    }

    var webDirectory: URL {
        // 优先用 .app 里的资源；开发时回落到源码目录，方便改 HTML 后免重建
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/web")
    }

    var availableAnimations: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: webDirectory.path))?
            .filter { $0.hasSuffix(".html") && $0 != "hud.html" }.sorted() ?? []
    }

    func load(_ name: String) {
        let url = webDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        ready = false
        currentAnimation = name
        webView.loadFileURL(url, allowingReadAccessTo: webDirectory)
    }

    func push(state: ClaudeState) {
        let obj = state.jsonObject
        pendingState = obj
        guard ready else { return }
        pushRaw(obj)
    }

    /// 异步取页面自检数据（可见性/累计帧数），用于持续记录真实帧率
    func queryDiag(_ done: @escaping ([String: Any]) -> Void) {
        webView.evaluateJavaScript("JSON.stringify(window.__ldDiag ? window.__ldDiag() : {})") { r, _ in
            guard let s = r as? String, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { done([:]); return }
            done(o)
        }
    }

    func setHudEditing(_ on: Bool) {
        webView.evaluateJavaScript("window.__ldSetEditing && window.__ldSetEditing(\(on ? "true" : "false"));")
    }

    func setRendering(_ on: Bool) {
        webView.evaluateJavaScript("window.__ld && window.__ld.setRunning(\(on ? "true" : "false"));")
        if !on { reportedFPS = 0 }
    }

    // 兜底：即使页面没发 ready，导航完成后也允许推状态
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let p = pendingState { pushRaw(p) }
        onReady?()
    }

    private func pushRaw(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__ld && window.__ld.setState(\(s));")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let kind = body["kind"] as? String, kind == "ready" {
            ready = true
            if let p = pendingState { pushRaw(p) }
            onReady?()
        }
        if let fps = body["fps"] as? Double { reportedFPS = fps }
        if let kind = body["kind"] as? String, kind == "hudSize",
           let w = body["w"] as? Double, let h = body["h"] as? Double {
            onHudSize?(w, h)
        }
    }
}

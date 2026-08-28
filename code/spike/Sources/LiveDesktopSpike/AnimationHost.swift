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
    private var pendingConfig: [String: Any]?
    private var pendingRunning: Bool?      // 渲染开关也要缓存：页面就绪前推送会被静默吞掉，而 ld.js 默认 running=true
    private var ready = false
    /// HUD 页面量出的内容尺寸（含阴影余量），宿主据此调整窗口大小
    var onHudSize: ((Double, Double) -> Void)?
    /// 页面就绪（含每次切换动画后重新加载）
    var onReady: (() -> Void)?
    /// 可见桌面相对整块屏幕的四边内缩量（点）：菜单栏 / Dock 占掉的部分，来自 NSScreen.visibleFrame（真实事实，ScreenUnit 设置）。
    /// 页面拿它当"桌面边缘"——弹球皮肤的球不该滚到 Dock 后面。设置预览没有屏幕，保持为空
    var visibleInsets: [String: Double] = [:]
    /// 皮肤自声明的设置项 schema（页面 __ld.declarePrefs 上报），AppDelegate 据此渲染设置页
    var onPrefsSchema: (([[String: Any]]) -> Void)?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = false
        // 用户 3D 模型经 ld-model:// 供给页面；scheme handler 属于 configuration，必须在创建 WKWebView 之前挂上
        cfg.setURLSchemeHandler(ModelServer(), forURLScheme: ModelServer.scheme)
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

    var webDirectory: URL { Self.bundledWebDirectory }

    /// 内置皮肤目录：优先用 .app 里的资源；开发时回落到源码目录，方便改 HTML 后免重建
    static var bundledWebDirectory: URL {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/web")
    }

    /// 用户自定义皮肤目录：放进去的 *.html 自动出现在皮肤列表（名字带 user/ 前缀），不用重编译。
    /// 皮肤 HTML 里照常 `<script src="ld.js">` / `ld-widgets.js`——运行时文件由 ensureUserSkinsDir 同步进来
    static let userSkinsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/live-desktop/skins", isDirectory: true)
    static let userPrefix = "user/"

    var availableAnimations: [String] {
        let bundled = (try? FileManager.default.contentsOfDirectory(atPath: webDirectory.path))?
            .filter { $0.hasSuffix(".html") && $0 != "hud.html" }.sorted() ?? []
        let user = (try? FileManager.default.contentsOfDirectory(atPath: Self.userSkinsDir.path))?
            .filter { $0.hasSuffix(".html") && !$0.hasPrefix(".") }.sorted().map { Self.userPrefix + $0 } ?? []
        return bundled + user
    }

    func load(_ name: String) {
        let dir = name.hasPrefix(Self.userPrefix) ? Self.userSkinsDir : webDirectory
        let file = name.hasPrefix(Self.userPrefix) ? String(name.dropFirst(Self.userPrefix.count)) : name
        let url = dir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.log("[webkit] 皮肤文件不存在：\(url.path)，保持当前页面")
            return
        }
        ready = false
        currentAnimation = name
        webView.loadFileURL(url, allowingReadAccessTo: dir)
    }

    static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    // MARK: - 自愈：WebContent 进程没了不会自己回来

    /// WebContent 被系统杀掉（内存压力 / 长时间休眠后回收）时页面停在最后一帧或整块透明，不重载就是**永久黑屏**——
    /// 对常驻应用这是最致命的一类失败。重载走 load() 同一条路，pendingState / pendingConfig / pendingRunning 在 ready 时补推，状态不丢。
    /// 连续崩溃按 2^n 秒退避（上限 60s）：一个必崩的皮肤不能变成重载风暴
    private var crashCount = 0
    private var lastCrashAt = Date.distantPast

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        if now.timeIntervalSince(lastCrashAt) > 120 { crashCount = 0 }   // 两分钟没再崩就当新一轮
        crashCount += 1
        lastCrashAt = now
        ready = false
        reportedFPS = 0
        let delay = min(60.0, pow(2.0, Double(crashCount - 1)))
        let name = currentAnimation
        Self.log("[webkit] WebContent 进程终止（皮肤 \(name)，连续第 \(crashCount) 次），\(Int(delay))s 后重载")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // 期间用户换了皮肤 / 宿主已下线，load 已经或不再需要重建页面
            guard let self, self.webView.navigationDelegate != nil, self.currentAnimation == name else { return }
            self.load(name)
        }
    }

    /// 加载失败不能静默：用户自定义皮肤路径 / 权限出问题时桌面是黑的，日志里至少要有一行
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }   // 快速连切皮肤时上一次加载被取消，正常
        Self.log("[webkit] 皮肤 \(currentAnimation) 加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        Self.log("[webkit] 皮肤 \(currentAnimation) 导航出错：\(error.localizedDescription)")
    }

    /// 建好自定义皮肤目录，把运行时（ld.js / ld-widgets.js）同步进去，首次生成契约说明。
    /// 每次启动都同步：运行时升级后用户皮肤自动跟上，用户改的是自己的 HTML，不会被覆盖
    static func ensureUserSkinsDir(webDirectory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: userSkinsDir, withIntermediateDirectories: true)
        for f in ["ld.js", "ld-widgets.js", "ld-3d.js", "three.bundle.js"] {
            let src = webDirectory.appendingPathComponent(f), dst = userSkinsDir.appendingPathComponent(f)
            if let a = try? Data(contentsOf: src), (try? Data(contentsOf: dst)) != a { try? a.write(to: dst) }
        }
        let readme = userSkinsDir.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            try? """
            # live-desktop 自定义皮肤

            把任意自包含的 `*.html` 放在这个目录，它就会出现在皮肤列表里（名字前缀 `user/`）。
            最快的起点：在设置页点「新建皮肤（从模板）」，会复制一份内置皮肤到这里。

            ## 契约（页面必须做的事）
            - `<script src="ld.js"></script>`：核心运行时（状态→主题映射、帧循环闸门、消息通道），不要改它，每次启动会被同步覆盖
            - `__ld.loop((t, th, st) => { ... })`：每帧回调。`t` 时间，`th` 当前主题（bg/a/b 颜色、energy/speed/pulse），`st` 真实状态
            - `st` 结构：`phase`（idle/waiting/thinking/running）、`sessions[]`（含各会话进程树的 `cpuPct` / `memBytes`）、`recentTools[]`、`quota`、`repos[]`、
              `system`（整机 `cpuPct` / `gpuPct` / `memUsedBytes` / `diskReadBps`… 与 Claude 占比 `claudeCpuPct` / `claudeMemBytes`，拿不到的字段为 null）、`host`
            - 可选：`<script src="ld-widgets.js"></script>` 后在每帧末调 `__ldWidgets.draw(st, { key, hi })`，
              就得到与内置皮肤一致的小工具面板（槽位由用户在设置页配置，皮肤不用管）
            - 宿主会调用 `__ld.setState / setConfig / setRunning`，页面用 `__ldDiag()` 自检；这些都在 ld.js 里，皮肤无需实现
            - 可选：每帧调 `__ld.events(st, pw)` 拿真实事件 `{tool, phase, recharge, lowPower}`（pw 传 `__ldWidgets.computePower(st.quota)`），
              它已经按用户的「事件反应」开关过滤过；`__ld.flicker(t, remain)` 给低电量闪烁用。内置皮肤 matrix / radar / globe / circuit / warp 都是这样写的
            - 可选：`<script src="three.bundle.js"></script><script src="ld-3d.js"></script>` 后用 `__ld3d.Renderer(canvas)` 画全息风格 3D 模型，
              `__ld3d.loadModel(__ld.config.model)` 拿用户在设置页选的模型（内置程序化模型或 ~/.config/live-desktop/models 里的 .glb / .gltf / .fbx，带骨骼动画会动）。
              three.bundle.js 就是打包好的 Three.js（全局 LD_THREE），自定义皮肤也可以直接用它画别的。写法看内置皮肤 hologram
            - 可选：皮肤自己的设置项——加载时调一次 `__ld.declarePrefs([{ id, name, type: 'bool'|'number'|'choice', default, min/max/step 或 options }])`，
              设置页会出现「皮肤设置」区（复选框 / 滑杆 / 下拉），值按皮肤名保存并经 setConfig 推回，每帧读 `__ld.config.skin.<id>` 即可；`./ld skin <id> <值>` 也能改。
              例子看内置皮肤 bounce（重力开关 / 球数上限 / 球的大小）。宿主不认识任何具体 id，皮肤作者不需要改 Swift
            - 可选：被动输入感知——`__ld.mouse` 是光标在本屏的页面坐标 `{x, y, t}`（不在本屏为 null），`__ld.takeClicks()` 取走旁听到的桌面左键点击 `[{x, y, t}]`。
              宿主不拦截任何事件（点击照常落到 Finder / 图标），所以只能"感知"不能"接管"：适合球躲光标、点哪生成什么这类玩法，做不了需要键盘或精确点击的游戏。浏览器里调试时自动回落到 DOM 鼠标事件

            ## 纪律
            屏幕上每个数字都必须来自 `st` 里的真实数据——宁可留空，不许造假。动效随意，但只对真实事件发生。
            改完 HTML 后在设置页点「重新加载」即可看到效果。
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// 宿主下线。userContentController 强持有 handler（self），不摘掉就成环：
    /// AnimationHost ↔ WKWebView 永不释放，WebContent 进程跟着漏。
    func shutdown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "ld")
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        onHudSize = nil
        onReady = nil
        onPrefsSchema = nil
        ready = false
    }

    /// 机器开机时刻（epoch 秒）。页面上的 UPTIME 必须是真实的系统运行时长，不能拿页面存活时长冒充。
    private static let bootTime: Double = {
        var tv = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return 0 }
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }()

    func push(state: ClaudeState) {
        var obj = state.jsonObject
        // 宿主侧事实单独放 host 字段，与 Claude 状态分开，页面能看出数据来源。
        // pushedAt：本次推送时刻，页面用 pushedAt − ago 还原事件的绝对时间戳，不受页面自己时钟漂移影响
        var host: [String: Any] = ["pushedAt": Date().timeIntervalSince1970]
        if Self.bootTime > 0 { host["bootTime"] = Self.bootTime }
        if !visibleInsets.isEmpty { host["insets"] = visibleInsets }
        obj["host"] = host
        pendingState = obj
        guard ready else { return }
        pushRaw(obj)
    }

    /// 第四个契约口子：推送偏好（小工具槽位、事件反应开关）。页面未就绪先存着，就绪时连同状态一起补发
    func pushConfig(_ cfg: [String: Any]) {
        pendingConfig = cfg
        guard ready else { return }
        pushConfigRaw(cfg)
    }

    private func pushConfigRaw(_ cfg: [String: Any]) {
        guard let s = serialize(cfg, what: "setConfig") else { return }
        webView.evaluateJavaScript("window.__ld && window.__ld.setConfig(\(s));")
    }

    /// 序列化失败（NaN / Inf 混进了某个数值字段）以前是静默 no-op——页面从此再收不到更新、动画停在旧状态且零日志。
    /// 现在至少喊一声（每种推送只喊一次，别每秒刷屏）
    private var loggedSerializeFailure: Set<String> = []
    private func serialize(_ obj: [String: Any], what: String) -> String? {
        if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) { return s }
        if !loggedSerializeFailure.contains(what) {
            loggedSerializeFailure.insert(what)
            Self.log("[webkit] \(what) 序列化失败（数值字段含 NaN/Inf？），本次推送被丢弃：\(obj.keys.sorted().joined(separator: ","))")
        }
        return nil
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

    /// 被动输入感知：鼠标在本屏页面坐标里的位置（左上原点，点）与"刚发生一次左键点击"。不拦截任何事件——
    /// 位置来自宿主的轮询，点击来自全局旁听（NSEvent.addGlobalMonitorForEvents），Finder 照常收到点击。
    /// x/y 为 nil 表示光标不在本屏（只推一次）。同一位置不重复推；页面未就绪不推
    private var lastMouse: CGPoint?
    private var mouseGone = true
    func pushMouse(_ x: Double?, _ y: Double?, down: Bool = false) {
        guard ready else { return }
        guard let x, let y else {
            if !mouseGone { mouseGone = true; lastMouse = nil; webView.evaluateJavaScript("window.__ld && window.__ld.setMouse(null);") }
            return
        }
        let p = CGPoint(x: x, y: y)
        if !down, let l = lastMouse, abs(l.x - p.x) < 0.5, abs(l.y - p.y) < 0.5 { return }
        lastMouse = p; mouseGone = false
        webView.evaluateJavaScript(String(format: "window.__ld && window.__ld.setMouse(%.1f,%.1f,%@);", x, y, down ? "true" : "false"))
    }

    func setHudEditing(_ on: Bool) {
        webView.evaluateJavaScript("window.__ldSetEditing && window.__ldSetEditing(\(on ? "true" : "false"));")
    }

    /// 渲染开关（省电闸门）。意图存 pendingRunning：页面未就绪时 window.__ld 还不存在、这条 JS 是 no-op，
    /// 若丢掉 false 页面会按默认 running=true 白烧 GPU 直到 WebKit 自己判 hidden（约 1 分钟，见 issues.md）；
    /// 切皮肤重载同理——宿主只在开关变化时调用本方法，新页面必须靠 ready 回调补推
    func setRendering(_ on: Bool) {
        pendingRunning = on
        pushRunningRaw(on)
        if !on { reportedFPS = 0 }
    }

    private func pushRunningRaw(_ on: Bool) {
        webView.evaluateJavaScript("window.__ld && window.__ld.setRunning(\(on ? "true" : "false"));")
    }

    // 兜底：即使页面没发 ready，导航完成后也允许推状态
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let c = pendingConfig { pushConfigRaw(c) }
        if let p = pendingState { pushRaw(p) }
        if let r = pendingRunning { pushRunningRaw(r) }
        onReady?()
    }

    private func pushRaw(_ obj: [String: Any]) {
        guard let s = serialize(obj, what: "setState") else { return }
        webView.evaluateJavaScript("window.__ld && window.__ld.setState(\(s));")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let kind = body["kind"] as? String, kind == "ready" {
            ready = true
            if let c = pendingConfig { pushConfigRaw(c) }
            if let p = pendingState { pushRaw(p) }
            if let r = pendingRunning { pushRunningRaw(r) }
            onReady?()
        }
        if let fps = body["fps"] as? Double { reportedFPS = fps }
        if let kind = body["kind"] as? String, kind == "prefs", let schema = body["schema"] as? [[String: Any]] {
            onPrefsSchema?(schema)
        }
        if let kind = body["kind"] as? String, kind == "hudSize",
           let w = body["w"] as? Double, let h = body["h"] as? Double {
            onHudSize?(w, h)
        }
    }
}

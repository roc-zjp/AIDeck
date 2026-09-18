import AppKit

/// 菜单栏（三层感知的第二层：常驻哨兵）。图标自绘 + 下拉面板构建都在这里。
///
/// 从 AppDelegate 抽出来（2026-09-18）：菜单构建原本是个 136 行的长函数，且与状态卡、屏幕单元、
/// 探测器挤在同一个类里。现在它只依赖一份**只读快照**（`Context`）与一个 target——
/// 快照负责数据、target 负责动作，AppKit 的 target-action 模式照旧。
///
/// ⚠️ 刘海屏上菜单栏项可能被系统静默隐藏（实测落在 x=566），所以菜单栏**不能是唯一入口**：
/// 同样的能力在 `./ld` 命令与设置页里都有一份。
final class StatusItemController: NSObject, NSMenuDelegate {
    /// 构建菜单所需的一份只读快照。每次打开菜单时向宿主取，避免 controller 反向读 AppDelegate 的内部字段
    struct Context {
        var state: ClaudeState
        var animations: [String]
        var currentAnimation: String
        var rendering: Bool
        var fps: Double
        var occluded: Bool
        var coverage: Double
        var coverageMillis: Double
        var onBattery: Bool
        var paused: Bool
    }

    private var statusItem: NSStatusItem!
    private weak var target: AppDelegate?
    private let context: () -> Context
    private var state = ClaudeState()

    init(target: AppDelegate, context: @escaping () -> Context) {
        self.target = target
        self.context = context
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)   // 要放得下等待数
        statusItem.isVisible = true
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(state)

        // 刘海屏菜单栏挤爆时系统会静默隐藏图标，这里把真实位置打出来便于判断
        if let w = statusItem.button?.window {
            let f = w.frame
            log("[status] button=yes visible=\(statusItem.isVisible) frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) 屏宽=\(Int(NSScreen.main?.frame.width ?? 0))")
        } else {
            log("[status] button 为 nil —— 菜单栏项未能创建")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let b = self.statusItem?.button, let w = b.window else { return }
            let f = w.frame
            self.log("[status+3s] frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) image=\(b.image != nil) visible=\(self.statusItem.isVisible)")
        }
    }

    /// 菜单栏图标：自绘实色圆盘（阶段色）+ 反应堆式内环与核心，**非模板图**，任何菜单栏外观下都是一块彩色。
    /// 有会话在等你时，圆盘右侧直接显示等待数（橙色）——真实数据，也是菜单栏最该喊出来的一件事。
    /// 早先用 SF Symbol 模板图（15pt 细线、随阶段换形状），在十几个系统图标里根本认不出是谁的
    func updateIcon(_ state: ClaudeState) {
        self.state = state
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
        let img = NSImage(size: NSSize(width: h + badgeW, height: h), flipped: false) { _ in
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
        b.toolTip = "AIDeck · \(waiting > 0 ? "\(waiting) 个会话等你输入" : "Claude Code 状态")"
    }

    // MARK: - 下拉面板（只在打开菜单时构建，所以这里读一次配置文件无妨）

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let target else { return }
        let ctx = context()
        let state = ctx.state
        menu.removeAllItems()

        addStatusRows(menu, state, target)
        addQuotaRow(menu, state, target)
        addSkinRows(menu, ctx, target)
        addWidgetRows(menu, target)
        addHudRows(menu, target)
        addDiagnosticRows(menu, ctx)
        addActionRows(menu, ctx, target)
    }

    /// 头两行是「要不要管」的总结，随后一行一个会话（等你输入的排最前）
    private func addStatusRows(_ menu: NSMenu, _ state: ClaudeState, _ target: AppDelegate) {
        let phaseLabel: [ClaudePhase: String] = [
            .idle: "空闲", .waiting: "等你输入", .thinking: "思考中", .running: "执行工具"
        ]
        var head = "Claude：\(phaseLabel[state.phase] ?? "?")"
        if let t = state.tool { head += " · \(t)" }
        if let p = state.name ?? state.project { head += " · \(p)" }
        if !state.claudeDetected && state.sessions.isEmpty {
            head = "未检测到 Claude Code 会话记录（~/.claude 下没有 sessions / projects）"
        }
        menu.addItem(NSMenuItem(title: head, action: nil, keyEquivalent: ""))
        // 第二行把菜单栏图标旁那个数字解释清楚：它就是等你输入的会话数
        let waitingCount = state.sessions.filter { $0.phase == .waiting }.count
        menu.addItem(NSMenuItem(title: "活跃会话 \(state.sessions.count) 个"
                                + (waitingCount > 0 ? " · \(waitingCount) 个等你输入（图标旁的数字）" : ""),
                                action: nil, keyEquivalent: ""))
        let order: [ClaudePhase: Int] = [.waiting: 0, .running: 1, .thinking: 2, .idle: 3]
        for s in state.sessions.sorted(by: {
            (order[$0.phase] ?? 9, $0.kind == "bg" ? 1 : 0) < (order[$1.phase] ?? 9, $1.kind == "bg" ? 1 : 0)
        }) {
            var name = (s.nameIsUserSet ? s.name : nil) ?? s.project
            if s.kind == "bg" { name += "（后台）" }
            menu.addItem(NSMenuItem(title: "   \(name)  —  \(HUDView.statusText(s))", action: nil, keyEquivalent: ""))
        }
    }

    /// 额度与精细态 hook：没数据也不藏这一行——未接入给入口，已接入说明还在等数据
    private func addQuotaRow(_ menu: NSMenu, _ state: ClaudeState, _ target: AppDelegate) {
        if let q = state.quota, let f = q.fiveHour {
            var s = "额度 5h 已用 \(Int(f.usedPercentage.rounded()))%"
            if let r = f.resetsAt { s += r > Date() ? " · \(Self.hms(r.timeIntervalSinceNow)) 后重置" : " · 已重置" }
            if let w = q.sevenDay { s += " · 7d 已用 \(Int(w.usedPercentage.rounded()))%" }
            let age = Date().timeIntervalSince(q.recordedAt)
            if age > 600 { s += "（\(Int(age / 60)) 分钟前）" }
            menu.addItem(NSMenuItem(title: s, action: nil, keyEquivalent: ""))
        } else if state.quota == nil {
            let st = QuotaInstaller.inspect()
            let title: String
            if st.installed      { title = "额度：已接入，等待 Claude Code 刷新状态栏" }
            else if st.hasRecord { title = "额度：接入已失效 · 点击处理" }
            else                 { title = "额度：未接入 · 点击接入" }
            let it = NSMenuItem(title: title,
                                action: st.installed ? nil : #selector(AppDelegate.openSettingsForQuota),
                                keyEquivalent: "")
            it.target = target
            menu.addItem(it)
        }
        if !HooksInstaller.inspect().installed {
            let it = NSMenuItem(title: "权限确认状态：未接入 · 点击接入",
                                action: #selector(AppDelegate.openSettingsForHooks), keyEquivalent: "")
            it.target = target
            menu.addItem(it)
        }
    }

    private func addSkinRows(_ menu: NSMenu, _ ctx: Context, _ target: AppDelegate) {
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "切换动画", action: nil, keyEquivalent: ""))
        for name in ctx.animations {
            let it = NSMenuItem(title: "   " + name.replacingOccurrences(of: ".html", with: ""),
                                action: #selector(AppDelegate.pickAnimation(_:)), keyEquivalent: "")
            it.target = target
            it.representedObject = name
            it.state = (name == ctx.currentAnimation) ? .on : .off
            menu.addItem(it)
        }
    }

    /// 小工具：每个小工具一个子菜单选槽位；事件反应：逐项开关。改动即推给所有皮肤页面
    private func addWidgetRows(_ menu: NSMenu, _ target: AppDelegate) {
        menu.addItem(.separator())
        let widgetRoot = NSMenuItem(title: "小工具", action: nil, keyEquivalent: "")
        let widgetMenu = NSMenu()
        let slots = Prefs.widgetSlots
        for w in Prefs.widgets {
            let item = NSMenuItem(title: "\(w.name)  ·  \(Prefs.slots.first { $0.id == slots[w.id] }?.name ?? "?")",
                                  action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for s in Prefs.slots {
                let it = NSMenuItem(title: s.name, action: #selector(AppDelegate.pickWidgetSlot(_:)), keyEquivalent: "")
                it.target = target
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
            let it = NSMenuItem(title: r.name, action: #selector(AppDelegate.toggleReaction(_:)), keyEquivalent: "")
            it.target = target
            it.representedObject = r.id
            it.state = flags[r.id] == true ? .on : .off
            fxMenu.addItem(it)
        }
        fxRoot.submenu = fxMenu
        menu.addItem(fxRoot)
    }

    private func addHudRows(_ menu: NSMenu, _ target: AppDelegate) {
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "状态卡位置", action: nil, keyEquivalent: ""))
        let drag = NSMenuItem(title: "   拖动到任意位置…", action: #selector(AppDelegate.beginHudEdit), keyEquivalent: "")
        drag.target = target
        menu.addItem(drag)
        let float = NSMenuItem(title: "   置顶悬浮（盖在所有窗口之上）",
                               action: #selector(AppDelegate.toggleHudFloat), keyEquivalent: "")
        float.target = target
        float.state = Prefs.hudFloat ? .on : .off
        menu.addItem(float)
        let autoFloat = NSMenuItem(title: "   有会话等你时自动浮现",
                                   action: #selector(AppDelegate.toggleHudAutoFloat), keyEquivalent: "")
        autoFloat.target = target
        autoFloat.state = Prefs.hudAutoFloat ? .on : .off
        menu.addItem(autoFloat)
        let cur = Prefs.hasFreeHudPosition ? "" : Prefs.hudAnchor
        for (code, name) in [("tl", "左上"), ("tr", "右上"), ("bl", "左下"), ("br", "右下")] {
            let it = NSMenuItem(title: "   " + name, action: #selector(AppDelegate.pickHudAnchor(_:)), keyEquivalent: "")
            it.target = target
            it.representedObject = code
            it.state = (code == cur) ? .on : .off
            menu.addItem(it)
        }
    }

    private func addDiagnosticRows(_ menu: NSMenu, _ ctx: Context) {
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(format: "渲染 %@ · %.0f fps", ctx.rendering ? "开" : "停", ctx.fps),
                                action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(format: "遮挡 occlusionState=%@ · 覆盖率 %.0f%%",
                                              ctx.occluded ? "遮住" : "可见", ctx.coverage * 100),
                                action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(format: "探测 %.1fms · 覆盖计算 %.1fms · %@",
                                              ctx.state.probeMillis, ctx.coverageMillis,
                                              ctx.onBattery ? "电池" : "外接电源"),
                                action: nil, keyEquivalent: ""))
    }

    private func addActionRows(_ menu: NSMenu, _ ctx: Context, _ target: AppDelegate) {
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        settingsItem.target = target
        menu.addItem(settingsItem)
        let helpItem = NSMenuItem(title: "使用说明…", action: #selector(AppDelegate.showWelcome), keyEquivalent: "")
        helpItem.target = target
        menu.addItem(helpItem)
        let pause = NSMenuItem(title: ctx.paused ? "恢复动画" : "暂停动画",
                               action: #selector(AppDelegate.togglePause), keyEquivalent: "")
        pause.target = target
        menu.addItem(pause)
        let quit = NSMenuItem(title: "退出", action: #selector(AppDelegate.quit), keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)
    }

    private static func hms(_ t: TimeInterval) -> String {
        let s = max(0, Int(t)); return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}

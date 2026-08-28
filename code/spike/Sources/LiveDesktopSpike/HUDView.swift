import AppKit

/// 状态卡的原生实现：全局状态指引，可置顶悬浮盖在所有窗口之上。
/// 头行是"要不要管"的总结（有会话等你就说等你，否则说几个在跑），下面一行一个会话——
/// 做别的事时瞟一眼就知道哪个会话在等你、哪个还在跑、哪个跑着却半天没输出。
/// 早先用 WKWebView 渲染，但桌面层透明窗口里 WebView 总会露出一块比内容大一圈的底色，
/// 改为 AppKit 绘制后彻底不存在这个问题，毛玻璃交给系统的 NSVisualEffectView。
final class HUDView: NSView {
    private let blur = NSVisualEffectView()
    private let tint = NSView()            // 薄薄一层暗色衬底：浮到白底 App 上时玻璃不能变浅
    private let dot = NSView()             // 容器：定位用
    private let dotLayer = CALayer()       // 真正的圆点：锚点居中，呼吸缩放围绕中心
    private let brandLabel = NSTextField(labelWithString: "CLAUDE CODE")   // 身份标：别人一眼知道这卡是谁的状态
    private let headLabel = NSTextField(labelWithString: "空闲 · 无活跃会话")
    private let moreLabel = NSTextField(labelWithString: "")

    private struct Row { let dot: NSView; let name: NSTextField; let status: NSTextField }
    private var rows: [Row] = []
    private var visibleRows = 0

    private let padX: CGFloat = 20, padTop: CGFloat = 16, padBottom: CGFloat = 14
    private let dotSize: CGFloat = 8, dotGap: CGFloat = 9
    private let headGap: CGFloat = 10, rowH: CGFloat = 18, rowDot: CGFloat = 6, rowDotGap: CGFloat = 8
    private let nameMaxW: CGFloat = 200, colGap: CGFloat = 14
    private let maxRows = 8

    /// HUD 用的强调色：比动画配色更亮，保证在深色毛玻璃上可读
    static func accent(_ p: ClaudePhase) -> NSColor {
        switch p {
        case .idle:     return NSColor(srgbRed: 0.54, green: 0.65, blue: 0.78, alpha: 1)
        case .waiting:  return NSColor(srgbRed: 1.00, green: 0.70, blue: 0.28, alpha: 1)
        case .thinking: return NSColor(srgbRed: 0.65, green: 0.55, blue: 0.98, alpha: 1)
        case .running:  return NSColor(srgbRed: 0.20, green: 0.83, blue: 0.60, alpha: 1)
        }
    }

    /// 时长：不到一小时 MM:SS，超过则 Hh MMm（等你输入不设上限，可能是好几个小时）
    static func dur(_ s: Int) -> String {
        s < 3600 ? String(format: "%02d:%02d", s / 60, s % 60) : String(format: "%dh %02dm", s / 3600, s / 60 % 60)
    }

    /// 每行右侧的状态文字。工作中但 ≥2 分钟没写文件的，如实标"无输出"，不把它伪装成在工作
    static func statusText(_ s: SessionState) -> String {
        if s.parked { return "已转后台" }
        if s.stalled { return "停滞 · \(dur(s.idleSeconds)) 无输出" }
        let quiet = s.idleSeconds >= 120 ? " · \(dur(s.idleSeconds)) 无输出" : ""
        switch s.phase {
        case .waiting:  return "等你输入 · \(dur(s.idleSeconds))"
        case .running:  return "执行 \(s.tool ?? "工具")" + quiet
        case .thinking: return "思考中" + quiet
        case .idle:     return "空闲"
        }
    }

    /// 行的用色：停滞 / 已转后台用暗灰蓝，不给它们工作态的颜色（转后台的活儿由 bg 行代表）
    static func rowAccent(_ s: SessionState) -> NSColor {
        (s.stalled || s.parked) ? accent(.idle) : accent(s.phase)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow      // 模糊窗口背后的内容（桌面动画，或置顶时的应用窗口）
        // 卡片文字是按深色玻璃设计的固定白色；置顶浮到白底 App 上时系统外观会让玻璃变浅、白字糊掉，
        // 所以外观锁定深色，再垫一层暗色衬底，任何背景上都是深色玻璃
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        addSubview(blur)

        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0, alpha: 0.30).cgColor
        blur.addSubview(tint)

        brandLabel.attributedStringValue = NSAttributedString(
            string: "CLAUDE CODE",
            attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                         .foregroundColor: NSColor(white: 1, alpha: 0.45), .kern: 1.2])
        brandLabel.alignment = .right
        styleLabel(brandLabel)

        // 圆点画在独立子层上并把锚点放在中心：AppKit 托管的 view layer 锚点在左下角，
        // 直接对它做 transform.scale 会往右上方长，呼吸放到最大时就和文字对不齐
        dot.wantsLayer = true
        dotLayer.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        dotLayer.cornerRadius = dotSize / 2
        dotLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        dotLayer.position = CGPoint(x: dotSize / 2, y: dotSize / 2)
        dot.layer?.addSublayer(dotLayer)
        blur.addSubview(dot)

        headLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        headLabel.lineBreakMode = .byTruncatingTail
        styleLabel(headLabel)

        moreLabel.font = .systemFont(ofSize: 10, weight: .regular)
        moreLabel.textColor = NSColor(white: 1, alpha: 0.45)
        styleLabel(moreLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func styleLabel(_ l: NSTextField) {
        l.backgroundColor = .clear
        l.isBezeled = false
        l.isEditable = false
        l.maximumNumberOfLines = 1
        blur.addSubview(l)
    }

    private func ensureRows(_ n: Int) {
        while rows.count < n {
            let d = NSView(); d.wantsLayer = true; d.layer?.cornerRadius = rowDot / 2; blur.addSubview(d)
            let name = NSTextField(labelWithString: "")
            name.font = .systemFont(ofSize: 11.5, weight: .medium)
            name.textColor = NSColor(white: 1, alpha: 0.88)
            name.lineBreakMode = .byTruncatingTail
            styleLabel(name)
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 10.5, weight: .regular)
            status.alignment = .right
            styleLabel(status)
            rows.append(Row(dot: d, name: name, status: status))
        }
        for (i, r) in rows.enumerated() {
            let hidden = i >= n
            r.dot.isHidden = hidden; r.name.isHidden = hidden; r.status.isHidden = hidden
        }
        visibleRows = n
    }

    // MARK: - 内容

    func update(_ state: ClaudeState) {
        // 排序：等你输入（等得最久的在前）→ 执行工具 → 思考中 → 停滞；后台任务排最后
        let order: [ClaudePhase: Int] = [.waiting: 0, .running: 1, .thinking: 2, .idle: 3]
        let sorted = state.sessions.sorted { a, b in
            if (a.kind == "bg") != (b.kind == "bg") { return a.kind != "bg" }
            let oa = a.parked ? 7 : a.stalled ? 8 : order[a.phase] ?? 9
            let ob = b.parked ? 7 : b.stalled ? 8 : order[b.phase] ?? 9
            if oa != ob { return oa < ob }
            return a.phase == .waiting ? a.idleSeconds > b.idleSeconds : a.idleSeconds < b.idleSeconds
        }
        let waiting = sorted.filter { $0.phase == .waiting }.count
        let stalled = sorted.filter { $0.stalled }.count
        let parked = sorted.filter { $0.parked }.count
        let busy = sorted.count - waiting - stalled - parked   // 转后台的不算在跑：活儿已由 bg 行计入

        // 头行是"要不要管"的总结：有会话等你就说等你（橙色），否则说几个在跑；停滞的单列不算在跑
        let headPhase: ClaudePhase = waiting > 0 ? .waiting
            : sorted.contains { $0.phase == .running && !$0.stalled && !$0.parked } ? .running
            : busy > 0 ? .thinking : .idle
        let color = HUDView.accent(headPhase)
        dotLayer.backgroundColor = color.cgColor
        dotLayer.shadowColor = color.cgColor
        dotLayer.shadowOpacity = 0.9
        dotLayer.shadowRadius = 6
        dotLayer.shadowOffset = .zero
        if sorted.isEmpty { headLabel.stringValue = "空闲 · 无活跃会话" }
        else {
            var parts: [String] = []
            if waiting > 0 { parts.append("\(waiting) 个等你输入") }
            if busy > 0 { parts.append(waiting > 0 ? "\(busy) 个在跑" : "\(busy) 个会话在跑") }
            if stalled > 0 { parts.append("\(stalled) 个停滞") }
            headLabel.stringValue = parts.joined(separator: " · ")
        }
        headLabel.textColor = color

        ensureRows(min(sorted.count, maxRows))
        // 显示名：用户起的会话名最好认；派生名退回项目名——但项目名重复时用带后缀的派生名区分谁是谁
        var display = sorted.map { (s: SessionState) -> String in (s.nameIsUserSet ? s.name : nil) ?? s.project }
        var seen: [String: Int] = [:]
        for n in display { seen[n, default: 0] += 1 }
        for (i, s) in sorted.enumerated() where seen[display[i]] ?? 0 > 1 {
            if let full = s.name { display[i] = full }
        }
        for (i, s) in sorted.prefix(maxRows).enumerated() {
            let r = rows[i], c = HUDView.rowAccent(s)
            r.dot.layer?.backgroundColor = c.cgColor
            r.name.stringValue = display[i] + (s.kind == "bg" ? "（后台）" : "")
            r.status.stringValue = HUDView.statusText(s)
            r.status.textColor = c.withAlphaComponent(0.95)
        }
        let extra = sorted.count - maxRows
        moreLabel.stringValue = extra > 0 ? "还有 \(extra) 个会话" : ""
        moreLabel.isHidden = extra <= 0

        setBreathing(waiting > 0)   // 有人在等你时才呼吸，最该被一眼看见
        needsLayout = true
    }

    private var breathing = false
    private func setBreathing(_ on: Bool) {
        guard on != breathing else { return }
        breathing = on
        dotLayer.removeAnimation(forKey: "breathe")
        guard on else { dotLayer.transform = CATransform3DIdentity; return }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1.0; a.toValue = 1.55
        a.duration = 0.8
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayer.add(a, forKey: "breathe")
    }

    func setDragging(_ on: Bool) {
        blur.layer?.borderColor = NSColor(white: 1, alpha: on ? 0.30 : 0.14).cgColor
    }

    // MARK: - 尺寸与布局

    /// 身份标的实际宽度：带 kern 的属性字符串，intrinsicContentSize 不把字距算进去，会把 "CODE" 截掉
    private var brandWidth: CGFloat { ceil(brandLabel.attributedStringValue.size().width) + 6 }
    private var headHeight: CGFloat { ceil(headLabel.intrinsicContentSize.height) }

    /// 文本实测宽度：设了截断模式的 NSTextField，intrinsicContentSize 会按当前 frame 缩水；
    /// 用 attributedStringValue 实测（含真实字体与段落属性），再留几像素余量防边界截断
    private func textW(_ l: NSTextField) -> CGFloat {
        ceil(l.attributedStringValue.size().width) + 6
    }

    /// 卡片本体尺寸（不含窗口留给阴影的余量）
    var cardSize: CGSize {
        var w = dotSize + dotGap + textW(headLabel) + colGap + brandWidth
        for r in rows.prefix(visibleRows) {
            let nameW = min(nameMaxW, textW(r.name))
            w = max(w, rowDot + rowDotGap + nameW + colGap + textW(r.status))
        }
        w = max(230, w) + padX * 2
        var h = padTop + headHeight + padBottom
        if visibleRows > 0 { h += headGap + CGFloat(visibleRows) * rowH }
        if !moreLabel.isHidden { h += rowH - 2 }
        return CGSize(width: min(w, 420), height: h)
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        tint.frame = blur.bounds
        let innerW = bounds.width - padX * 2
        let hh = headHeight
        var y = bounds.height - padTop - hh
        dot.frame = CGRect(x: padX, y: y + (hh - dotSize) / 2, width: dotSize, height: dotSize)
        dotLayer.position = CGPoint(x: dotSize / 2, y: dotSize / 2)   // 容器几何变化后子层位置重新钉回中心
        let bw = brandWidth, bh = ceil(brandLabel.intrinsicContentSize.height)
        brandLabel.frame = CGRect(x: bounds.width - padX - bw, y: y + (hh - bh) / 2 + 1, width: bw, height: bh)
        headLabel.frame = CGRect(x: padX + dotSize + dotGap, y: y,
                                 width: innerW - dotSize - dotGap - bw - colGap, height: hh)
        y -= headGap
        for r in rows.prefix(visibleRows) {
            y -= rowH
            let sw = textW(r.status)
            let sh = ceil(r.status.intrinsicContentSize.height)
            let nh = ceil(r.name.intrinsicContentSize.height)
            r.dot.frame = CGRect(x: padX + 1, y: y + (rowH - rowDot) / 2, width: rowDot, height: rowDot)
            r.status.frame = CGRect(x: bounds.width - padX - sw, y: y + (rowH - sh) / 2, width: sw, height: sh)
            let nameX = padX + rowDot + rowDotGap
            r.name.frame = CGRect(x: nameX, y: y + (rowH - nh) / 2,
                                  width: max(20, bounds.width - padX - sw - colGap - nameX), height: nh)
        }
        if !moreLabel.isHidden {
            let mh = ceil(moreLabel.intrinsicContentSize.height)
            y -= rowH - 2
            moreLabel.frame = CGRect(x: padX + rowDot + rowDotGap, y: y + (rowH - 2 - mh) / 2, width: innerW, height: mh)
        }
    }
}

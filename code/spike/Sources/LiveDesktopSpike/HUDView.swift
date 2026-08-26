import AppKit

/// 状态卡的原生实现。
/// 早先用 WKWebView 渲染，但桌面层透明窗口里 WebView 总会露出一块比内容大一圈的底色，
/// 逐层设置透明属性都压不掉。改为 AppKit 绘制后彻底不存在这个问题，
/// 毛玻璃交给系统的 NSVisualEffectView，效果与性能都更好。
final class HUDView: NSView {
    private let blur = NSVisualEffectView()
    private let card = NSView()
    private let dot = NSView()
    private let phaseLabel = NSTextField(labelWithString: "空闲")
    private let metaLabel  = NSTextField(labelWithString: "—")
    private let countLabel = NSTextField(labelWithString: "无活跃会话")

    private let padX: CGFloat = 20, padTop: CGFloat = 16, padBottom: CGFloat = 15
    private let dotSize: CGFloat = 8, dotGap: CGFloat = 9
    private let gap1: CGFloat = 7, gap2: CGFloat = 3

    /// HUD 用的强调色：比动画配色更亮，保证在深色毛玻璃上可读
    static func accent(_ p: ClaudePhase) -> NSColor {
        switch p {
        case .idle:     return NSColor(srgbRed: 0.54, green: 0.65, blue: 0.78, alpha: 1)
        case .waiting:  return NSColor(srgbRed: 1.00, green: 0.70, blue: 0.28, alpha: 1)
        case .thinking: return NSColor(srgbRed: 0.65, green: 0.55, blue: 0.98, alpha: 1)
        case .running:  return NSColor(srgbRed: 0.20, green: 0.83, blue: 0.60, alpha: 1)
        }
    }

    private static func label(_ p: ClaudePhase) -> String {
        switch p {
        case .idle: return "空闲"; case .waiting: return "等你输入"
        case .thinking: return "思考中"; case .running: return "执行工具"
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow      // 模糊窗口背后的桌面动画
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        addSubview(blur)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotSize / 2
        blur.addSubview(dot)

        phaseLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        metaLabel.font  = .systemFont(ofSize: 11, weight: .regular)
        countLabel.font = .systemFont(ofSize: 10, weight: .regular)
        metaLabel.textColor  = NSColor(white: 1, alpha: 0.78)
        countLabel.textColor = NSColor(white: 1, alpha: 0.50)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        for l in [phaseLabel, metaLabel, countLabel] {
            l.backgroundColor = .clear
            l.isBezeled = false
            l.isEditable = false
            blur.addSubview(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 内容

    func update(_ state: ClaudeState) {
        let color = HUDView.accent(state.phase)
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.shadowColor = color.cgColor
        dot.layer?.shadowOpacity = 0.9
        dot.layer?.shadowRadius = 6
        dot.layer?.shadowOffset = .zero

        phaseLabel.stringValue = HUDView.label(state.phase)
        phaseLabel.textColor = color

        var meta: [String] = []
        if let t = state.tool { meta.append(t) }
        if let p = state.project { meta.append(p) }
        if let b = state.branch { meta.append(b) }
        metaLabel.stringValue = meta.isEmpty ? "—" : meta.joined(separator: " · ")
        let n = state.sessions.count
        countLabel.stringValue = n > 0 ? "\(n) 个会话在跑" : "无活跃会话"

        setBreathing(state.phase == .waiting)   // 等你输入时才呼吸，最该被一眼看见
        needsLayout = true
    }

    private var breathing = false
    private func setBreathing(_ on: Bool) {
        guard on != breathing else { return }
        breathing = on
        dot.layer?.removeAnimation(forKey: "breathe")
        guard on else { dot.layer?.transform = CATransform3DIdentity; return }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1.0; a.toValue = 1.55
        a.duration = 0.8
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(a, forKey: "breathe")
    }

    func setDragging(_ on: Bool) {
        blur.layer?.borderColor = NSColor(white: 1, alpha: on ? 0.30 : 0.14).cgColor
    }

    // MARK: - 尺寸与布局

    /// 卡片本体尺寸（不含窗口留给阴影的余量）
    var cardSize: CGSize {
        let headW = dotSize + dotGap + ceil(phaseLabel.intrinsicContentSize.width)
        let w = max(190, max(headW, max(ceil(metaLabel.intrinsicContentSize.width),
                                        ceil(countLabel.intrinsicContentSize.width)))) + padX * 2
        let h = padTop + ceil(phaseLabel.intrinsicContentSize.height)
              + gap1 + ceil(metaLabel.intrinsicContentSize.height)
              + gap2 + ceil(countLabel.intrinsicContentSize.height) + padBottom
        return CGSize(width: min(w, 420), height: h)
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        let ph = ceil(phaseLabel.intrinsicContentSize.height)
        var y = bounds.height - padTop - ph
        dot.frame = CGRect(x: padX, y: y + (ph - dotSize) / 2, width: dotSize, height: dotSize)
        phaseLabel.frame = CGRect(x: padX + dotSize + dotGap, y: y,
                                  width: bounds.width - padX * 2 - dotSize - dotGap, height: ph)
        let mh = ceil(metaLabel.intrinsicContentSize.height)
        y -= gap1 + mh
        metaLabel.frame = CGRect(x: padX, y: y, width: bounds.width - padX * 2, height: mh)
        let ch = ceil(countLabel.intrinsicContentSize.height)
        y -= gap2 + ch
        countLabel.frame = CGRect(x: padX, y: y, width: bounds.width - padX * 2, height: ch)
    }
}

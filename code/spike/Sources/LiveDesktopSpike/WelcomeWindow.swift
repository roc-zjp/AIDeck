import AppKit

/// 首启引导（P2）。LSUIElement 菜单栏 app 没有 Dock 图标、没有主窗口，第一次启动时用户
/// 常常不知道它在哪、怎么用——尤其刘海屏上菜单栏图标会被系统隐掉。这个面板首启弹一次，
/// 也挂在菜单栏「使用说明…」下随时可再看。它同时是通知授权的入口（授权不再启动瞬间自动弹）。
final class WelcomeWindowController: NSWindowController {
    private weak var app: AppDelegate?
    private var notifButton: NSButton!

    init(app: AppDelegate) {
        self.app = app
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "欢迎使用 AIDeck"
        win.isReleasedWhenClosed = false     // controller 持有，关闭后可再次打开
        super.init(window: win)
        buildUI()
        win.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, wrap: CGFloat? = nil) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.backgroundColor = .clear
        if let w = wrap {
            l.lineBreakMode = .byWordWrapping
            l.maximumNumberOfLines = 0
            l.preferredMaxLayoutWidth = w
        }
        return l
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.08, blue: 0.13, alpha: 1).cgColor
        let cyan = NSColor(srgbRed: 0.42, green: 0.86, blue: 0.80, alpha: 1)
        let dim  = NSColor(white: 1, alpha: 0.62)
        let W: CGFloat = 500, pad: CGFloat = 28
        let textW = W - pad * 2 - 34   // 要点行 emoji 列宽 34

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
        ])

        // 图标 + 标题
        let head = NSStackView()
        head.orientation = .horizontal; head.spacing = 14; head.alignment = .centerY
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 60).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let titleCol = NSStackView()
        titleCol.orientation = .vertical; titleCol.alignment = .leading; titleCol.spacing = 3
        titleCol.addArrangedSubview(label("AIDeck", size: 24, weight: .bold, color: .white))
        titleCol.addArrangedSubview(label("常驻你桌面的 AI agent 状态感知台", size: 12.5, weight: .regular, color: dim))
        head.addArrangedSubview(icon)
        head.addArrangedSubview(titleCol)
        stack.addArrangedSubview(head)
        stack.setCustomSpacing(20, after: head)

        // 要点
        let points: [(String, String)] = [
            ("🖥", "桌面露出时看右下角状态卡、菜单栏图标随状态变色——不切回终端也知道哪个会话在跑、哪个在等你。"),
            ("⚙️", "打开设置：右键状态卡，或点菜单栏图标选「设置…」。刘海屏挤掉菜单栏图标时，右键状态卡是永远可用的入口。"),
            ("🔌", "想让桌面显示额度、把「卡在确认框」精确标出来？在设置页一键接入（会改 Claude Code 配置，改前整份备份、随时可恢复）。"),
            ("🔔", "希望会话等你太久 / 卡在确认框时被系统通知提醒？点下面「开启通知」。"),
        ]
        for (emoji, text) in points {
            let row = NSStackView()
            row.orientation = .horizontal; row.alignment = .top; row.spacing = 0
            let e = label(emoji, size: 15, weight: .regular, color: .white)
            e.translatesAutoresizingMaskIntoConstraints = false
            e.widthAnchor.constraint(equalToConstant: 34).isActive = true
            row.addArrangedSubview(e)
            row.addArrangedSubview(label(text, size: 12.5, weight: .regular, color: NSColor(white: 1, alpha: 0.85), wrap: textW))
            stack.addArrangedSubview(row)
        }

        // 按钮行
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)
        let btns = NSStackView()
        btns.orientation = .horizontal; btns.spacing = 10; btns.alignment = .centerY
        btns.translatesAutoresizingMaskIntoConstraints = false
        notifButton = NSButton(title: "开启通知", target: self, action: #selector(notifTapped))
        notifButton.bezelStyle = .rounded
        let settingsBtn = NSButton(title: "打开设置…", target: self, action: #selector(settingsTapped))
        settingsBtn.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let startBtn = NSButton(title: "开始使用", target: self, action: #selector(closeTapped))
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"     // 回车 = 默认按钮
        btns.addArrangedSubview(notifButton)
        btns.addArrangedSubview(settingsBtn)
        btns.addArrangedSubview(spacer)
        btns.addArrangedSubview(startBtn)
        btns.widthAnchor.constraint(equalToConstant: W - pad * 2).isActive = true
        stack.addArrangedSubview(btns)

        window?.setContentSize(NSSize(width: W, height: stack.fittingSize.height + pad * 2))
        refreshNotifButton()
    }

    private func refreshNotifButton() {
        guard let engine = app?.alertEngine else { return }
        engine.refreshAuthorizationStatus { [weak self] in
            guard let self, let engine = self.app?.alertEngine else { return }
            switch engine.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.notifButton.title = "通知已开启"; self.notifButton.isEnabled = false
            case .denied:
                self.notifButton.title = "通知被拒（去系统设置）"; self.notifButton.isEnabled = true
            default:
                self.notifButton.title = "开启通知"; self.notifButton.isEnabled = true
            }
        }
    }

    @objc private func notifTapped() {
        guard let engine = app?.alertEngine else { return }
        if engine.authorizationStatus == .denied {
            if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(u) }
        } else {
            engine.requestAuthorization { [weak self] in self?.refreshNotifButton() }
        }
    }
    @objc private func settingsTapped() { app?.openSettings() }
    @objc private func closeTapped() { window?.close() }
}

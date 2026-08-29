import AppKit

/// 首启引导（P2）。LSUIElement 菜单栏 app 没有 Dock 图标、没有主窗口，首次启动时用户没有任何
/// "这是什么、从哪开始"的线索——尤其刘海屏上菜单栏图标可能被系统隐藏。本面板首启弹一次，
/// 也挂在菜单栏「使用说明…」下随时可再看；同时是通知授权的入口（授权不在启动瞬间自动弹）。
///
/// 文案面向外部用户：陈述句、术语统一（会话 / 状态卡 / 菜单栏 / 接入 / 通知），不用口语与反问；图标用 SF Symbols。
final class WelcomeWindowController: NSWindowController {
    private weak var app: AppDelegate?
    private var notifButton: NSButton!

    init(app: AppDelegate) {
        self.app = app
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "AIDeck"
        win.appearance = NSAppearance(named: .darkAqua)   // 面板是深色底：锁定深色外观，否则浅色模式下按钮按浅色渲染、在深底上几乎不可见
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
        let accent = NSColor(srgbRed: 0.42, green: 0.86, blue: 0.80, alpha: 1)
        let dim    = NSColor(white: 1, alpha: 0.60)
        let body   = NSColor(white: 1, alpha: 0.82)
        let W: CGFloat = 520, pad: CGFloat = 30, iconCol: CGFloat = 36
        let textW = W - pad * 2 - iconCol

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
        ])

        // 图标 + 名称 + 定位
        let head = NSStackView()
        head.orientation = .horizontal; head.spacing = 14; head.alignment = .centerY
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 60).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let titleCol = NSStackView()
        titleCol.orientation = .vertical; titleCol.alignment = .leading; titleCol.spacing = 3
        titleCol.addArrangedSubview(label("AIDeck", size: 24, weight: .bold, color: .white))
        titleCol.addArrangedSubview(label("AI Agent 桌面 · 实时呈现 Claude Code 会话状态", size: 12.5, weight: .regular, color: dim))
        head.addArrangedSubview(icon)
        head.addArrangedSubview(titleCol)
        stack.addArrangedSubview(head)
        stack.setCustomSpacing(22, after: head)

        // 要点：SF Symbol + 标题 + 说明
        let points: [(symbol: String, title: String, desc: String)] = [
            ("rectangle.on.rectangle", "状态感知",
             "状态卡与菜单栏图标实时反映所有 Claude Code 会话：正在执行、等待输入、等待确认。无需切换至终端。"),
            ("gearshape", "设置入口",
             "右键状态卡，或通过菜单栏图标打开「设置」。状态卡入口在任何屏幕布局下均可用。"),
            ("link", "数据接入（可选）",
             "额度显示与权限确认状态需接入 Claude Code 配置，在「设置」首屏的「数据接入」区完成。接入前自动备份完整配置，可随时一键恢复。"),
            ("bell", "系统通知（可选）",
             "会话等待超过阈值或需要确认时发送系统通知。每次等待仅通知一次，可在设置中调整或关闭。"),
        ]
        for p in points {
            let row = NSStackView()
            row.orientation = .horizontal; row.alignment = .top; row.spacing = 0
            let iv = NSImageView()
            if let img = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title) {
                iv.image = img.withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
            }
            iv.contentTintColor = accent
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: iconCol).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 20).isActive = true
            iv.imageAlignment = .alignTopLeft
            let col = NSStackView()
            col.orientation = .vertical; col.alignment = .leading; col.spacing = 3
            col.addArrangedSubview(label(p.title, size: 13, weight: .semibold, color: .white))
            col.addArrangedSubview(label(p.desc, size: 12, weight: .regular, color: body, wrap: textW))
            row.addArrangedSubview(iv)
            row.addArrangedSubview(col)
            stack.addArrangedSubview(row)
        }

        // 按钮行
        stack.setCustomSpacing(24, after: stack.arrangedSubviews.last!)
        let btns = NSStackView()
        btns.orientation = .horizontal; btns.spacing = 10; btns.alignment = .centerY
        btns.translatesAutoresizingMaskIntoConstraints = false
        notifButton = NSButton(title: "启用通知", target: self, action: #selector(notifTapped))
        notifButton.bezelStyle = .rounded
        let settingsBtn = NSButton(title: "打开设置", target: self, action: #selector(settingsTapped))
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
                self.notifButton.title = "通知已启用"; self.notifButton.isEnabled = false
            case .denied:
                self.notifButton.title = "前往系统设置启用通知"; self.notifButton.isEnabled = true
            default:
                self.notifButton.title = "启用通知"; self.notifButton.isEnabled = true
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
    @objc private func settingsTapped() { app?.revealSettings("quota") }   // 首次使用最先要配的是数据接入
    @objc private func closeTapped() { window?.close() }
}

import AppKit

/// 设置窗口（M4 第一块）：左侧是**真实渲染**的实时预览——同一份皮肤 HTML、同一份实时状态与偏好，
/// 页面按窗口尺寸等比缩放（S = min(W,H)/900），所以它不是假缩略图，就是桌面本身的缩小版；
/// 右侧改皮肤 / 小工具槽位 / 事件反应 / 状态卡行为，预览和桌面同时生效。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var app: AppDelegate?
    private let previewHost = AnimationHost()
    private var skinPopup: NSPopUpButton!
    private var modelPopup: NSPopUpButton!
    private var skinPrefsBox: NSStackView!
    private var quotaStatusLabel: NSTextField!
    private var quotaActionButton: NSButton!
    private var quotaInstalled = false
    private var quotaTick = 0
    private var previewSizeConstraints: (w: NSLayoutConstraint, h: NSLayoutConstraint)?
    private var scrollWidth: CGFloat = 472
    private var noteHeight: CGFloat = 15
    private var appliedAspect: CGFloat = 0
    private let widgetPaletteH: CGFloat = 80      // 预览下方「未装配」托盘带高度（容纳带形态缩略图的卡片）
    private var widgetOverlay: WidgetOverlayView!

    init(app: AppDelegate) {
        self.app = app
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "live-desktop 设置"
        super.init(window: win)
        win.delegate = self
        buildUI()
        win.center()
        previewHost.load(app.currentAnimation)
        previewHost.pushConfig(Prefs.config(skin: app.currentAnimation))
        previewHost.onPrefsSchema = { [weak app] schema in app?.registerSkinSchema(app?.currentAnimation ?? "", schema) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// AppDelegate 每拍调用：预览喂的就是桌面那份真实状态
    func pushState(_ state: ClaudeState) {
        previewHost.push(state: state)
        widgetOverlay?.state = state      // 装配台卡片缩略图用真实数据
        quotaTick += 1
        if quotaTick % 5 == 1 { refreshQuotaSection() }   // 5s 一刷：够跟上数据，又不必每秒读 settings.json
    }
    func pushConfig() {
        previewHost.pushConfig(Prefs.config(skin: app?.currentAnimation ?? ""))
        widgetOverlay?.reload()      // 菜单栏 / ./ld widget 改了槽位也让装配台同步
    }
    func reloadSkin(_ name: String) {
        previewHost.load(name)
        previewHost.pushConfig(Prefs.config(skin: name))
        rebuildSkinPopup(selecting: name)
        rebuildSkinPrefs()
    }
    /// 某个皮肤上报了设置项 schema：是当前皮肤就重建「皮肤设置」区
    func skinSchemaChanged(_ skin: String) { if skin == app?.currentAnimation { rebuildSkinPrefs() } }

    /// 皮肤下拉：内置 + 自定义（user/ 前缀显示为「自定义 · 名字」），文件名放在 representedObject 里
    private func rebuildSkinPopup(selecting name: String) {
        skinPopup.removeAllItems()
        for file in previewHost.availableAnimations {
            let title = file.hasPrefix(AnimationHost.userPrefix)
                ? "自定义 · " + String(file.dropFirst(AnimationHost.userPrefix.count)).replacingOccurrences(of: ".html", with: "")
                : file.replacingOccurrences(of: ".html", with: "")
            skinPopup.addItem(withTitle: title)
            skinPopup.lastItem?.representedObject = file
        }
        if let idx = skinPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == name }) {
            skinPopup.selectItem(at: idx)
        }
    }

    /// 3D 模型下拉：内置程序化模型 + 模型目录里的 .glb（显示为「自定义 · 文件名」），id 放 representedObject
    private func rebuildModelPopup() {
        modelPopup.removeAllItems()
        for m in ModelServer.builtinModels { modelPopup.addItem(withTitle: "\(m.name)  \(m.id)"); modelPopup.lastItem?.representedObject = m.id }
        for f in ModelServer.userModelFiles { modelPopup.addItem(withTitle: "自定义 · " + f); modelPopup.lastItem?.representedObject = ModelServer.userPrefix + f }
        let cur = Prefs.model
        if let idx = modelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == cur }) { modelPopup.selectItem(at: idx) }
    }

    func windowWillClose(_ notification: Notification) {
        previewHost.shutdown()      // 不摘 handler 会漏 WebContent 进程（见 issues.md）
        app?.settingsClosed()
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // 左：实时预览（真渲染）
        let preview = previewHost.webView
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        content.addSubview(preview)

        // 小工具装配台：透明 overlay 盖在预览之上（预览区接落点）+ 预览下方一条托盘带（未装配的小工具）
        widgetOverlay = WidgetOverlayView(paletteHeight: widgetPaletteH) { [weak self] in self?.app?.pushPrefs() }
        content.addSubview(widgetOverlay)      // 加在 preview 之后 → 层级在其上

        let previewNote = label("↑ 左侧＝真实预览（改动即时生效）；小工具直接拖到预览九宫格＝装配、拖回下方托盘＝移除", size: 11, color: .secondaryLabelColor)
        // 不关掉 autoresizing 翻译的话，它会把自己钉在窗口底部，连带把 preview 的高度约束挤爆（preview 被拉长）
        previewNote.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(previewNote)

        // 右：控制列
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        // 右列装进滚动容器：区块会继续变多，窗口不该无限长高；显示不下就上下滚动
        let doc = FlippedView()          // documentView 需翻转坐标系，内容才从顶部排起
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(controls)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        content.addSubview(scroll)

        // 皮肤：内置 + ~/.config/live-desktop/skins 里的自定义
        controls.addArrangedSubview(sectionTitle("皮肤"))
        skinPopup = NSPopUpButton()
        skinPopup.target = self
        skinPopup.action = #selector(skinChanged(_:))
        rebuildSkinPopup(selecting: app?.currentAnimation ?? "")
        controls.addArrangedSubview(skinPopup)
        let skinButtons = NSStackView()
        skinButtons.orientation = .horizontal
        skinButtons.spacing = 6
        for (title, sel) in [("新建皮肤（从模板）", #selector(newSkin)), ("打开皮肤目录", #selector(openSkinsDir)), ("重新加载", #selector(reloadCurrentSkin))] {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            skinButtons.addArrangedSubview(b)
        }
        controls.addArrangedSubview(skinButtons)
        controls.addArrangedSubview(label("自定义皮肤 = 一个自包含 HTML，放进皮肤目录即出现在列表；契约见目录里的 README.md",
                                          size: 11, color: .secondaryLabelColor))

        // 皮肤自声明的设置项：控件按页面上报的 schema 生成，宿主不认识任何具体 id
        controls.addArrangedSubview(spacer(6))
        controls.addArrangedSubview(sectionTitle("皮肤设置"))
        skinPrefsBox = NSStackView()
        skinPrefsBox.orientation = .vertical
        skinPrefsBox.alignment = .leading
        skinPrefsBox.spacing = 6
        controls.addArrangedSubview(skinPrefsBox)
        rebuildSkinPrefs()

        // 3D 模型（hologram 皮肤的主体）
        controls.addArrangedSubview(spacer(6))
        controls.addArrangedSubview(sectionTitle("3D 模型（hologram 皮肤）"))
        let modelRow = NSStackView()
        modelRow.orientation = .horizontal
        modelRow.spacing = 6
        modelPopup = NSPopUpButton()
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        rebuildModelPopup()
        modelRow.addArrangedSubview(modelPopup)
        for (title, sel) in [("打开模型目录", #selector(openModelsDir)), ("刷新列表", #selector(refreshModels))] {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            modelRow.addArrangedSubview(b)
        }
        controls.addArrangedSubview(modelRow)
        controls.addArrangedSubview(label("把 .glb 放进模型目录即可选；全息风格只用几何，材质贴图忽略；Draco 压缩不支持",
                                          size: 11, color: .secondaryLabelColor))

        // 小工具槽位：装配台就在左侧真实预览上（overlay），这里只放引导说明
        controls.addArrangedSubview(spacer(6))
        controls.addArrangedSubview(sectionTitle("小工具槽位"))
        controls.addArrangedSubview(wrappedLabel("在左侧预览上直接拖放：把卡片拖到预览九宫格的某个位置＝装配到该槽位，拖回预览下方的托盘＝移除，格子之间拖＝换位置。所见即所得，装配后预览与桌面同时生效。",
                                                 size: 11, color: .secondaryLabelColor))

        // 事件反应
        controls.addArrangedSubview(spacer(6))
        controls.addArrangedSubview(sectionTitle("事件反应"))
        let flags = Prefs.reactionFlags
        for r in Prefs.reactions {
            let cb = NSButton(checkboxWithTitle: r.name, target: self, action: #selector(reactionToggled(_:)))
            cb.identifier = NSUserInterfaceItemIdentifier(r.id)
            cb.state = flags[r.id] == true ? .on : .off
            cb.font = .systemFont(ofSize: 12)
            controls.addArrangedSubview(cb)
        }

        // 状态卡
        controls.addArrangedSubview(spacer(6))
        controls.addArrangedSubview(sectionTitle("状态卡"))
        let float = NSButton(checkboxWithTitle: "置顶悬浮（盖在所有窗口之上，全屏 App 可见）",
                             target: self, action: #selector(floatToggled(_:)))
        float.state = UserDefaults.standard.bool(forKey: "hudFloat") ? .on : .off
        float.font = .systemFont(ofSize: 12)
        controls.addArrangedSubview(float)
        let through = NSButton(checkboxWithTitle: "点击穿透（不拦截鼠标，也就不能直接拖动）",
                               target: self, action: #selector(throughToggled(_:)))
        through.state = UserDefaults.standard.bool(forKey: "hudClickThrough") ? .on : .off
        through.font = .systemFont(ofSize: 12)
        controls.addArrangedSubview(through)
        controls.addArrangedSubview(label("位置：直接用鼠标把状态卡拖到想要的地方（每块屏各自记忆）；右键状态卡可随时打开本设置",
                                          size: 11, color: .secondaryLabelColor))

        // Claude 额度（M3 收尾：QuotaInstaller 的 UI 壳，与 ./ld quota 同一套逻辑）
        controls.addArrangedSubview(spacer(6))
        controls.addArrangedSubview(sectionTitle("Claude 额度（五小时 / 七天用量）"))
        quotaStatusLabel = wrappedLabel("…", size: 12, color: .labelColor)
        controls.addArrangedSubview(quotaStatusLabel)
        let quotaButtons = NSStackView()
        quotaButtons.orientation = .horizontal
        quotaButtons.spacing = 6
        quotaActionButton = smallButton("", action: #selector(quotaActionTapped))
        quotaButtons.addArrangedSubview(quotaActionButton)
        quotaButtons.addArrangedSubview(smallButton("打开数据目录", action: #selector(openQuotaDir)))
        controls.addArrangedSubview(quotaButtons)
        controls.addArrangedSubview(wrappedLabel("接入只改 ~/.claude/settings.json 的 statusLine 一个键（改前整份备份），原状态栏命令原样透传、终端显示不变，可随时恢复",
                                                 size: 11, color: .secondaryLabelColor))
        refreshQuotaSection()

        // 通用
        controls.addArrangedSubview(spacer(6))
        controls.addArrangedSubview(sectionTitle("通用"))
        let auto = NSButton(checkboxWithTitle: "开机自启（登录时自动启动，launchd 保活，崩了自动拉起）",
                            target: self, action: #selector(autostartToggled(_:)))
        auto.state = Autostart.isEnabled ? .on : .off
        auto.font = .systemFont(ofSize: 12)
        controls.addArrangedSubview(auto)
        controls.addArrangedSubview(wrappedLabel("开启只写一个 LaunchAgent（~/Library/LaunchAgents/），下次登录生效；与 ./ld autostart 等价",
                                                 size: 11, color: .secondaryLabelColor))
        let alertsCb = NSButton(checkboxWithTitle: "阈值通知：「等你输入」超时每次等待一次、额度跨 80% / 95% 各一次",
                                target: self, action: #selector(alertsToggled(_:)))
        alertsCb.state = Prefs.alertsEnabled ? .on : .off
        alertsCb.font = .systemFont(ofSize: 12)
        controls.addArrangedSubview(alertsCb)
        let thRow = NSStackView()
        thRow.orientation = .horizontal
        thRow.spacing = 8
        let thLabel = label("等待阈值", size: 12, color: .labelColor)
        thLabel.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let thPopup = NSPopUpButton()
        var minutes = Prefs.alertMinuteChoices
        if !minutes.contains(Prefs.alertWaitingMinutes) { minutes.append(Prefs.alertWaitingMinutes); minutes.sort() }
        for m in minutes {
            thPopup.addItem(withTitle: "\(m) 分钟")
            thPopup.lastItem?.representedObject = m
        }
        if let i = thPopup.itemArray.firstIndex(where: { ($0.representedObject as? Int) == Prefs.alertWaitingMinutes }) {
            thPopup.selectItem(at: i)
        }
        thPopup.target = self
        thPopup.action = #selector(alertMinutesChanged(_:))
        thRow.addArrangedSubview(thLabel)
        thRow.addArrangedSubview(thPopup)
        controls.addArrangedSubview(thRow)
        controls.addArrangedSubview(wrappedLabel("不做常规状态播报——通知一旦变成噪音就会被关掉，长尾兜底也就没了（决策 003）",
                                                 size: 11, color: .secondaryLabelColor))

        // 右列的行一律禁止纵向压缩：否则空间不足时 autolayout 会把勾选框叠起来（而不是交给滚动）
        controls.arrangedSubviews.forEach { $0.setContentCompressionResistancePriority(.required, for: .vertical) }
        controls.setClippingResistancePriority(.required, for: .vertical)

        // 预览与**所在屏幕**同宽高比、吃满左列高度（多屏宽高比可能不同：窗口挪到哪块屏就按哪块屏换算，
        // 见 windowDidChangeScreen → applyPreviewAspect）。窗口尺寸全部用挂在 content 上的约束表达——
        // 首次显示时 AppKit 会按约束重算窗口尺寸（_changeWindowFrameFromConstraintsIfNecessary），
        // setContentSize 会被它覆盖，而 content 上的约束它是尊重的（见 issues.md 2026-08-27）
        let scrollW = controls.fittingSize.width + 16     // +16：系统开「总是显示滚动条」时留出 legacy scroller
        scrollWidth = scrollW
        noteHeight = previewNote.fittingSize.height
        let pw = preview.widthAnchor.constraint(equalToConstant: 640)   // 初值随即被 applyPreviewAspect 覆盖
        let ph = preview.heightAnchor.constraint(equalToConstant: 400)
        previewSizeConstraints = (pw, ph)
        NSLayoutConstraint.activate([
            pw, ph,
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            preview.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            // overlay 盖住预览（接落点）并向下延伸出托盘带；尺寸随 preview 走
            widgetOverlay.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            widgetOverlay.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            widgetOverlay.topAnchor.constraint(equalTo: preview.topAnchor),
            widgetOverlay.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: widgetPaletteH),
            previewNote.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            previewNote.topAnchor.constraint(equalTo: widgetOverlay.bottomAnchor, constant: 8),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: previewNote.bottomAnchor, constant: 14),

            scroll.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalToConstant: scrollW),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            // documentView：宽度跟视口走（只竖滚），高度由栈内容决定
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            controls.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            controls.topAnchor.constraint(equalTo: doc.topAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 620 + widgetPaletteH),
        ])
        applyPreviewAspect()
    }

    /// 预览按窗口所在屏幕的宽高比吃满左列高度；屏幕太窄放不下时按宽度封顶、等比缩小。
    /// 初次 buildUI 时窗口还没上屏，取 NSScreen.main；之后拖到别的屏由 windowDidChangeScreen 触发重算
    private func applyPreviewAspect() {
        guard let sizes = previewSizeConstraints else { return }
        let screen = window?.screen ?? NSScreen.main
        let aspect = screen.map { $0.frame.width / $0.frame.height } ?? 16.0 / 10.0
        if abs(aspect - appliedAspect) < 0.01 { return }    // 跨屏拖动 / 重入时避免反复触发
        appliedAspect = aspect
        var h: CGFloat = 620 - 16 - 8 - noteHeight - 14     // 左列可用高度，留白与上面约束一致
        var w = (h * aspect).rounded()
        let maxW = (screen?.visibleFrame.width ?? 1400) - scrollWidth - 52 - 24
        if w > maxW { w = maxW; h = (w / aspect).rounded() }
        sizes.w.constant = w
        sizes.h.constant = h
        window?.layoutIfNeeded()
    }

    func windowDidChangeScreen(_ notification: Notification) { applyPreviewAspect() }

    /// 「皮肤设置」区：bool → 复选框，number → 滑杆 + 读数，choice → 下拉；值存 Prefs.skinValues(皮肤名)，默认值以 schema 为准
    private func rebuildSkinPrefs() {
        guard let box = skinPrefsBox else { return }
        box.arrangedSubviews.forEach { box.removeArrangedSubview($0); $0.removeFromSuperview() }
        let skin = app?.currentAnimation ?? ""
        let schema = app?.skinSchema(for: skin) ?? []
        if schema.isEmpty {
            box.addArrangedSubview(label("此皮肤没有声明设置项（皮肤可用 __ld.declarePrefs 声明，见皮肤目录 README）", size: 11, color: .secondaryLabelColor))
            return
        }
        let saved = Prefs.skinValues(skin)
        for p in schema {
            guard let id = p["id"] as? String, let type = p["type"] as? String else { continue }
            let name = p["name"] as? String ?? id
            let value: Any? = saved[id] ?? p["default"]
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
            switch type {
            case "bool":
                let cb = NSButton(checkboxWithTitle: name, target: self, action: #selector(skinBoolToggled(_:)))
                cb.identifier = NSUserInterfaceItemIdentifier(id)
                cb.state = ((value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)) ? .on : .off
                cb.font = .systemFont(ofSize: 12)
                row.addArrangedSubview(cb)
            case "number":
                let l = label(name, size: 12, color: .labelColor); l.widthAnchor.constraint(equalToConstant: 88).isActive = true
                let slider = NSSlider(value: (value as? NSNumber)?.doubleValue ?? 0,
                                      minValue: (p["min"] as? NSNumber)?.doubleValue ?? 0,
                                      maxValue: (p["max"] as? NSNumber)?.doubleValue ?? 100,
                                      target: self, action: #selector(skinNumberChanged(_:)))
                slider.identifier = NSUserInterfaceItemIdentifier(id)
                slider.isContinuous = false
                slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
                if let step = (p["step"] as? NSNumber)?.doubleValue, step > 0 {
                    slider.allowsTickMarkValuesOnly = true
                    slider.numberOfTickMarks = Int(((slider.maxValue - slider.minValue) / step).rounded()) + 1
                }
                let readout = label(Self.fmt((value as? NSNumber)?.doubleValue ?? 0), size: 11, color: .secondaryLabelColor)
                readout.identifier = NSUserInterfaceItemIdentifier("readout." + id)
                row.addArrangedSubview(l); row.addArrangedSubview(slider); row.addArrangedSubview(readout)
            case "choice":
                let l = label(name, size: 12, color: .labelColor); l.widthAnchor.constraint(equalToConstant: 88).isActive = true
                let popup = NSPopUpButton()
                popup.identifier = NSUserInterfaceItemIdentifier(id)
                popup.target = self; popup.action = #selector(skinChoiceChanged(_:))
                for o in (p["options"] as? [[String: Any]]) ?? [] {
                    popup.addItem(withTitle: o["name"] as? String ?? o["id"] as? String ?? "?")
                    popup.lastItem?.representedObject = o["id"]
                }
                if let cur = value as? String, let idx = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == cur }) { popup.selectItem(at: idx) }
                row.addArrangedSubview(l); row.addArrangedSubview(popup)
            default: continue
            }
            box.addArrangedSubview(row)
        }
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(skinPrefsReset))
        reset.bezelStyle = .rounded; reset.controlSize = .small; reset.font = .systemFont(ofSize: 11)
        box.addArrangedSubview(reset)
    }
    private static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }

    @objc private func skinBoolToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let skin = app?.currentAnimation else { return }
        Prefs.setSkinValue(skin, id: id, value: sender.state == .on); app?.pushPrefs()
    }
    @objc private func skinNumberChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue, let skin = app?.currentAnimation else { return }
        Prefs.setSkinValue(skin, id: id, value: sender.doubleValue); app?.pushPrefs()
        if let ro = skinPrefsBox.arrangedSubviews.compactMap({ ($0 as? NSStackView)?.arrangedSubviews.first { $0.identifier?.rawValue == "readout." + id } as? NSTextField }).first {
            ro.stringValue = Self.fmt(sender.doubleValue)
        }
    }
    @objc private func skinChoiceChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue, let skin = app?.currentAnimation, let v = sender.selectedItem?.representedObject as? String else { return }
        Prefs.setSkinValue(skin, id: id, value: v); app?.pushPrefs()
    }
    @objc private func skinPrefsReset() {
        guard let skin = app?.currentAnimation else { return }
        Prefs.resetSkin(skin); app?.pushPrefs(); rebuildSkinPrefs()
    }

    private func sectionTitle(_ s: String) -> NSTextField {
        let l = label(s, size: 12, color: .labelColor)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        return l
    }

    private func label(_ s: String, size: CGFloat, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        return l
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    /// 右列宽约 330，长句要能折行（labelWithString 是单行的，超宽会被截尾）
    private func wrappedLabel(_ s: String, size: CGFloat, color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.isSelectable = false
        l.preferredMaxLayoutWidth = 320
        return l
    }

    private func smallButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    // MARK: - 动作：全部走 Prefs / AppDelegate 的同一套入口，预览与桌面同时生效

    @objc private func skinChanged(_ sender: NSPopUpButton) {
        guard let file = sender.selectedItem?.representedObject as? String else { return }
        app?.applyAnimation(file)
    }

    /// 从内置皮肤复制一份到自定义目录，选中它并在 Finder 里露出来
    @objc private func newSkin() {
        let fm = FileManager.default
        let dir = AnimationHost.userSkinsDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = "我的皮肤.html", n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) { name = "我的皮肤 \(n).html"; n += 1 }
        let template = previewHost.webDirectory.appendingPathComponent("pulse.html")   // 最短的内置皮肤，最适合改起
        guard (try? fm.copyItem(at: template, to: dir.appendingPathComponent(name))) != nil else { return }
        app?.applyAnimation(AnimationHost.userPrefix + name)
        NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent(name)])
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        Prefs.setModel(id)
        app?.pushPrefs()
    }

    @objc private func openModelsDir() {
        ModelServer.ensureUserModelsDir()
        NSWorkspace.shared.open(ModelServer.userModelsDir)
    }

    @objc private func refreshModels() { rebuildModelPopup() }

    @objc private func openSkinsDir() {
        NSWorkspace.shared.open(AnimationHost.userSkinsDir)
    }

    @objc private func reloadCurrentSkin() {
        if let cur = app?.currentAnimation { app?.applyAnimation(cur) }
    }

    @objc private func reactionToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        Prefs.setReaction(id, on: sender.state == .on)
        app?.pushPrefs()
    }

    @objc private func floatToggled(_ sender: NSButton) {
        app?.setHudFloat(sender.state == .on)
    }

    @objc private func throughToggled(_ sender: NSButton) {
        app?.setClickThrough(sender.state == .on)
    }

    // MARK: - Claude 额度

    /// 接入与否看 settings.json（inspect），数据是否健康看 rate-limits.json 的新鲜度——
    /// statusLine 可能被项目级 / 托管 settings 覆盖：键还指向我们、数据却断了，所以两者分开判断
    private func refreshQuotaSection() {
        let st = QuotaInstaller.inspect()
        quotaInstalled = st.installed
        var text: String
        if st.installed {
            if let snap = st.snapshot {
                var parts: [String] = []
                if let f = snap.fiveHour { parts.append("5h 已用 \(Int(f.usedPercentage.rounded()))%") }
                if let w = snap.sevenDay { parts.append("7d 已用 \(Int(w.usedPercentage.rounded()))%") }
                let age = Date().timeIntervalSince(snap.recordedAt)
                let ageText = age < 120 ? "\(max(0, Int(age)))s 前" : age < 7200 ? "\(Int(age / 60)) 分钟前" : "\(Int(age / 3600)) 小时前"
                text = "已接入 · " + parts.joined(separator: " · ") + "（数据 \(ageText)）"
                if age > 3600 {
                    text += "\n长时间无更新：Claude Code 未在跑，或 statusLine 被项目级 / 托管 settings 覆盖（./ld quota status 可查）"
                }
            } else {
                text = "已接入 · 暂无数据：Claude Code 刷新一次状态栏后才有（仅 Pro / Max 订阅有额度数据）"
            }
        } else if st.hasRecord {
            text = "接入被顶掉：statusLine 现在是 \(st.currentCommand ?? "（未配置）")，额度数据不再更新，可重新接入"
        } else {
            text = "未接入 · 桌面 POWER 面板与菜单栏额度行留空"
        }
        quotaStatusLabel.stringValue = text
        quotaActionButton.title = quotaInstalled ? "恢复原状态栏…" : "接入…"
    }

    /// 改用户 settings.json 前必须确认，把改什么、备份在哪说清楚（决策 005：零侵入承诺的一部分）
    @objc private func quotaActionTapped() {
        let alert = NSAlert()
        if quotaInstalled {
            alert.messageText = "恢复原状态栏？"
            alert.informativeText = """
            把 \(QuotaInstaller.settingsURL.path) 的 statusLine 还原为接入前的配置（还原前会再备份一次），并删除本机的额度记录文件。桌面 POWER 面板与菜单栏额度行将留空。
            """
            alert.addButton(withTitle: "恢复")
        } else {
            alert.messageText = "接入 Claude 额度数据？"
            alert.informativeText = """
            将修改 \(QuotaInstaller.settingsURL.path) 的 statusLine 一个键，指向本 App 自带的 ld-statusline。

            · 改前把整份 settings.json 备份到 \(QuotaInstaller.backupDir.path)/
            · 你原来的状态栏命令原样透传，终端底部显示不变
            · 不读凭证、不发网络请求，数据来自 Claude Code 喂给状态栏的 JSON
            · 随时可在本页一键恢复
            """
            alert.addButton(withTitle: "接入")
        }
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if quotaInstalled { try QuotaInstaller.uninstall() } else { try QuotaInstaller.install() }
        } catch {
            let e = NSAlert()
            e.alertStyle = .warning
            e.messageText = quotaInstalled ? "恢复失败" : "接入失败"
            e.informativeText = "\(error)"
            e.runModal()
        }
        refreshQuotaSection()
    }

    @objc private func autostartToggled(_ sender: NSButton) {
        do {
            if sender.state == .on { try Autostart.enable() } else { try Autostart.disable() }
        } catch {
            sender.state = sender.state == .on ? .off : .on     // 失败回滚勾选
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "开机自启设置失败"
            a.informativeText = "\(error)"
            a.runModal()
        }
    }

    @objc private func alertsToggled(_ sender: NSButton) {
        Prefs.setAlertsEnabled(sender.state == .on)
    }

    @objc private func alertMinutesChanged(_ sender: NSPopUpButton) {
        if let m = sender.selectedItem?.representedObject as? Int { Prefs.setAlertWaitingMinutes(m) }
    }

    @objc private func openQuotaDir() {
        try? FileManager.default.createDirectory(at: QuotaProbe.dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(QuotaProbe.dir)
    }
}

/// NSScrollView 的 documentView：AppKit 默认坐标系原点在左下，翻转后内容才从顶部排起
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 小工具装配台：直接叠在左侧**真实预览**之上——把预览当成桌面本身。
/// 预览区按 3×3 九宫格接收落点：从下方「未装配」托盘拖一张卡片到某格 = 装配到该槽位；
/// 把预览里已装配的卡片拖回托盘 / 拖出预览 = 移除；格子之间拖 = 换位置；同一格可叠放多个。
/// 松手即写 Prefs.setWidget 并回调 onChange（= app.pushPrefs），预览里的小工具真的挪到新位置。
/// 全自绘、单视图内拖拽：overlay 盖在 WebView 上（预览只读，拦截鼠标正合适），预览区透明、托盘区自绘。
private final class WidgetOverlayView: NSView {
    private struct Item { let id: String; var slot: String }
    private let onChange: () -> Void
    private var items: [Item]
    let paletteH: CGFloat            // 预览下方托盘带高度（controller 用它布局对齐）

    private let cols = 3
    private let slotOrder = ["tl", "tc", "tr", "ml", "mc", "mr", "bl", "bc", "br"]
    private let name: [String: String] = ["sessions": "会话", "context": "上下文", "activity": "活动流",
                                          "repos": "代码仓", "power": "能量", "clock": "时间", "system": "系统"]
    // 每张卡片画出该小工具的大概形态，让人一看就知道装配到桌面后长什么样
    private let glyphKind: [String: String] = ["sessions": "list", "activity": "list", "repos": "list",
                                               "context": "bars", "system": "bars", "power": "ring", "clock": "clock"]
    private let chipW: CGFloat = 96, chipH: CGFloat = 46

    private var frames: [String: NSRect] = [:]
    private var dragging: String?
    private var dragOffset: NSPoint = .zero
    private var dragPoint: NSPoint = .zero
    private var hoverSlot: String?          // "off" = 托盘 / 移除区；nil = 无
    var state: ClaudeState? { didSet { needsDisplay = true } }   // 卡片缩略图用真实数据（controller 每拍喂）

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // 设置窗口没聚焦时也能直接拖

    init(paletteHeight: CGFloat, onChange: @escaping () -> Void) {
        self.paletteH = paletteHeight
        self.onChange = onChange
        let slots = Prefs.widgetSlots
        self.items = Prefs.widgets.map { Item(id: $0.id, slot: slots[$0.id] ?? "off") }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 外部（如 ./ld widget、菜单栏）改了槽位后同步显示
    func reload() {
        let slots = Prefs.widgetSlots
        items = Prefs.widgets.map { Item(id: $0.id, slot: slots[$0.id] ?? "off") }
        needsDisplay = true
    }

    private var previewH: CGFloat { max(0, bounds.height - paletteH) }

    private func cellRect(_ i: Int) -> NSRect {
        let cw = bounds.width / 3, ch = previewH / 3
        return NSRect(x: CGFloat(i % 3) * cw, y: CGFloat(i / 3) * ch, width: cw, height: ch)
    }

    private func layoutChips() {
        frames.removeAll()
        for (gi, slot) in slotOrder.enumerated() {
            let ids = items.filter { $0.slot == slot }.map { $0.id }
            guard !ids.isEmpty else { continue }
            let c = cellRect(gi)
            let total = CGFloat(ids.count) * chipH + CGFloat(ids.count - 1) * 4
            var y = c.midY - total / 2
            for id in ids { frames[id] = NSRect(x: c.midX - chipW / 2, y: y, width: chipW, height: chipH); y += chipH + 4 }
        }
        let offIds = items.filter { $0.slot == "off" }.map { $0.id }
        let perRow = max(1, Int(bounds.width / (chipW + 8)))
        for (k, id) in offIds.enumerated() {
            frames[id] = NSRect(x: 8 + CGFloat(k % perRow) * (chipW + 8),
                                y: previewH + 22 + CGFloat(k / perRow) * (chipH + 6), width: chipW, height: chipH)
        }
    }

    override func draw(_ dirty: NSRect) {
        layoutChips()
        let W = bounds.width, ph = previewH
        // 预览区九宫格辅助线（很淡，不遮预览）
        NSColor.white.withAlphaComponent(0.10).setStroke()
        for i in 1..<3 {
            let x = W / 3 * CGFloat(i), y = ph / 3 * CGFloat(i)
            let a = NSBezierPath(); a.move(to: NSPoint(x: x, y: 4)); a.line(to: NSPoint(x: x, y: ph - 4)); a.lineWidth = 1; a.stroke()
            let b = NSBezierPath(); b.move(to: NSPoint(x: 4, y: y)); b.line(to: NSPoint(x: W - 4, y: y)); b.lineWidth = 1; b.stroke()
        }
        // 拖拽中高亮目标格
        if let hs = hoverSlot, hs != "off", let gi = slotOrder.firstIndex(of: hs) {
            let c = cellRect(gi).insetBy(dx: 3, dy: 3)
            let bp = NSBezierPath(roundedRect: c, xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill(); bp.fill()
            NSColor.controlAccentColor.setStroke(); bp.lineWidth = 1.5; bp.stroke()
        }
        // 托盘区
        let paletteRect = NSRect(x: 0, y: ph, width: W, height: paletteH)
        NSColor.controlBackgroundColor.withAlphaComponent(hoverSlot == "off" ? 0.9 : 0.55).setFill()
        NSBezierPath(roundedRect: paletteRect.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
        drawText("未装配 · 拖到预览装配，拖回此处移除", in: NSRect(x: 8, y: ph + 4, width: W - 16, height: 15),
                 size: 10, color: .secondaryLabelColor, align: .left)
        if hoverSlot == "off" {
            let p = NSBezierPath(roundedRect: paletteRect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            NSColor.controlAccentColor.setStroke(); p.lineWidth = 1.5; p.stroke()
        }
        // 卡片（拖动中的最后画）
        for it in items where it.id != dragging {
            if let f = frames[it.id] { drawChip(it, in: f, inPreview: it.slot != "off", active: false) }
        }
        if let id = dragging, let it = items.first(where: { $0.id == id }) {
            drawChip(it, in: NSRect(x: dragPoint.x - dragOffset.x, y: dragPoint.y - dragOffset.y, width: chipW, height: chipH),
                     inPreview: false, active: true)
        }
    }

    private func drawChip(_ it: Item, in rect: NSRect, inPreview: Bool, active: Bool) {
        let bp = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if active { NSColor.controlAccentColor.setFill() }
        else if inPreview { NSColor.black.withAlphaComponent(0.62).setFill() }   // 预览上半透明深底，衬出内容
        else { NSColor.controlColor.setFill() }
        bp.fill()
        (active ? NSColor.controlAccentColor : (inPreview ? NSColor.white.withAlphaComponent(0.45) : NSColor.separatorColor)).setStroke()
        bp.lineWidth = 1; bp.stroke()
        let fg: NSColor = active ? .white : (inPreview ? .white : .labelColor)
        let tint: NSColor = active ? .white : (inPreview ? NSColor(white: 1, alpha: 0.92) : .controlAccentColor)
        // 卡片够高就画「形态缩略图（上）+ 名字（下）」——让人知道这个小工具装配后长什么样；叠放压扁时退回只画名字
        if rect.height >= 34 {
            drawWidgetPreview(it.id, in: NSRect(x: rect.minX + 9, y: rect.minY + 5, width: rect.width - 18, height: rect.height - 22), tint: tint, state: state)
            drawText(name[it.id] ?? it.id, in: NSRect(x: rect.minX, y: rect.maxY - 15, width: rect.width, height: 13), size: 10, color: fg, align: .center, weight: .medium)
        } else {
            drawText(name[it.id] ?? it.id, in: rect, size: 11, color: fg, align: .center, weight: .medium)
        }
    }

    /// 小工具的大概形态示意（与真实渲染同一隐喻，让人认出「这是哪个」即可）
    private func drawGlyph(_ kind: String, in r: NSRect, tint: NSColor) {
        switch kind {
        case "ring":
            let rad = (min(r.width, r.height) - 3) / 2, c = NSPoint(x: r.midX, y: r.midY)
            let base = NSBezierPath(); base.appendArc(withCenter: c, radius: rad, startAngle: 0, endAngle: 360)
            tint.withAlphaComponent(0.28).setStroke(); base.lineWidth = 2.5; base.stroke()
            let arc = NSBezierPath(); arc.appendArc(withCenter: c, radius: rad, startAngle: 90, endAngle: -180, clockwise: true)
            tint.setStroke(); arc.lineWidth = 2.5; arc.stroke()
        case "clock":
            drawText("12:34", in: r, size: min(15, r.height), color: tint, align: .center, weight: .medium, mono: true)
        case "bars":
            let rh = r.height / 2
            for i in 0..<2 {
                let y = r.minY + CGFloat(i) * rh + rh / 2 - 2.5
                tint.setFill(); NSBezierPath(rect: NSRect(x: r.minX, y: y, width: 12, height: 5)).fill()
                let bx = r.minX + 16, bw = max(4, r.maxX - (r.minX + 16))
                tint.withAlphaComponent(0.28).setFill(); NSBezierPath(rect: NSRect(x: bx, y: y, width: bw, height: 5)).fill()
                tint.setFill(); NSBezierPath(rect: NSRect(x: bx, y: y, width: bw * (i == 0 ? 0.7 : 0.4), height: 5)).fill()
            }
        default: // list
            let rh = r.height / 3
            let ws: [CGFloat] = [1.0, 0.8, 0.6]
            tint.setFill()
            for i in 0..<3 {
                let y = r.minY + CGFloat(i) * rh + rh / 2 - 1.5
                NSBezierPath(rect: NSRect(x: r.minX, y: y, width: r.width * ws[i], height: 3)).fill()
            }
        }
    }

    private func drawText(_ s: String, in rect: NSRect, size: CGFloat, color: NSColor, align: NSTextAlignment, weight: NSFont.Weight = .regular, mono: Bool = false) {
        let p = NSMutableParagraphStyle(); p.alignment = align; p.lineBreakMode = .byTruncatingTail
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let y = rect.midY - (font.ascender - font.descender) / 2
        (s as NSString).draw(in: NSRect(x: rect.minX, y: max(rect.minY, y), width: rect.width, height: rect.height),
                             withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    /// 卡片缩略图优先用**真实数据**（让人看到的就是装配后桌面上的样子）；对应数据缺失时才退回 drawGlyph 的示意图形。
    private func drawWidgetPreview(_ id: String, in r: NSRect, tint: NSColor, state st: ClaudeState?) {
        func bar(_ pct: Double, _ y: CGFloat, label: String?) {
            var x = r.minX
            if let label = label { drawText(label, in: NSRect(x: r.minX, y: y - 2, width: 24, height: 9), size: 7.5, color: tint, align: .left, weight: .semibold); x = r.minX + 26 }
            let bw = max(6, r.maxX - x - 20)
            tint.withAlphaComponent(0.28).setFill(); NSBezierPath(rect: NSRect(x: x, y: y, width: bw, height: 5)).fill()
            tint.setFill(); NSBezierPath(rect: NSRect(x: x, y: y, width: bw * CGFloat(max(0, min(100, pct)) / 100), height: 5)).fill()
            drawText("\(Int(pct.rounded()))%", in: NSRect(x: x + bw + 2, y: y - 2, width: 20, height: 9), size: 7.5, color: tint, align: .left)
        }
        switch id {
        case "clock":
            drawText(currentHM(), in: r, size: min(15, r.height), color: tint, align: .center, weight: .medium, mono: true)
        case "power":
            let rad = (min(r.width, r.height) - 3) / 2, c = NSPoint(x: r.midX, y: r.midY)
            let base = NSBezierPath(); base.appendArc(withCenter: c, radius: rad, startAngle: 0, endAngle: 360)
            tint.withAlphaComponent(0.28).setStroke(); base.lineWidth = 2.5; base.stroke()
            if let rm = powerRemain(st) {
                let arc = NSBezierPath(); arc.appendArc(withCenter: c, radius: rad, startAngle: 90, endAngle: 90 - 360 * rm / 100, clockwise: true)
                tint.setStroke(); arc.lineWidth = 2.5; arc.stroke()
                drawText("\(Int(rm.rounded()))", in: NSRect(x: r.minX, y: c.y - 6, width: r.width, height: 12), size: 9, color: tint, align: .center, weight: .medium)
            } else { drawText("—", in: r, size: 12, color: tint, align: .center) }
        case "system":
            if let cpu = st?.system?.cpuPct {
                bar(cpu, r.minY + 2, label: "CPU")
                if let gpu = st?.system?.gpuPct { bar(gpu, r.minY + r.height / 2 + 3, label: "GPU") }
            } else { drawGlyph("bars", in: r, tint: tint) }
        case "context":
            if let p = st?.sessions.compactMap({ $0.contextPct }).max() { bar(p, r.midY - 2, label: nil) }
            else { drawGlyph("bars", in: r, tint: tint) }
        case "sessions":
            let ss = st?.sessions ?? []
            if !ss.isEmpty {
                drawText("\(ss.count)", in: NSRect(x: r.minX, y: r.minY, width: 20, height: r.height), size: min(18, r.height), color: tint, align: .center, weight: .bold)
                let nm = (ss[0].nameIsUserSet ? ss[0].name : nil) ?? ss[0].project
                drawText(nm.uppercased(), in: NSRect(x: r.minX + 22, y: r.midY - 5, width: r.width - 22, height: 11), size: 8, color: tint, align: .left)
            } else { drawGlyph("list", in: r, tint: tint) }
        case "activity":
            if let t = st?.recentTools.first?.tool { drawText(t.uppercased(), in: r, size: min(12, r.height - 2), color: tint, align: .center, weight: .medium) }
            else { drawGlyph("list", in: r, tint: tint) }
        case "repos":
            if let rp = st?.repos.first { drawText("\(rp.branch.uppercased())  \(rp.dirty)", in: r, size: 9, color: tint, align: .center) }
            else { drawGlyph("list", in: r, tint: tint) }
        default:
            drawGlyph(glyphKind[id] ?? "list", in: r, tint: tint)
        }
    }

    /// 五小时剩余额度（与 ld-widgets 的 computePower 同口径）；无额度数据返回 nil
    private func powerRemain(_ st: ClaudeState?) -> Double? {
        guard let q = st?.quota?.fiveHour else { return nil }
        if let r = q.resetsAt, Date() >= r { return 100 }        // 窗口已过 = 满电
        return max(0, min(100, 100 - q.usedPercentage))
    }
    private func currentHM() -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - 拖拽（单视图内，全自绘无子视图争抢事件）

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil); layoutChips()
        for it in items.reversed() where frames[it.id]?.contains(p) == true {   // 叠放时取最上面那张
            dragging = it.id; let f = frames[it.id]!
            dragOffset = NSPoint(x: p.x - f.minX, y: p.y - f.minY); dragPoint = p; needsDisplay = true; return
        }
    }
    override func mouseDragged(with e: NSEvent) {
        guard dragging != nil else { return }
        dragPoint = convert(e.locationInWindow, from: nil); hoverSlot = targetSlot(at: dragPoint); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        guard let id = dragging else { return }
        let target = targetSlot(at: convert(e.locationInWindow, from: nil))
        dragging = nil; hoverSlot = nil
        if let idx = items.firstIndex(where: { $0.id == id }), items[idx].slot != target {
            items[idx].slot = target; Prefs.setWidget(id, slot: target); onChange()
        }
        needsDisplay = true
    }
    /// 落在预览区九宫格 → 该槽；托盘区 / 越界 → off（移除）
    private func targetSlot(at p: NSPoint) -> String {
        if p.y >= previewH || p.x < 0 || p.x > bounds.width || p.y < 0 { return "off" }
        let c = min(2, max(0, Int(p.x / (bounds.width / 3))))
        let r = min(2, max(0, Int(p.y / (previewH / 3))))
        return slotOrder[r * 3 + c]
    }
}

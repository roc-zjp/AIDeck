import AppKit

/// 挂在「壁纸之上、桌面图标之下」的全屏无交互窗口。
/// 全部使用公开 API：靠 window level + collectionBehavior 达成，无私有调用。
final class DesktopWindow: NSWindow {
    init(screen: NSScreen, levelOverride: Int? = nil, small: Bool = false) {
        // 实验模式用小窗口，避免测高 level 时全屏挡住用户视线
        let rect = small
            ? CGRect(x: screen.frame.minX + 24, y: screen.frame.minY + 24, width: 240, height: 150)
            : screen.frame
        super.init(contentRect: rect,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        // 桌面图标层减 1 —— 图标和右键菜单仍然正常工作，动画只接管壁纸位置
        level = NSWindow.Level(rawValue: levelOverride ?? (Int(CGWindowLevelForKey(.desktopIconWindow)) - 1))

        // 所有 Space 都在、不随 Space 切换动画、不进 Cmd-Tab / Mission管理
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        desktopLevel = level
        ignoresMouseEvents = true      // 点击穿透，桌面图标照常可选
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        canHide = false                // Cmd-H / 显示桌面时不跟着消失
        isReleasedWhenClosed = false
        displaysWhenScreenProfileChanges = true
        setFrame(rect, display: true)
    }

    /// 桌面层的原始 level，编辑 HUD 时临时抬高、结束后恢复
    private(set) var desktopLevel: NSWindow.Level = .normal

    /// 编辑模式：抬到浮动层并接收鼠标，否则回到桌面层并点击穿透
    func setEditing(_ on: Bool) {
        if on {
            level = .floating
            ignoresMouseEvents = false
            orderFrontRegardless()
        } else {
            level = desktopLevel
            ignoresMouseEvents = true
            orderFront(nil)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// occlusionState 在桌面层是否可信是本次 spike 的核心疑问，
/// 因此并行实现一套基于窗口几何的覆盖率估算作为对照/兜底。
enum DesktopCoverage {
    /// 返回屏幕被普通窗口遮挡的比例 0...1（32x18 网格采样，够用且便宜）
    static func occludedFraction(of screen: NSScreen) -> Double {
        let cols = 32, rows = 18
        var grid = [Bool](repeating: false, count: cols * rows)

        // 屏幕坐标：CGWindow 用左上原点，NSScreen 用左下原点，这里统一到 CG 坐标
        guard let primary = NSScreen.screens.first else { return 0 }
        let flippedY = primary.frame.maxY - screen.frame.maxY
        let screenRect = CGRect(x: screen.frame.minX, y: flippedY,
                                width: screen.frame.width, height: screen.frame.height)

        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return 0 }

        let myPID = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            if let pid = w[kCGWindowOwnerPID as String] as? Int32, pid == myPID { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.5 { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            let hit = r.intersection(screenRect)
            guard !hit.isNull, hit.width > 1, hit.height > 1 else { continue }

            let cw = screenRect.width / CGFloat(cols)
            let ch = screenRect.height / CGFloat(rows)
            let c0 = max(0, Int((hit.minX - screenRect.minX) / cw))
            let c1 = min(cols - 1, Int((hit.maxX - screenRect.minX - 0.001) / cw))
            let r0 = max(0, Int((hit.minY - screenRect.minY) / ch))
            let r1 = min(rows - 1, Int((hit.maxY - screenRect.minY - 0.001) / ch))
            guard c0 <= c1, r0 <= r1 else { continue }
            for ri in r0...r1 { for ci in c0...c1 { grid[ri * cols + ci] = true } }
        }
        return Double(grid.filter { $0 }.count) / Double(grid.count)
    }
}

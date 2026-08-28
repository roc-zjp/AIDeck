import Foundation

/// 小工具槽位与事件反应的偏好。存 UserDefaults，经 AnimationHost.pushConfig（契约口子 setConfig）推给每个皮肤页面。
/// 入口：菜单栏「小工具 / 事件反应」子菜单，以及 `./ld widget <id> <slot>` / `./ld fx <id> on|off`。
enum Prefs {
    // task（当前作业）已删：与会话列表 / 状态卡完全重复，属于拼氛围时凑的数
    static let widgets: [(id: String, name: String)] = [
        ("sessions", "会话列表"), ("context", "上下文占用"), ("activity", "活动流"),
        ("repos", "代码仓状态"), ("power", "能量 / 额度"), ("clock", "系统时间"),
        ("system", "系统资源（CPU / GPU / 内存 / 磁盘 + Claude 占比）"),
    ]
    // 3×3 九点位（左中右 × 上中下）+ 关闭；所有皮肤一视同仁
    static let slots: [(id: String, name: String)] = [
        ("tl", "左上"), ("tc", "顶部居中"), ("tr", "右上"),
        ("ml", "左中"), ("mc", "正中"),     ("mr", "右中"),
        ("bl", "左下"), ("bc", "底部居中"), ("br", "右下"),
        ("off", "关闭"),
    ]
    static let reactions: [(id: String, name: String)] = [
        ("toolPulse", "工具调用：光点绕环一周"), ("phaseRipple", "状态切换：涟漪"),
        ("rechargeBurst", "充能完成：能量环扫满"), ("lowPowerFlicker", "低电量：核心闪烁"),
        ("satellites", "会话卫星点：环外每会话一颗"),
    ]
    static let defaultWidgets = ["sessions": "tl", "context": "tr", "activity": "bl",
                                 "repos": "br", "power": "bc", "clock": "off",
                                 "system": "off"]   // 机器总量不是本产品的核心感知，默认关；想看的自己开（同 clock）

    static var widgetSlots: [String: String] {
        var m = defaultWidgets
        let saved = UserDefaults.standard.dictionary(forKey: "widgets") as? [String: String] ?? [:]
        for (k, v) in saved where defaultWidgets[k] != nil { m[k] = v }
        return m
    }

    static var reactionFlags: [String: Bool] {
        var m = Dictionary(uniqueKeysWithValues: reactions.map { ($0.id, true) })
        let saved = UserDefaults.standard.dictionary(forKey: "reactions") as? [String: Bool] ?? [:]
        for (k, v) in saved where m[k] != nil { m[k] = v }
        return m
    }

    /// 3D 模型（hologram 皮肤用）：内置名或 user/<文件名>；文件后来被删了也照常推给页面，页面如实显示加载失败并回落内置
    static let defaultModel = "station"
    static var model: String {
        let m = UserDefaults.standard.string(forKey: "model") ?? defaultModel
        return m.isEmpty ? defaultModel : m
    }

    // 阈值通知（AlertEngine，决策 003）：整体开关 + 「等你输入」阈值分钟
    static let alertMinuteChoices = [1, 3, 5, 10, 15]
    static var alertsEnabled: Bool {
        UserDefaults.standard.object(forKey: "alertsEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "alertsEnabled")
    }
    static func setAlertsEnabled(_ on: Bool) { UserDefaults.standard.set(on, forKey: "alertsEnabled") }
    static var alertWaitingMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: "alertWaitingMinutes")
        return v > 0 ? v : 5
    }
    static func setAlertWaitingMinutes(_ m: Int) { UserDefaults.standard.set(m, forKey: "alertWaitingMinutes") }

    /// bundle id 从 com.zhoujunpeng.livedesktop.spike 改正式后的一次性迁移（2026-08-27）：老域偏好原样搬新域。
    /// 必须在 AppDelegate 构造之前调用——它的属性初始化就在读 UserDefaults
    static func migrateFromSpikeDomain() {
        let marker = "didMigrateFromSpikeDomain"
        let std = UserDefaults.standard
        guard std.object(forKey: marker) == nil else { return }
        std.set(true, forKey: marker)
        let old = "com.zhoujunpeng.livedesktop.spike" as CFString
        guard let keys = CFPreferencesCopyKeyList(old, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty else { return }
        for k in keys {
            if let v = CFPreferencesCopyAppValue(k as CFString, old) { std.set(v, forKey: k) }
        }
    }

    /// 完整偏好：小工具 / 事件反应 / 3D 模型 + 当前皮肤自声明设置项里用户改过的值（默认值由皮肤自己持有）
    static func config(skin: String) -> [String: Any] {
        ["widgets": widgetSlots, "reactions": reactionFlags, "model": model, "skin": skinValues(skin)]
    }

    // MARK: - 皮肤自声明设置项（决策 006）：宿主不认识具体的 id，只按皮肤名存用户改过的值；schema 由皮肤页面运行时上报
    private static let skinPrefsKey = "skinPrefs"
    static func skinValues(_ skin: String) -> [String: Any] {
        (UserDefaults.standard.dictionary(forKey: skinPrefsKey)?[skin] as? [String: Any]) ?? [:]
    }
    static func setSkinValue(_ skin: String, id: String, value: Any) {
        var all = UserDefaults.standard.dictionary(forKey: skinPrefsKey) ?? [:]
        var m = (all[skin] as? [String: Any]) ?? [:]
        m[id] = value
        all[skin] = m
        UserDefaults.standard.set(all, forKey: skinPrefsKey)
    }
    static func resetSkin(_ skin: String) {
        var all = UserDefaults.standard.dictionary(forKey: skinPrefsKey) ?? [:]
        all.removeValue(forKey: skin)
        UserDefaults.standard.set(all, forKey: skinPrefsKey)
    }
    /// 命令行给的字串 → 值：on/off/true/false 是布尔，能转数字的是数字，其余原样（choice 的 id）
    static func parseSkinValue(_ s: String) -> Any {
        switch s.lowercased() {
        case "on", "true", "yes": return true
        case "off", "false", "no": return false
        default: if let d = Double(s) { return d }; return s
        }
    }

    @discardableResult
    static func setModel(_ id: String) -> Bool {
        guard ModelServer.availableModels.contains(id) else { return false }
        UserDefaults.standard.set(id, forKey: "model")
        return true
    }

    @discardableResult
    static func setWidget(_ id: String, slot: String) -> Bool {
        guard defaultWidgets[id] != nil, slots.contains(where: { $0.id == slot }) else { return false }
        var m = widgetSlots; m[id] = slot
        UserDefaults.standard.set(m, forKey: "widgets")
        return true
    }

    @discardableResult
    static func setReaction(_ id: String, on: Bool) -> Bool {
        guard reactions.contains(where: { $0.id == id }) else { return false }
        var m = reactionFlags; m[id] = on
        UserDefaults.standard.set(m, forKey: "reactions")
        return true
    }
}

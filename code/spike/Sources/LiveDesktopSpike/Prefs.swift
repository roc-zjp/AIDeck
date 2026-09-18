import CoreGraphics
import Foundation

/// 全部用户偏好的唯一入口。存 UserDefaults；皮肤相关的部分经 AnimationHost.pushConfig（契约口子 setConfig）推给页面。
/// 入口有三条且共用这里：菜单栏子菜单、设置窗口、`./ld` 命令（widget / fx / model / skin / hud …）。
///
/// 纪律：**用户偏好的 UserDefaults 键名只允许出现在本文件里**。早先状态卡那几个键（hudFloat / hudScreen / hudOffset …）
/// 直接裸写在 AppDelegate 中，同一个「状态卡偏好」概念被劈成两半、键名字符串散落十余处，
/// 2026-09-18 收口到这里。组件私有的持久化状态不算偏好（如 AlertEngine 的通知去重记录），留在各自组件内。
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
    // 宿主是槽位默认值的唯一真相源；ld.js 的 DEFAULT_CONFIG.widgets 是无宿主调试时的影子副本，改这里要同步改那里
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

    // 状态卡按需浮现（决策 011）：有会话等你时临时升到悬浮层，回复后收回。默认开启；
    // 三个时长（秒）不进设置页，先用 defaults write 调，自用验证后再定是否暴露
    static var hudAutoFloat: Bool {
        UserDefaults.standard.object(forKey: "hudAutoFloat") == nil
            ? true : UserDefaults.standard.bool(forKey: "hudAutoFloat")
    }
    static func setHudAutoFloat(_ on: Bool) { UserDefaults.standard.set(on, forKey: "hudAutoFloat") }
    /// 普通「等你输入」满多少秒才浮现（正要回它的不打扰）；卡在确认框 / 表单不等
    static var hudAutoFloatGraceSeconds: Int {
        let v = UserDefaults.standard.integer(forKey: "hudAutoFloatGrace"); return v > 0 ? v : 30
    }
    /// 每轮浮现最多保持多少秒（回复了提前收回）；长期不回的等待由菜单栏与阈值通知兜底
    static var hudAutoFloatHoldSeconds: Int {
        let v = UserDefaults.standard.integer(forKey: "hudAutoFloatHold"); return v > 0 ? v : 90
    }
    /// 鼠标静止多少秒后再动算「人回来了」——回来时若仍有会话在等，再展示一轮
    static var hudAutoFloatIdleGapSeconds: Int {
        let v = UserDefaults.standard.integer(forKey: "hudAutoFloatIdleGap"); return v > 0 ? v : 180
    }

    // MARK: - 当前皮肤

    static let defaultAnimation = "jarvis.html"
    static var animation: String { UserDefaults.standard.string(forKey: "animation") ?? defaultAnimation }
    static func setAnimation(_ name: String) { UserDefaults.standard.set(name, forKey: "animation") }

    // MARK: - 首启引导

    /// 读一次即置位：第一次运行弹一次欢迎面板
    static func consumeFirstLaunch() -> Bool {
        guard !UserDefaults.standard.bool(forKey: "didLaunchBefore") else { return false }
        UserDefaults.standard.set(true, forKey: "didLaunchBefore")
        return true
    }

    // MARK: - 状态卡：层级与交互

    /// 常驻置顶悬浮（盖在所有窗口之上）。与按需浮现（hudAutoFloat）互不覆盖，任一生效即抬层
    static var hudFloat: Bool { UserDefaults.standard.bool(forKey: "hudFloat") }
    static func setHudFloat(_ on: Bool) { UserDefaults.standard.set(on, forKey: "hudFloat") }

    /// 点击穿透：开着就不响应拖动与单击直达
    static var hudClickThrough: Bool { UserDefaults.standard.bool(forKey: "hudClickThrough") }
    static func setHudClickThrough(_ on: Bool) { UserDefaults.standard.set(on, forKey: "hudClickThrough") }

    // MARK: - 状态卡：位置（决策 010 —— 家屏 displayID + 屏内偏移）

    /// 家屏 displayID：用户最后把卡放在哪块屏。那块屏不在时临时落主屏，但**不改写**这个值，插回即归位
    static var hudScreenID: Double? { UserDefaults.standard.object(forKey: "hudScreen").flatMap(num) }
    /// 相对家屏原点的偏移；nil 表示没有自由位置，按 hudAnchor 吸附四角
    static var hudOffset: CGPoint? {
        guard let a = UserDefaults.standard.array(forKey: "hudOffset"), a.count == 2,
              let x = num(a[0]), let y = num(a[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }
    static var hudAnchor: String { UserDefaults.standard.string(forKey: "hudAnchor") ?? "br" }

    /// 松手 / 编辑结束：记下家屏与屏内偏移，并清掉所有旧格式的位置键
    static func setHudPosition(screenID: UInt32, offset: CGPoint) {
        let d = UserDefaults.standard
        d.set(Int(screenID), forKey: "hudScreen")
        d.set([Double(offset.x), Double(offset.y)], forKey: "hudOffset")
        legacyPositionKeys.forEach(d.removeObject(forKey:))
    }

    /// 吸附四角 = 清掉自由位置（含旧格式），卡留在当前家屏
    static func setHudAnchor(_ a: String) {
        let d = UserDefaults.standard
        d.removeObject(forKey: "hudOffset")
        legacyPositionKeys.forEach(d.removeObject(forKey:))
        d.set(a, forKey: "hudAnchor")
    }

    /// 菜单里给四角打勾用：有自由位置时四角都不打勾
    static var hasFreeHudPosition: Bool {
        (["hudOffset"] + legacyPositionKeys).contains { UserDefaults.standard.object(forKey: $0) != nil }
    }

    /// 决策 010 之前每屏一张、按 displayID 各存偏移（hudPositions），更早只有主屏绝对坐标（hudX/hudY）
    private static let legacyPositionKeys = ["hudPositions", "hudX", "hudY"]

    /// 旧格式位置：升级后首次布局时沿用，保存过一次新格式就再不会走到这里
    static func legacyHudOrigin(screenID: UInt32, screenOrigin: CGPoint) -> CGPoint? {
        let d = UserDefaults.standard
        if let saved = d.dictionary(forKey: "hudPositions"),
           let a = saved[String(screenID)] as? [Any], a.count == 2,
           let x = num(a[0]), let y = num(a[1]) {
            return CGPoint(x: screenOrigin.x + x, y: screenOrigin.y + y)
        }
        if d.object(forKey: "hudX") != nil {
            return CGPoint(x: d.double(forKey: "hudX"), y: d.double(forKey: "hudY"))
        }
        return nil
    }

    /// 宽容解析：runtime 存的是数字，手工 `defaults write` 进来的是字符串，两种都认
    static func num(_ v: Any) -> Double? { (v as? NSNumber)?.doubleValue ?? Double(v as? String ?? "") }

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

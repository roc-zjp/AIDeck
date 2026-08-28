import AppKit
import UserNotifications

/// 三层感知的第三层：阈值通知，长尾兜底（决策 003，覆盖「Claude 说完 15 分钟以上才回来」的 12.8%）。
/// 只做两类，常规状态播报一律不走通知——通知一旦变成噪音就会被关掉，长尾兜底也就没了：
///   1. 会话「等你输入」超过阈值（默认 5 分钟）：每次等待只发一次，点通知唤起该会话所在的终端。
///      跨越语义：只在运行期间看到时长跨过阈值才发；启动时就已超阈值的视为已通知，
///      否则每次重启都会把过夜的会话全轰一遍（常驻场景下跨越必然发生在运行中，语义不丢）。
///   2. 额度跨 80% / 95%：每个重置窗口每档一次，记录持久化，重启不重发。
final class AlertEngine: NSObject, UNUserNotificationCenterDelegate {
    private var waitingNotified: Set<String> = []       // sessionId：本次等待已通知（或启动时已超阈值）
    private var quotaNotified: [String: Double] = [:]   // 窗口 key → 已通知的最高档
    private var authorized = false
    private var seeded = false                          // 首拍把已超阈值的等待标记为已通知
    let hasBundle = Bundle.main.bundleIdentifier != nil

    /// 系统层面的通知授权状态（设置页据此提示）。以前用户一旦点了「不允许」，post() 就静默返回，
    /// 而设置页的「阈值通知」勾选框还亮着——用户以为开着，其实永远收不到
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        quotaNotified = (UserDefaults.standard.dictionary(forKey: "alertQuotaNotified") as? [String: Double]) ?? [:]
        guard hasBundle else { return }     // 裸二进制（开发态/CLI）没有通知能力，UNUserNotificationCenter 会直接崩
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestAuthorization()
    }

    /// 向系统申请授权（只有 notDetermined 时系统才会真的弹框；已拒绝的只能去系统设置改）
    func requestAuthorization(_ done: (() -> Void)? = nil) {
        guard hasBundle else { done?(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            DispatchQueue.main.async {
                self?.authorized = ok
                self?.refreshAuthorizationStatus(done)
            }
        }
    }

    /// 重新读一次系统授权状态（用户可能刚在系统设置里改过）
    func refreshAuthorizationStatus(_ done: (() -> Void)? = nil) {
        guard hasBundle else { done?(); return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            DispatchQueue.main.async {
                self?.authorizationStatus = s.authorizationStatus
                self?.authorized = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
                done?()
            }
        }
    }

    /// AppDelegate 每秒喂一次（state.quota 已就位）
    func tick(_ state: ClaudeState) {
        guard Prefs.alertsEnabled else { return }
        let threshold = Prefs.alertWaitingMinutes * 60

        var stillWaiting: Set<String> = []
        for s in state.sessions where s.phase == .waiting && !s.id.isEmpty {
            stillWaiting.insert(s.id)
            guard s.idleSeconds >= threshold, !waitingNotified.contains(s.id) else { continue }
            waitingNotified.insert(s.id)
            if seeded {     // 首拍只登记不发
                let name = (s.nameIsUserSet ? s.name : nil) ?? s.project
                post(id: "waiting-\(s.id)",
                     title: "\(name) 等你输入",
                     body: "已等待 \(max(1, s.idleSeconds / 60)) 分钟，点击回到对应终端",
                     sound: true, userInfo: ["pid": Int(s.pid)])
            }
        }
        // 不再等待（回答了 / 会话关了）就复位，下一次等待重新计
        waitingNotified.formIntersection(stillWaiting)
        seeded = true

        if let q = state.quota {
            check(q.fiveHour, label: "五小时额度", key: "5h")
            check(q.sevenDay, label: "七天额度", key: "7d")
        }
    }

    private func check(_ window: QuotaWindow?, label: String, key: String) {
        guard let w = window else { return }
        let wKey = "\(key)-\(Int(w.resetsAt?.timeIntervalSince1970 ?? 0))"
        guard let top = [80.0, 95.0].filter({ w.usedPercentage >= $0 }).max(),
              (quotaNotified[wKey] ?? 0) < top else { return }
        quotaNotified[wKey] = top
        // 只留时间戳最新的 12 条记录，别让 UserDefaults 越攒越多
        if quotaNotified.count > 12 {
            let sorted = quotaNotified.keys.sorted { (Int($0.split(separator: "-").last ?? "0") ?? 0)
                                                   < (Int($1.split(separator: "-").last ?? "0") ?? 0) }
            sorted.prefix(quotaNotified.count - 12).forEach { quotaNotified.removeValue(forKey: $0) }
        }
        UserDefaults.standard.set(quotaNotified, forKey: "alertQuotaNotified")
        var body = "已用 \(Int(w.usedPercentage.rounded()))%"
        if let r = w.resetsAt {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            body += "，\(f.string(from: r)) 重置"
        }
        post(id: "quota-\(wKey)-\(Int(top))", title: "\(label)已用超 \(Int(top))%", body: body,
             sound: false, userInfo: [:])
    }

    private func post(id: String, title: String, body: String, sound: Bool, userInfo: [String: Any]) {
        guard hasBundle, authorized else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = userInfo
        if sound { c.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // MARK: - 点通知 → 唤起会话所在终端

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let pid = (response.notification.request.content.userInfo["pid"] as? NSNumber)?.int32Value, pid > 0 {
            Self.activateApp(owning: pid)
        }
        done()
    }

    /// App 自己在前台时也照常出横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }

    /// 沿 pid 祖先链找到第一个常规 GUI 应用（Terminal / iTerm / VS Code…）并激活。
    /// 只能激活到 App 级，具体窗口/标签页无从得知——聊胜于无的最大努力
    static func activateApp(owning pid: Int32) {
        var p = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                if #available(macOS 14.0, *) { app.activate() }
                else { app.activate(options: [.activateIgnoringOtherApps]) }
                return
            }
            let pp = parentPID(p)
            guard pp > 1 else { return }
            p = pp
        }
    }

    private static func parentPID(_ pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}

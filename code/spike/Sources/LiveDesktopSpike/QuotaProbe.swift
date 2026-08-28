import Foundation

/// 一个额度窗口（五小时 / 七天）：Claude Code 自己算好、喂给 statusline 的数字，不是我们估的
struct QuotaWindow {
    var usedPercentage: Double
    var resetsAt: Date?
    var jsonObject: [String: Any] {
        ["usedPercentage": usedPercentage,
         "resetsAt": resetsAt.map { $0.timeIntervalSince1970 } as Any]
    }
}

struct QuotaSnapshot {
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    var recordedAt: Date          // ld-statusline 记录这份数据的时刻，页面用它标注"数字真到几点"
    var jsonObject: [String: Any] {
        ["recordedAt": recordedAt.timeIntervalSince1970,
         "fiveHour": fiveHour?.jsonObject as Any,
         "sevenDay": sevenDay?.jsonObject as Any]
    }
}

/// 只读 ~/.config/live-desktop/rate-limits.json（由 ld-statusline 原子写入）。
/// 与读 jsonl 同级的零侵入：不碰凭证、不发请求；Claude Code 不跑就没有新数据，页面会如实标出时间。
final class QuotaProbe {
    /// 默认 ~/.config/live-desktop；LIVE_DESKTOP_DIR 仅供沙箱测试重定向，与 ld-statusline 约定一致
    static let dir: URL = {
        if let d = ProcessInfo.processInfo.environment["LIVE_DESKTOP_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/live-desktop", isDirectory: true)
    }()
    static let recordURL = dir.appendingPathComponent("rate-limits.json")

    private var lastMtime: Date?
    private var cached: QuotaSnapshot?

    func read() -> QuotaSnapshot? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.recordURL.path),
              let mtime = attrs[.modificationDate] as? Date else { cached = nil; lastMtime = nil; return nil }
        if mtime == lastMtime { return cached }        // 文件没变就不重新解析
        lastMtime = mtime
        cached = Self.parse(url: Self.recordURL)
        return cached
    }

    static func parse(url: URL) -> QuotaSnapshot? {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        func window(_ key: String) -> QuotaWindow? {
            guard let w = o[key] as? [String: Any], let p = w["usedPercentage"] as? Double else { return nil }
            let r = (w["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return QuotaWindow(usedPercentage: p, resetsAt: r)
        }
        let recorded = (o["recordedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        let snap = QuotaSnapshot(fiveHour: window("fiveHour"), sevenDay: window("sevenDay"), recordedAt: recorded)
        return (snap.fiveHour == nil && snap.sevenDay == nil) ? nil : snap
    }
}

import Foundation

/// 诊断日志（`--log` 开启）：每秒一行写 diag.csv，是 P0 判据 `./ld report` 的唯一数据源。
///
/// 两条约束决定了它的形状：**不能清空**（重启 / launchd 拉起都要追加，否则判据断档），
/// 也**不能无限长**（2026-08-28 已 12.5 MB，一年 2 GB）。所以按本地日期轮转：
/// 当前文件永远叫 `diag.csv`（report.py 与老习惯不变），跨天时改名 `diag-<最后一行的日期>.csv` 归档，
/// 只保留最近 `retentionDays` 天；report.py 会把归档一起读。
///
/// 从 AppDelegate 抽出来（2026-09-18）：它与状态、窗口、菜单栏都无关，只消费一份快照。
final class DiagLogger {
    /// 一拍的诊断快照。字段顺序即 CSV 列顺序，与 `header` 对应
    struct Sample {
        var phase: String
        var tool: String
        var sessions: Int
        var occluded: Bool
        var coverage: Double
        var rendering: Bool
        var fps: Double
        var probeMillis: Double
        var coverageMillis: Double
        var onBattery: Bool
        var visibility: String     // 页面自检的 document.visibilityState
        var realFrames: Int        // 两拍之间页面真实跑了多少帧
    }

    private static let retentionDays = 30
    private static let header = "ts,phase,tool,sessions,occluded,coverage,rendering,fps,probeMs,coverageMs,battery,vis,realFps\n"
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private let dir: String
    private var handle: FileHandle?
    private var day = ""                    // 当前 diag.csv 对应的本地日期
    private var path: String { dir + "/diag.csv" }

    /// 目录默认取进程当前工作目录（`./ld start` 从 code/app 起，diag.csv 就落在那里）
    init(directory: String = FileManager.default.currentDirectoryPath) {
        self.dir = directory
    }

    /// 打开当日文件并接上（上次运行留下的若属更早日期，先归档）。失败不抛——诊断停用，主功能不受影响
    func open() {
        let fm = FileManager.default
        let today = Self.dayFormatter.string(from: Date())
        // 上次运行留下的文件若属于更早的日期（mtime = 最后一行写入的那天），先归档再开新的
        if fm.fileExists(atPath: path),
           let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            let d = Self.dayFormatter.string(from: m)
            if d != today { archive(as: d) }
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: Self.header.data(using: .utf8))
        }
        handle = FileHandle(forWritingAtPath: path)
        day = today
        if let h = handle {
            _ = try? h.seekToEnd()
            log("[diag] 写入 \(path)")
        } else {
            // 以前这里静默：cwd 不可写（如双击 .app 时 cwd=/）诊断就悄悄没了
            log("[diag] 打不开 \(path)（目录不可写？），诊断日志停用")
        }
        prune()
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    /// 写一行。未开启（open 没调过或失败）时静默跳过
    func write(_ s: Sample) {
        guard handle != nil else { return }
        let today = Self.dayFormatter.string(from: Date())
        if today != day {                                  // 跨天：关掉、归档昨天的、开今天的
            close()
            archive(as: day)
            open()
            guard handle != nil else { return }
        }
        let line = String(format: "%@,%@,%@,%d,%d,%.3f,%d,%.0f,%.2f,%.2f,%d,%@,%d\n",
                          ISO8601DateFormatter().string(from: Date()),
                          s.phase, s.tool, s.sessions,
                          s.occluded ? 1 : 0, s.coverage,
                          s.rendering ? 1 : 0, s.fps,
                          s.probeMillis, s.coverageMillis, s.onBattery ? 1 : 0,
                          s.visibility, s.realFrames)
        do {
            // 用会抛 Swift 错误的 write(contentsOf:)：老的 write(_:) 在磁盘满时抛 ObjC 异常，Swift 接不住、进程直接崩
            try handle?.write(contentsOf: line.data(using: .utf8)!)
        } catch {
            // 磁盘满 / 文件被挪走：停掉诊断，主功能不受影响，也不再每秒重试
            log("[diag] 写入失败（\(error.localizedDescription)），诊断日志停用")
            close()
        }
    }

    /// diag.csv → diag-<day>.csv；同名已存在就加序号，绝不覆盖
    private func archive(as day: String) {
        let fm = FileManager.default
        var dst = dir + "/diag-\(day).csv"
        var n = 1
        while fm.fileExists(atPath: dst) { dst = dir + "/diag-\(day)-\(n).csv"; n += 1 }
        do {
            try fm.moveItem(atPath: path, toPath: dst)
            log("[diag] 已归档 \(dst)")
        } catch {
            log("[diag] 归档失败：\(error.localizedDescription)")
        }
    }

    /// 删掉超过保留期的归档。文件名里的 yyyy-MM-dd 字典序即时间序
    private func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let cutoff = Self.dayFormatter.string(from: Date(timeIntervalSinceNow: -Double(Self.retentionDays) * 86400))
        for n in names where n.hasPrefix("diag-") && n.hasSuffix(".csv") {
            let d = String(n.dropFirst("diag-".count).prefix(10))
            if d < cutoff { try? fm.removeItem(atPath: dir + "/" + n) }
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}

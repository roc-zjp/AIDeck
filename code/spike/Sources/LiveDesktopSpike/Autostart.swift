import Foundation

/// 开机自启 = 一个 LaunchAgent plist（RunAtLoad + 崩溃拉起），与 ./ld autostart 写的是同一个文件。
/// KeepAlive 用 SuccessfulExit=false：只在异常退出（崩溃 / 非零退出码）时拉起，
/// 菜单「退出」与 ./ld stop（SIGTERM → 温和收尾 → exit 0）不会被 launchd 缠着重启。
/// 从 UI 开启时只写 plist、不当场 launchctl load——App 正在跑，load 会立刻再拉起一个实例；
/// 下次登录生效，KeepAlive 从那时起接管保活（崩了自动拉起）。
enum Autostart {
    static let label = "com.zhoujunpeng.livedesktop"
    static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// bundle id 去掉 .spike 后的一次性迁移：老 label 的 plist 换名重写、删旧文件。
    /// 不动 launchctl——老 job 若本次登录已加载，注销前继续兜底崩溃拉起，下次登录由新 label 接管
    static func migrateFromSpikeLabel() {
        let fm = FileManager.default
        let old = plistURL.deletingLastPathComponent().appendingPathComponent("com.zhoujunpeng.livedesktop.spike.plist")
        guard fm.fileExists(atPath: old.path) else { return }
        try? fm.removeItem(at: old)
        try? enable()
    }

    /// 自启模式的 stderr 落这里——否则 launchd 拉起时全部诊断日志无处可去（自启出问题零线索）
    static var stderrLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AIDeck.log")
    }

    static func enable() throws {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let cwd = FileManager.default.currentDirectoryPath
        let logPath = stderrLogURL.path
        // StandardErrorPath 的目录必须先存在，否则 launchd 静默丢弃重定向
        try? FileManager.default.createDirectory(at: stderrLogURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>\(exe)</string><string>--log</string></array>
          <key>WorkingDirectory</key><string>\(cwd)</string>
          <key>StandardErrorPath</key><string>\(logPath)</string>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
        </dict></plist>
        """
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try xml.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    static func disable() throws {
        // 若当前实例正由 launchd 管着，unload 会当场杀掉自己（设置窗口一起消失）——
        // 这种情况只删 plist：下次登录不再自启，本次登录 KeepAlive 保活到注销为止
        if launchdPID() != getpid() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["unload", plistURL.path]
            try? p.run()
            p.waitUntilExit()
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    /// launchd 眼中该 label 的运行 PID；未加载 / 未运行返回 -1
    private static func launchdPID() -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["list", label]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let r = out.range(of: #""PID"\s*=\s*(\d+)"#, options: .regularExpression),
              let pid = Int32(out[r].components(separatedBy: CharacterSet.decimalDigits.inverted).joined())
        else { return -1 }
        return pid
    }
}

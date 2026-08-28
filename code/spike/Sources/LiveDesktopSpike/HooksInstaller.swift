import Foundation

/// 把 ld-hook 接进 Claude Code 的 `Notification` hook，或撤掉（决策 009）。
///
/// 与 QuotaInstaller（statusLine，正则外科手术）**不同**：hooks 是 `事件名 → 数组 → 对象` 的嵌套结构，
/// 正则改写不可靠（issues.md 2026-08-28 的坑）。这里改用**整份 JSONSerialization 解析 → 内存里增删我们那一条 → 重写**。
/// 代价：重排键序、丢 JSONC 注释；换来的是对「已有其它 hooks 的用户」也安全。改前整份备份，可一键恢复。
///
/// 只加/删一条：`hooks.Notification` 数组里 command 指向本机 ld-hook 的那个 group。用户原有 hooks 原样保留。
/// 用法（命令行）：AIDeck --hooks install | uninstall | status
enum HooksInstaller {
    static let dir = QuotaProbe.dir
    static let hookBinaryURL = dir.appendingPathComponent("ld-hook")
    static var settingsURL: URL { QuotaInstaller.settingsURL }
    static var backupDir: URL { QuotaInstaller.backupDir }
    static let event = "Notification"

    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(_ args: [String]) -> Int32 {
        do {
            switch args.first ?? "status" {
            case "install":   try install();   print(statusText())
            case "uninstall": try uninstall(); print(statusText())
            case "status":    print(statusText())
            default: print("用法: --hooks install | uninstall | status"); return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write("失败：\(error)\n".data(using: .utf8)!)
            return 1
        }
    }

    // MARK: - 识别「我们的」条目

    private static func isOurs(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains("ld-hook") ?? false }
    }

    /// 我们要加的那个 group：matcher "*"（订全部 Notification，由 ld-hook 自己按 notification_type 筛）
    private static func ourGroup() -> [String: Any] {
        ["matcher": "*",
         "hooks": [["type": "command", "command": hookBinaryURL.path, "timeout": 5]]]
    }

    // MARK: - 安装

    static func install() throws {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try installHookBinary()      // 幂等：每次刷新二进制，app 挪位置也不坏

        var root = try readSettings()
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var groups = (hooks[event] as? [[String: Any]]) ?? []
        if groups.contains(where: isOurs) {
            print("已接入，仅更新 ld-hook 二进制")
            return
        }
        _ = try backupSettings()     // 只有真要改文件时才备份
        groups.append(ourGroup())
        hooks[event] = groups
        root["hooks"] = hooks
        try writeSettings(root)
    }

    // MARK: - 卸载

    static func uninstall() throws {
        var root = try readSettings()
        guard var hooks = root["hooks"] as? [String: Any],
              var groups = hooks[event] as? [[String: Any]],
              groups.contains(where: isOurs) else {
            try? removeHookFiles()
            print("settings.json 里没有我们的 Notification hook，只清理了本地文件")
            return
        }
        _ = try backupSettings()
        groups.removeAll(where: isOurs)
        if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeSettings(root)
        try? removeHookFiles()
    }

    private static func removeHookFiles() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: hookBinaryURL.path) { try fm.removeItem(at: hookBinaryURL) }
        let hd = dir.appendingPathComponent("hooks", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: hd, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" { try? fm.removeItem(at: f) }
        }
    }

    // MARK: - 状态

    struct Status {
        var installed: Bool         // settings.json 里有指向本机 ld-hook 的 Notification hook
        var otherCommand: String?   // 指向的是别的路径的 ld-hook（app 换过位置 / 手工配过）
    }

    static func inspect() -> Status {
        guard let root = try? readSettings(),
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]] else { return Status(installed: false) }
        for g in groups where isOurs(g) {
            let cmd = (g["hooks"] as? [[String: Any]])?
                .compactMap { $0["command"] as? String }.first { $0.contains("ld-hook") }
            return Status(installed: cmd == hookBinaryURL.path, otherCommand: cmd == hookBinaryURL.path ? nil : cmd)
        }
        return Status(installed: false)
    }

    static func statusText() -> String {
        let st = inspect()
        if st.installed { return "已接入 · Notification hook 指向 \(hookBinaryURL.path)" }
        if let other = st.otherCommand { return "接入路径不一致：settings.json 指向 \(other)，重新接入即可修正" }
        return "未接入 · 权限确认 / MCP 表单的精细态不可用（其余功能不受影响）"
    }

    // MARK: - 文件读写

    private static func readSettings() throws -> [String: Any] {
        let text = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? "{}"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            throw Failure(description: "settings.json 不是合法的 JSON 对象，为安全起见不做修改")
        }
        return root
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let fm = FileManager.default
        let tmp = settingsURL.deletingLastPathComponent().appendingPathComponent(".settings.json.ld-hook-tmp")
        try data.write(to: tmp)
        if let attrs = try? fm.attributesOfItem(atPath: settingsURL.path), let perm = attrs[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: perm], ofItemAtPath: tmp.path)
        }
        guard rename(tmp.path, settingsURL.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw Failure(description: "写入 \(settingsURL.path) 失败：\(String(cString: strerror(errno)))")
        }
    }

    @discardableResult
    private static func backupSettings() throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss.SSS"
        let base = "settings.json.\(f.string(from: Date()))"
        var backup = backupDir.appendingPathComponent(base)
        var n = 1
        while fm.fileExists(atPath: backup.path) { backup = backupDir.appendingPathComponent("\(base)-\(n)"); n += 1 }
        try fm.copyItem(at: settingsURL, to: backup)
        return backup
    }

    private static func installHookBinary() throws {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ld-hook"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("LdHook"),
        ].compactMap { $0 }
        guard let src = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw Failure(description: "找不到 ld-hook 二进制（应在 .app/Contents/MacOS/）")
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: hookBinaryURL.path) { try fm.removeItem(at: hookBinaryURL) }
        try fm.copyItem(at: src, to: hookBinaryURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookBinaryURL.path)
    }
}

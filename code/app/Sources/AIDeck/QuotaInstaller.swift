import Foundation

/// 把 ld-statusline 接进 Claude Code 的 statusLine，或恢复原样。
///
/// 这是本项目**唯一**会改用户 settings.json 的地方（决策 005）：只碰 `statusLine` 一个键；
/// 改前把整份文件备份到 ~/.config/live-desktop/backups/；原命令原样保留在 statusline.json 作透传；一条命令恢复。
/// 用法（命令行）：AIDeck --quota install | uninstall | status
///
/// statusLine 在 settings 里有两种写法，都要认：
///   对象   {"type":"command","command":"...","padding":"normal","refreshInterval":1000,"hideVimModeIndicator":false}
///   字符串 "~/.claude/statusline.sh"（等价于 type=command）
enum QuotaInstaller {
    static let dir = QuotaProbe.dir
    static let wrapperURL = dir.appendingPathComponent("ld-statusline")
    static let configURL = dir.appendingPathComponent("statusline.json")
    static let backupDir = dir.appendingPathComponent("backups", isDirectory: true)

    /// 与 Claude Code 一致：尊重 CLAUDE_CONFIG_DIR，便于在沙箱目录里测试而不碰真实配置
    static var claudeDir: URL {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
    static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(_ args: [String]) -> Int32 {
        do {
            switch args.first ?? "status" {
            case "install":   try install();   print(status())
            case "uninstall": try uninstall(); print(status())
            case "status":    print(status())
            default: print("用法: --quota install | uninstall | status"); return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write("失败：\(error)\n".data(using: .utf8)!)
            return 1
        }
    }

    // MARK: - 安装

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try installWrapperBinary()

        var text = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? "{}\n"
        let original = try currentStatusLine(in: text)      // nil = 用户原本没配状态栏
        let originalCommand = command(of: original)

        // 幂等：已经指向我们，只刷新二进制、不再套一层（否则透传会指向自己成环）
        if isOurs(originalCommand) {
            print("已接入，仅更新 wrapper 二进制")
            return
        }

        // 备份整份 settings.json —— 就算我们的改写出错，用户也能整文件恢复
        let backup = try backupSettings()

        // 新对象：保留用户原有的 padding / refreshInterval / hideVimModeIndicator 等键，只换 type/command
        var newObj: [String: Any] = (original as? [String: Any]) ?? [:]
        newObj["type"] = "command"
        newObj["command"] = wrapperURL.path
        text = try replacingStatusLine(in: text, with: newObj)
        try atomicWrite(text, to: settingsURL)

        let cfg: [String: Any] = [
            "version": 1,
            "installedAt": Date().timeIntervalSince1970,
            "wrapper": wrapperURL.path,
            "passthrough": originalCommand as Any,
            "originalStatusLine": original as Any,
            "settingsBackup": backup?.path as Any,
        ]
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configURL, options: .atomic)
    }

    // MARK: - 卸载

    static func uninstall() throws {
        guard let cfgData = try? Data(contentsOf: configURL),
              let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any] else {
            throw Failure(description: "没有找到安装记录 \(configURL.path)，无需卸载")
        }
        var text = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? "{}\n"
        let current = try currentStatusLine(in: text)
        guard isOurs(command(of: current)) else {
            // 用户已自己改回去了，只清我们的文件
            try removeOurFiles()
            print("settings.json 的 statusLine 已不是我们的，只清理了本地文件")
            return
        }
        _ = try backupSettings()
        let orig = cfg["originalStatusLine"]
        if let o = orig as? [String: Any] {
            text = try replacingStatusLine(in: text, with: o)
        } else if let s = orig as? String {
            text = try replacingStatusLine(in: text, withString: s)
        } else {
            text = try removingStatusLine(in: text)
        }
        try atomicWrite(text, to: settingsURL)
        try removeOurFiles()
    }

    private static func removeOurFiles() throws {
        let fm = FileManager.default
        for u in [wrapperURL, configURL, QuotaProbe.recordURL] where fm.fileExists(atPath: u.path) {
            try fm.removeItem(at: u)
        }
    }

    private static func backupSettings() throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss.SSS"
        let base = "settings.json.\(f.string(from: Date()))"
        // 同一毫秒内连续 install/uninstall 也不能撞名
        var backup = backupDir.appendingPathComponent(base)
        var n = 1
        while fm.fileExists(atPath: backup.path) { backup = backupDir.appendingPathComponent("\(base)-\(n)"); n += 1 }
        try fm.copyItem(at: settingsURL, to: backup)
        return backup
    }

    // MARK: - 状态

    /// 结构化状态：设置页、菜单栏与文本版 status() 共用同一次判定。
    /// 接入与否看 settings.json 指向谁；数据链路是否健康看 rate-limits.json 的新鲜度——
    /// statusLine 可能被项目级 / 托管 settings 覆盖，键还在但数据早断了（spec 风险 2）。
    struct Status {
        var currentCommand: String?     // settings.json 里 statusLine 现在指向的命令；nil = 未配置
        var installed: Bool             // 指向的是我们的 wrapper
        var hasRecord: Bool             // 本机有安装记录（statusline.json）；true 而 installed=false 说明被顶掉了
        var passthrough: String?        // 透传的原命令
        var backupPath: String?         // 安装前的整份 settings.json 备份
        var snapshot: QuotaSnapshot?    // rate-limits.json 当前内容
    }

    static func inspect() -> Status {
        let text = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? ""
        let cmd = command(of: (try? currentStatusLine(in: text)) ?? nil)
        var st = Status(currentCommand: cmd, installed: isOurs(cmd),
                        hasRecord: false, passthrough: nil, backupPath: nil,
                        snapshot: QuotaProbe.parse(url: QuotaProbe.recordURL))
        if let d = try? Data(contentsOf: configURL),
           let cfg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            st.hasRecord = true
            st.passthrough = cfg["passthrough"] as? String
            st.backupPath = cfg["settingsBackup"] as? String
        }
        return st
    }

    static func status() -> String {
        let st = inspect()
        var lines: [String] = []
        lines.append("settings.json：\(settingsURL.path)")
        lines.append("statusLine.command：\(st.currentCommand ?? "（未配置）")  " + (st.installed ? "← 已接入 ld-statusline" : "← 未接入"))
        if st.hasRecord {
            lines.append("透传给原命令：\(st.passthrough ?? "（无，用户原本没配状态栏）")")
            if let b = st.backupPath { lines.append("安装前备份：\(b)") }
        }
        if let snap = st.snapshot {
            let age = Int(Date().timeIntervalSince(snap.recordedAt))
            var s = "额度记录：\(age)s 前"
            if let f = snap.fiveHour {
                s += "  5h 已用 \(Int(f.usedPercentage.rounded()))%"
                if let r = f.resetsAt { s += " 重置于 \(clock(r))" }
            }
            if let w = snap.sevenDay {
                s += "  7d 已用 \(Int(w.usedPercentage.rounded()))%"
                if let r = w.resetsAt { s += " 重置于 \(clock(r))" }
            }
            lines.append(s)
        } else {
            lines.append("额度记录：暂无（Claude Code 刷新一次状态栏后才会有；仅 Pro/Max 订阅有此数据）")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: d)
    }

    // MARK: - settings.json 外科手术式改写（保留用户文件的其余格式）

    private static func isOurs(_ command: String?) -> Bool {
        command?.contains("ld-statusline") ?? false
    }

    private static func command(of statusLine: Any?) -> String? {
        if let s = statusLine as? String { return s }
        return (statusLine as? [String: Any])?["command"] as? String
    }

    /// statusLine 的值：平对象（不含嵌套花括号）或 JSON 字符串
    private static let statusLinePattern = #""statusLine"\s*:\s*(\{[^{}]*\}|"(?:[^"\\]|\\.)*")"#

    /// 返回 [String: Any]（对象写法）、String（字符串写法）或 nil（没配）。
    ///
    /// 正则只认「平对象 / 字符串」两种写法；command 里含花括号（jq 过滤器很常见）或值是嵌套对象时会失配。
    /// 失配以前被当成「没配」走插入分支，用户文件里就会出现**两个 statusLine 键**（2026-08-28 审计发现）。
    /// 所以先把整份文件按 JSON 解析核对：键在而正则找不到 → 拒绝改；正则找到的值与 JSON 解析结果对不上 → 拒绝改。
    /// 这是全项目唯一写用户配置的地方，宁可不改，不能改错
    static func currentStatusLine(in text: String) throws -> Any? {
        var expected: Any?     // 整份 JSON 解析出的 statusLine 值（NSNull 表示键在但为 null）
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let root = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
                throw Failure(description: "settings.json 不是合法的 JSON 对象，为安全起见不做修改")
            }
            expected = root["statusLine"]
        }
        guard let r = text.range(of: statusLinePattern, options: .regularExpression) else {
            if expected != nil {
                throw Failure(description: "settings.json 里的 statusLine 写法超出本工具能安全改写的范围（command 含花括号或值是嵌套对象），"
                              + "为安全起见不做修改；请先把它简化为 {\"type\":\"command\",\"command\":\"<脚本路径>\"} 再重试")
            }
            return nil
        }
        let m = String(text[r])
        guard let colon = m.firstIndex(of: ":") else { return nil }
        let value = m[m.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // 用数组包一层交给 JSONSerialization，对象和字符串两种值都能解析
        guard let arr = try? JSONSerialization.jsonObject(with: Data("[\(value)]".utf8)) as? [Any], let v = arr.first
        else { throw Failure(description: "settings.json 里的 statusLine 无法解析，为安全起见不做修改") }
        // 正则命中的必须就是 JSON 里那个键（别的字符串值里恰好出现 "statusLine": {...} 字样时会命中错位置）
        if let e = expected, command(of: e) != command(of: v) {
            throw Failure(description: "settings.json 里 statusLine 的位置无法可靠定位，为安全起见不做修改")
        }
        return v
    }

    static func replacingStatusLine(in text: String, with obj: [String: Any]) throws -> String {
        try replacingStatusLine(in: text) { indent in render(obj, indent: indent) }
    }

    static func replacingStatusLine(in text: String, withString s: String) throws -> String {
        try replacingStatusLine(in: text) { _ in jsonString(s) }
    }

    private static func replacingStatusLine(in text: String, value: (String) -> String) throws -> String {
        if let r = text.range(of: statusLinePattern, options: .regularExpression) {
            let indent = lineIndent(of: text, at: r.lowerBound)
            return text.replacingCharacters(in: r, with: "\"statusLine\": " + value(indent))
        }
        // 原本没有这个键：插到第一个 { 之后
        guard let open = text.firstIndex(of: "{") else { throw Failure(description: "settings.json 不是 JSON 对象") }
        let after = text.index(after: open)
        let restIsEmpty = text[after...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
        let indent = "  "
        let insertion = "\n\(indent)\"statusLine\": " + value(indent) + (restIsEmpty ? "\n" : ",")
        return text.replacingCharacters(in: after..<after, with: insertion)
    }

    static func removingStatusLine(in text: String) throws -> String {
        // 先试"前面带逗号"（它不是第一个键），再试"后面带逗号"（它是第一个键，连同前面的换行缩进一起删，否则留一个空行），最后裸删
        for p in [",\\s*" + statusLinePattern, "\\s*" + statusLinePattern + "\\s*,", "\\s*" + statusLinePattern + "\\s*"] {
            if let r = text.range(of: p, options: .regularExpression) {
                return text.replacingCharacters(in: r, with: "")
            }
        }
        return text
    }

    private static func render(_ obj: [String: Any], indent: String) -> String {
        // 手工排版成两空格风格；键按 type / command 优先，其余按名排序
        let order = ["type", "command"]
        let keys = order.filter { obj[$0] != nil } + obj.keys.filter { !order.contains($0) }.sorted()
        let inner = indent + "  "
        let rows = keys.map { "\(inner)\"\($0)\": \(jsonValue(obj[$0]!))" }
        return "{\n" + rows.joined(separator: ",\n") + "\n\(indent)}"
    }

    private static func jsonValue(_ v: Any) -> String {
        if let s = v as? String { return jsonString(s) }
        if let n = v as? NSNumber {
            // Bool 也是 NSNumber，要先分辨，否则会被写成 1 / 0
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return "\(n)"
        }
        return "null"
    }

    /// 手写转义：JSONSerialization 会把 / 写成 \/，路径会变得难看（虽然合法）
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    private static func lineIndent(of text: String, at idx: String.Index) -> String {
        var i = idx
        while i > text.startIndex, text[text.index(before: i)] != "\n" { i = text.index(before: i) }
        return String(text[i..<idx].prefix { $0 == " " || $0 == "\t" })
    }

    private static func atomicWrite(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".settings.json.ld-tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        if let attrs = try? fm.attributesOfItem(atPath: url.path), let perm = attrs[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: perm], ofItemAtPath: tmp.path)
        }
        guard rename(tmp.path, url.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw Failure(description: "写入 \(url.path) 失败：\(String(cString: strerror(errno)))")
        }
    }

    // MARK: - wrapper 二进制

    private static func installWrapperBinary() throws {
        let fm = FileManager.default
        // .app 里随包分发；开发态回落到编译产物
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ld-statusline"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("LdStatusline"),
        ].compactMap { $0 }
        guard let src = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw Failure(description: "找不到 ld-statusline 二进制（应在 .app/Contents/MacOS/）")
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: wrapperURL.path) { try fm.removeItem(at: wrapperURL) }
        try fm.copyItem(at: src, to: wrapperURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
    }
}

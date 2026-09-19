import Foundation

/// ld-statusline —— Claude Code statusline 的透传 wrapper。
///
/// Claude Code 每次刷新状态栏时把一份 JSON 喂给 statusLine.command。本程序做三件事：
///   1. 抽出 rate_limits（五小时 / 七天额度），**原子**写入 ~/.config/live-desktop/rate-limits.json；
///   2. 抽出本会话的 context_window 占用，写入 ~/.config/live-desktop/ctx/<sessionId>.json
///      （每会话一个文件，天然避免多会话并发写冲突；上下文只在会话活跃时变化，活跃时恰好会刷新，数值不会过期）；
///   3. 把同一份 JSON 原样喂给用户原来的 statusline 命令（存于 statusline.json 的 passthrough），转发其输出与退出码。
///
/// 铁律：任何一步失败都不得影响透传 —— 用户的状态栏永远不能因为我们而坏掉。
/// 用法：`ld-statusline`（wrapper 模式）；`ld-statusline --record`（只记录不透传，供手工嵌入现有脚本）。

// 默认 ~/.config/live-desktop；LIVE_DESKTOP_DIR 仅供沙箱测试重定向（Claude Code 调用时不会设置它）
let baseDir: URL = {
    if let d = ProcessInfo.processInfo.environment["LIVE_DESKTOP_DIR"], !d.isEmpty {
        return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/live-desktop", isDirectory: true)
}()
let recordURL = baseDir.appendingPathComponent("rate-limits.json")
let configURL = baseDir.appendingPathComponent("statusline.json")
let recordOnly = CommandLine.arguments.contains("--record")

let input = FileHandle.standardInput.readDataToEndOfFile()

/// 先写临时文件再 rename：读方永远不会读到半截 JSON
func atomicWrite(_ obj: [String: Any], to dst: URL) {
    guard let bytes = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).\(getpid()).tmp")
    guard (try? bytes.write(to: tmp)) != nil else { return }
    if rename(tmp.path, dst.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
}

func recordRateLimits(_ obj: [String: Any]) {
    guard let rl = obj["rate_limits"] as? [String: Any] else { return }
    func window(_ key: String) -> [String: Any]? {
        guard let w = rl[key] as? [String: Any] else { return nil }
        var d: [String: Any] = [:]
        if let p = w["used_percentage"] as? Double { d["usedPercentage"] = p }
        if let r = w["resets_at"] as? Double { d["resetsAt"] = r }
        return d.isEmpty ? nil : d
    }
    var out: [String: Any] = ["version": 1, "recordedAt": Date().timeIntervalSince1970]
    if let f = window("five_hour") { out["fiveHour"] = f }
    if let s = window("seven_day") { out["sevenDay"] = s }
    guard out["fiveHour"] != nil || out["sevenDay"] != nil else { return }
    if let sid = obj["session_id"] as? String { out["sessionId"] = sid }
    if let model = (obj["model"] as? [String: Any])?["id"] as? String { out["model"] = model }
    atomicWrite(out, to: recordURL)
}

func recordContext(_ obj: [String: Any]) {
    guard let sid = obj["session_id"] as? String,
          sid.allSatisfy({ $0.isHexDigit || $0 == "-" }), !sid.isEmpty,   // sid 要进文件名，只认 uuid 形状
          let cw = obj["context_window"] as? [String: Any],
          let pct = cw["used_percentage"] as? Double else { return }
    var out: [String: Any] = ["usedPercentage": pct, "recordedAt": Date().timeIntervalSince1970]
    if let size = cw["context_window_size"] as? Double { out["contextWindowSize"] = size }
    atomicWrite(out, to: baseDir.appendingPathComponent("ctx", isDirectory: true).appendingPathComponent(sid + ".json"))
}

if let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] {
    recordRateLimits(obj)
    recordContext(obj)
}
if recordOnly { exit(0) }

// 透传给用户原来的 statusline 命令；没有配置就安静退出（等同用户原本没配状态栏）
guard let cfgData = try? Data(contentsOf: configURL),
      let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
      let cmd = cfg["passthrough"] as? String, !cmd.isEmpty else { exit(0) }

let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/sh")
child.arguments = ["-c", cmd]
let stdinPipe = Pipe()
child.standardInput = stdinPipe
child.standardOutput = FileHandle.standardOutput
child.standardError = FileHandle.standardError
do { try child.run() } catch { exit(0) }
stdinPipe.fileHandleForWriting.write(input)
try? stdinPipe.fileHandleForWriting.close()
child.waitUntilExit()
exit(child.terminationStatus)

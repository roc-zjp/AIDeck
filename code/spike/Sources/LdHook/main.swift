import Foundation

/// ld-hook —— Claude Code 的 Notification hook 只读监听器（决策 009）。
///
/// Claude Code 在需要你注意时（权限确认框、MCP 表单等）把一份 JSON 从 stdin 喂给这个命令。
/// 本程序只做一件事：如果是我们关心的类型，就把「哪个会话卡在等你」原子写进
/// ~/.config/live-desktop/hooks/<sessionId>.json；其余一律安静退出。
///
/// 铁律（同 ld-statusline）：秒退、退出码恒 0，绝不阻塞 Claude Code。
/// 关心的类型（其余不写文件）：
///   permission_prompt        —— 需要你批准工具，且已等约 6 秒
///   elicitation_dialog       —— MCP 表单在等你
///   elicitation_url_dialog   —— MCP 要你打开一个 URL
/// 不订 idle_prompt（已被桌面的 waiting 覆盖）、auth_success、quota_auto_resume_* 等。

let interesting: Set<String> = ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog"]

// 默认 ~/.config/live-desktop；LIVE_DESKTOP_DIR 仅供沙箱测试重定向（Claude Code 调用时不会设置它）
let baseDir: URL = {
    if let d = ProcessInfo.processInfo.environment["LIVE_DESKTOP_DIR"], !d.isEmpty {
        return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/live-desktop", isDirectory: true)
}()
let hooksDir = baseDir.appendingPathComponent("hooks", isDirectory: true)

func atomicWrite(_ obj: [String: Any], to dst: URL) {
    guard let bytes = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).\(getpid()).tmp")
    guard (try? bytes.write(to: tmp)) != nil else { return }
    if rename(tmp.path, dst.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let type = obj["notification_type"] as? String, interesting.contains(type),
      let sid = obj["session_id"] as? String,
      sid.allSatisfy({ $0.isHexDigit || $0 == "-" }), !sid.isEmpty      // sid 进文件名，只认 uuid 形状
else { exit(0) }

var out: [String: Any] = ["version": 1, "type": type, "at": Date().timeIntervalSince1970]
// permission_prompt 带上要批准的工具名，桌面能说清「等你确认 Bash」
if let data = obj["notification_data"] as? [String: Any], let tool = data["tool_name"] as? String { out["tool"] = tool }
if let server = (obj["notification_data"] as? [String: Any])?["server_name"] as? String { out["server"] = server }

atomicWrite(out, to: hooksDir.appendingPathComponent(sid + ".json"))
exit(0)

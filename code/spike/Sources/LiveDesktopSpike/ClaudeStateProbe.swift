import Foundation

/// Claude 当前所处阶段。顺序即优先级（越靠后越"活跃"）。
enum ClaudePhase: String {
    case idle       // 没有活跃会话
    case waiting    // 已回答完，正在等你输入 —— 桌面最该突出的状态
    case thinking   // 收到输入/工具结果，正在推理
    case running    // 正在执行工具
}

struct SessionState {
    var project: String     // 项目名（从 cwd/slug 提取）
    var branch: String?
    var phase: ClaudePhase
    var tool: String?       // running 时的工具名
    var idleSeconds: Int    // 距上次文件更新的秒数
}

/// 一次真实的工具调用。贾伟斯式界面的"数据流"用它填充，不造假数据。
struct ToolEvent {
    var tool: String
    var project: String
    var agoSeconds: Int
}

struct ClaudeState {
    var phase: ClaudePhase = .idle
    var tool: String?
    var project: String?
    var branch: String?
    var sessions: [SessionState] = []
    var recentTools: [ToolEvent] = []   // 跨会话合并、按时间倒序
    var probeMillis: Double = 0   // 本轮探测耗时，用于评估轮询开销

    var jsonObject: [String: Any] {
        [
            "phase": phase.rawValue,
            "tool": tool as Any,
            "project": project as Any,
            "branch": branch as Any,
            "activeSessions": sessions.count,
            "recentTools": recentTools.map {
                ["tool": $0.tool, "project": $0.project, "ago": $0.agoSeconds]
            },
            "sessions": sessions.map {
                ["project": $0.project, "branch": $0.branch as Any,
                 "phase": $0.phase.rawValue, "tool": $0.tool as Any,
                 "idleSeconds": $0.idleSeconds]
            },
            "probeMillis": probeMillis
        ]
    }
}

/// 零侵入探测：只读 ~/.claude/projects 下的会话 jsonl，不改用户任何配置。
final class ClaudeStateProbe {
    private let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/projects")

    /// 超过这个秒数没有写入，就认为该会话不再活跃（waiting 除外，等你输入可以等很久）
    private let activeWindow: TimeInterval = 90
    private let waitingWindow: TimeInterval = 30 * 60
    private let tailBytes = 96 * 1024

    func probe() -> ClaudeState {
        let t0 = Date()
        var state = ClaudeState()
        let now = Date()

        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return state }

        var candidates: [(URL, Date)] = []
        for dir in dirs {
            // 只看顶层主会话文件，跳过 subagents/workflows 等子目录
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if now.timeIntervalSince(m) < waitingWindow { candidates.append((f, m)) }
            }
        }

        candidates.sort { $0.1 > $1.1 }
        var tools: [ToolEvent] = []
        for (url, mtime) in candidates.prefix(6) {
            let age = now.timeIntervalSince(mtime)
            guard var s = parseTail(url, now: now, tools: &tools) else { continue }
            s.idleSeconds = Int(age)
            // 时间衰减：thinking/running 超过活跃窗口就不可信了，降级
            if s.phase != .waiting && age > activeWindow { continue }
            state.sessions.append(s)
        }

        // 全局态取最活跃的一个：running > thinking > waiting
        let rank: [ClaudePhase: Int] = [.idle: 0, .waiting: 1, .thinking: 2, .running: 3]
        if let top = state.sessions.max(by: { (rank[$0.phase] ?? 0, -$0.idleSeconds) < (rank[$1.phase] ?? 0, -$1.idleSeconds) }) {
            state.phase = top.phase
            state.tool = top.tool
            state.project = top.project
            state.branch = top.branch
        }
        state.recentTools = Array(tools.sorted { $0.agoSeconds < $1.agoSeconds }.prefix(14))
        state.probeMillis = Date().timeIntervalSince(t0) * 1000
        return state
    }

    /// 只读文件尾部，避免大会话（本机实测有 14000+ 行）被整体载入
    private func parseTail(_ url: URL, now: Date, tools: inout [ToolEvent]) -> SessionState? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0 && !lines.isEmpty { lines.removeFirst() }  // 首行可能被截断

        var project: String?
        var branch: String?
        var result: SessionState?
        var collected = 0
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines.reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }

            if project == nil, let cwd = obj["cwd"] as? String {
                project = (cwd as NSString).lastPathComponent
            }
            if branch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }

            let type = obj["type"] as? String ?? ""
            guard type == "assistant" || type == "user" else { continue }
            // 顺路收集真实的工具调用流（含 sidechain，subagent 的活动也是活动）
            if type == "assistant", collected < 14,
               let m = obj["message"] as? [String: Any],
               let blocks = m["content"] as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "tool_use" {
                    guard let name = b["name"] as? String else { continue }
                    var ago = 0
                    if let ts = obj["timestamp"] as? String, let d = iso.date(from: ts) {
                        ago = max(0, Int(now.timeIntervalSince(d)))
                    }
                    tools.append(ToolEvent(tool: name,
                                           project: (project ?? "?"),
                                           agoSeconds: ago))
                    collected += 1
                }
            }
            // 侧链（subagent）事件不代表主会话状态
            if obj["isSidechain"] as? Bool == true { continue }
            guard let msg = obj["message"] as? [String: Any] else { continue }

            let blocks: [[String: Any]]
            if let arr = msg["content"] as? [[String: Any]] { blocks = arr }
            else if msg["content"] is String { blocks = [["type": "text"]] }
            else { continue }

            let kinds = blocks.compactMap { $0["type"] as? String }
            let phase: ClaudePhase
            var tool: String?

            if type == "assistant" {
                if kinds.contains("tool_use") {
                    phase = .running
                    tool = blocks.first(where: { $0["type"] as? String == "tool_use" })?["name"] as? String
                } else if kinds.contains("text") {
                    phase = .waiting   // 说完了，球在你这边
                } else { continue }
            } else {
                // user：既可能是工具结果回灌，也可能是你刚敲的提问，两者都意味着 Claude 要开始想了
                phase = .thinking
            }

            if result == nil {
                result = SessionState(project: project ?? "?", branch: branch,
                                      phase: phase, tool: tool, idleSeconds: 0)
            }
            if collected >= 14, result != nil { break }
        }
        // project 可能在确定 phase 之后才读到，回填一次
        if var r = result, r.project == "?" , let p = project { r.project = p; result = r }
        return result
    }
}

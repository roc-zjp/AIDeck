import XCTest
@testable import AIDeck

/// Claude Code 私有文件格式的 Golden Data：会话注册表 `~/.claude/sessions/<pid>.json` 与会话记录 jsonl。
///
/// 样本按 2026-10-09 本机真实文件的**结构**手写（键名、嵌套、取值类型照抄，内容全部脱敏），不含任何真实会话内容。
/// Claude Code 升级后这里挂了，说明它改了格式——先用真实文件核对结构、更新样本，再改解析，别反过来改测试迁就代码。
final class FormatGoldenTests: XCTestCase {

    // MARK: - jsonl 尾部

    /// 一段典型会话：元数据记录夹在对话里，主线用了 Bash / Read，subagent 侧链用了 Grep，最后 Claude 说完话
    private let transcript = [
        #"{"type":"mode","mode":"default","sessionId":"s1"}"#,
        #"{"type":"user","message":{"role":"user","content":"帮我看下构建"},"isSidechain":false,"gitBranch":"main","cwd":"/Users/dev/proj","timestamp":"2026-10-09T10:00:00.000Z"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"…"}]},"isSidechain":false,"gitBranch":"main","cwd":"/Users/dev/proj","timestamp":"2026-10-09T10:00:00.500Z"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]},"isSidechain":false,"gitBranch":"main","cwd":"/Users/dev/proj","timestamp":"2026-10-09T10:00:01.000Z"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"isSidechain":false,"gitBranch":"main","cwd":"/Users/dev/proj","timestamp":"2026-10-09T10:00:02.000Z"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Grep","input":{}}]},"isSidechain":true,"gitBranch":"main","cwd":"/Users/dev/proj","timestamp":"2026-10-09T10:00:03.000Z"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Read","input":{}}]},"isSidechain":false,"gitBranch":"main","cwd":"/Users/dev/proj","timestamp":"2026-10-09T10:00:05.000Z"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"…"}]},"isSidechain":false,"gitBranch":"main","cwd":"/Users/dev/proj","timestamp":"2026-10-09T10:00:06.000Z"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"构建通过"}]},"isSidechain":false,"gitBranch":"main","cwd":"/Users/dev/proj","timestamp":"2026-10-09T10:00:08.000Z"}"#,
        #"{"type":"attachment","attachment":{"type":"x"},"timestamp":"2026-10-09T10:00:08.100Z"}"#,
        #"{"type":"system","subtype":"turn_duration","timestamp":"2026-10-09T10:00:08.200Z"}"#,
    ]

    private func parse(_ lines: [String], truncated: Bool = false) -> ClaudeStateProbe.ParsedTail {
        ClaudeStateProbe.parseTail(lines.joined(separator: "\n") + "\n", truncated: truncated, project: "proj", now: Date())
    }

    private func isAssistantText(_ l: ClaudeStateProbe.Tail.Last?) -> Bool { if case .assistantText? = l { return true }; return false }
    private func isUser(_ l: ClaudeStateProbe.Tail.Last?) -> Bool { if case .user? = l { return true }; return false }
    private func toolName(_ l: ClaudeStateProbe.Tail.Last?) -> String? { if case .toolUse(let n)? = l { return n }; return nil }

    func testGoldenTranscriptLastBranchCwdAndTools() {
        let p = parse(transcript)
        XCTAssertTrue(isAssistantText(p.tail.last), "元数据记录之前的最后一条主线记录是 Claude 说完话")
        XCTAssertEqual(p.tail.branch, "main")
        XCTAssertEqual(p.tail.cwd, "/Users/dev/proj")
        XCTAssertEqual(p.tools.map(\.tool), ["Read", "Grep", "Bash"], "工具流按时间倒序，含 subagent 侧链")
        XCTAssertEqual(p.tools.first?.date, ISO8601DateFormatter.withFraction.date(from: "2026-10-09T10:00:05.000Z"))
        XCTAssertFalse(p.formatDrift)
    }

    func testThinkingOnlyRecordIsSkippedWhenFindingLast() {
        // 用户刚发出、Claude 只落了 thinking 块：最后一条按「用户说的」算（Claude 正在想）
        let p = parse(Array(transcript[1...2]))
        XCTAssertTrue(isUser(p.tail.last))
    }

    func testSidechainDoesNotBecomeLast() {
        // 主线停在工具调用 Bash，之后只有 subagent 侧链在动：最后一条仍是主线的 Bash
        let p = parse(Array(transcript[0...3]) + [transcript[5]])
        XCTAssertEqual(toolName(p.tail.last), "Bash")
        XCTAssertEqual(p.tools.map(\.tool), ["Grep", "Bash"])
    }

    func testTruncatedHeadLineIsDropped() {
        // 从文件中间读起时首行可能是半截 JSON，必须丢掉而不是当成一条记录
        let p = parse([#"t":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Zzz"}]}}"#] + transcript, truncated: true)
        XCTAssertFalse(p.tools.contains { $0.tool == "Zzz" })
        XCTAssertTrue(isAssistantText(p.tail.last))
    }

    func testMetadataOnlyTranscriptIsNotDrift() {
        // 还没开口的会话：只有元数据，没有最后一条，但这不是格式变化
        let p = parse([transcript[0], transcript[9]])
        XCTAssertNil(p.tail.last)
        XCTAssertFalse(p.formatDrift)
    }

    // MARK: - jsonl 格式漂移

    func testContentShapeChangeIsDrift() {
        // 假想升级：message.content 从数组 / 字符串改成对象
        let lines = [
            #"{"type":"user","message":{"role":"user","content":{"text":"hi"}}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":{"text":"done"}}}"#,
        ]
        let p = parse(lines)
        XCTAssertNil(p.tail.last)
        XCTAssertTrue(p.formatDrift)
    }

    func testTypeRenameIsDrift() {
        // 假想升级：type 从 assistant 改名，但 message.role 还在
        let p = parse([#"{"type":"agent_message","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#])
        XCTAssertNil(p.tail.last)
        XCTAssertTrue(p.formatDrift)
    }

    func testUnreadableRecordBehindReadableLastIsNotDrift() {
        // 最新一条读得懂，更早有一条读不懂：阶段判定不受影响，不报警
        let p = parse([#"{"type":"user","message":{"role":"user","content":{"x":1}}}"#, transcript[8]])
        XCTAssertTrue(isAssistantText(p.tail.last))
        XCTAssertFalse(p.formatDrift)
    }

    // MARK: - 会话注册表

    /// 本机真实记录的键集合（2026-10-09，取值脱敏）
    private func registry(_ patch: [String: Any?] = [:]) -> Data {
        var o: [String: Any] = [
            "pid": 4242, "sessionId": "11111111-2222-3333-4444-555555555555", "cwd": "/Users/dev/proj",
            "startedAt": 1_791_550_000_000, "procStart": "x", "version": "2.9.0", "peerProtocol": 1,
            "peerFeatures": [], "kind": "interactive", "entrypoint": "cli", "pidDomain": "x",
            "messagingSocketPath": "/tmp/x.sock", "name": "proj-1", "nameSource": "derived", "nameSince": 0,
            "updatedAt": 1_791_550_000_000, "status": "busy", "statusUpdatedAt": 1_791_550_001_500,
        ]
        for (k, v) in patch { o[k] = v }
        return try! JSONSerialization.data(withJSONObject: o)
    }

    func testGoldenRegistryRecordDecodes() {
        guard case .ok(let r) = ClaudeStateProbe.decodeRegistry(registry()) else { return XCTFail("现行格式应能解码") }
        XCTAssertEqual(r.pid, 4242)
        XCTAssertEqual(r.sessionId, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(r.cwd, "/Users/dev/proj")
        XCTAssertEqual(r.status, "busy")
        XCTAssertEqual(r.statusUpdatedAt?.timeIntervalSince1970, 1_791_550_001.5, "statusUpdatedAt 是毫秒 epoch")
        XCTAssertEqual(r.nameSource, "derived")
        XCTAssertEqual(r.kind, "interactive")
        XCTAssertEqual(r.version, "2.9.0")
    }

    func testRegistryKindDefaultsToInteractive() {
        guard case .ok(let r) = ClaudeStateProbe.decodeRegistry(registry(["kind": nil])) else { return XCTFail() }
        XCTAssertEqual(r.kind, "interactive")
    }

    func testRegistryMissingStatusIsDrift() {
        guard case .drift(let pid, let v) = ClaudeStateProbe.decodeRegistry(registry(["status": nil])) else { return XCTFail() }
        XCTAssertEqual(pid, 4242, "pid 读得出来就带上，宿主判活后再决定报不报")
        XCTAssertEqual(v, "2.9.0")
    }

    func testRegistryShellStatusIsKnown() {
        // 2026-10-09 在 Claude Code 2.1.295 实测：说完一轮、后台 Bash 还在跑时 status=shell
        guard case .ok(let r) = ClaudeStateProbe.decodeRegistry(registry(["status": "shell"])) else { return XCTFail() }
        XCTAssertTrue(r.statusKnown)
    }

    func testRegistryUnknownStatusKeepsSessionButIsFlagged() {
        // 新取值：会话不能丢（丢掉比显示得不够准更糟），但要能被识别出来报异常
        guard case .ok(let r) = ClaudeStateProbe.decodeRegistry(registry(["status": "compacting"])) else { return XCTFail() }
        XCTAssertFalse(r.statusKnown)
        XCTAssertEqual(ClaudeStateProbe.unknownStatusText(r.status, version: r.version),
                       "Claude Code 2.9.0 出现未识别的会话状态「compacting」，相关会话阶段可能不准")
    }

    func testRegistryNonStringStatusIsDrift() {
        guard case .drift = ClaudeStateProbe.decodeRegistry(registry(["status": 1])) else { return XCTFail() }
    }

    func testRegistryRenamedKeyIsDrift() {
        guard case .drift(let pid, _) = ClaudeStateProbe.decodeRegistry(registry(["sessionId": nil, "session_id": "x"])) else { return XCTFail() }
        XCTAssertEqual(pid, 4242)
    }

    func testRegistryNonJSONIsUnreadableNotDrift() {
        guard case .unreadable = ClaudeStateProbe.decodeRegistry(Data(#"{"pid": 42, "sess"#.utf8)) else { return XCTFail() }
    }

    func testIssueTextNamesVersion() {
        XCTAssertEqual(ClaudeStateProbe.issueText("会话注册表", version: "2.9.0"), "无法识别 Claude Code 2.9.0 的会话注册表格式，状态可能不准")
        XCTAssertEqual(ClaudeStateProbe.issueText("会话记录", version: nil), "无法识别 Claude Code 的会话记录格式，状态可能不准")
    }
}

private extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}

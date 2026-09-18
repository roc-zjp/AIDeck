import XCTest
@testable import LiveDesktopSpike

/// 状态判定规则的真值表测试。
///
/// 这些规则是整个产品的语义地基——「哪个会话在等你」判错，三层感知全都跟着错，
/// 而它们此前只能靠真机观察验证。规则出处：`docs/decisions/007-session-registry.md`（阶段与停滞）、
/// `docs/decisions/009-fine-state-via-hooks.md`（确认框的清除推断）。
final class SessionLogicTests: XCTestCase {

    // MARK: - 决策 007 的真值表：注册表 status × jsonl 最后一条 → 阶段

    func testBusyWithToolUseIsRunning() {
        let r = ClaudeStateProbe.resolvePhase(busy: true, last: .toolUse("Bash"), kind: "interactive")
        XCTAssertEqual(r?.phase, .running)
        XCTAssertEqual(r?.tool, "Bash", "running 必须带出工具名，桌面要显示它")
    }

    func testBusyWithAssistantTextIsThinking() {
        // busy 但最后一条是文本：Claude 正在往下想（或正在写），不是在跑工具
        XCTAssertEqual(ClaudeStateProbe.resolvePhase(busy: true, last: .assistantText, kind: "interactive")?.phase,
                       .thinking)
    }

    func testBusyWithUserIsThinking() {
        XCTAssertEqual(ClaudeStateProbe.resolvePhase(busy: true, last: .user, kind: "interactive")?.phase, .thinking)
    }

    func testBusyWithNoRecordIsThinking() {
        // 注册表说在忙但 jsonl 还没落任何一条：仍按思考中算，不能当空会话丢掉
        XCTAssertEqual(ClaudeStateProbe.resolvePhase(busy: true, last: nil, kind: "interactive")?.phase, .thinking)
    }

    func testIdleAfterAssistantTextIsWaiting() {
        // 最典型的一条：Claude 说完了，球在你这边
        XCTAssertEqual(ClaudeStateProbe.resolvePhase(busy: false, last: .assistantText, kind: "interactive")?.phase,
                       .waiting)
    }

    func testIdleAfterToolUseIsWaiting() {
        // 工具中途被你打断后停下，球同样在你这边——不能因为最后一条是 tool_use 就报 running
        let r = ClaudeStateProbe.resolvePhase(busy: false, last: .toolUse("Edit"), kind: "interactive")
        XCTAssertEqual(r?.phase, .waiting)
        XCTAssertNil(r?.tool, "等你输入不该再挂着工具名")
    }

    func testIdleAfterUserIsThinking() {
        // 你刚发出去、注册表还没翻成 busy 的那一瞬：算思考中，不能显示成"等你输入"
        XCTAssertEqual(ClaudeStateProbe.resolvePhase(busy: false, last: .user, kind: "interactive")?.phase, .thinking)
    }

    func testEmptySessionIsNotListed() {
        XCTAssertNil(ClaudeStateProbe.resolvePhase(busy: false, last: nil, kind: "interactive"),
                     "还没开口的空会话不该出现在列表里")
    }

    func testBackgroundSessionNeverWaits() {
        // 后台任务收尾不是在等你（决策 007）：bg + waiting 直接不列
        XCTAssertNil(ClaudeStateProbe.resolvePhase(busy: false, last: .assistantText, kind: "bg"))
        // 但 bg 在跑工具时照常显示
        XCTAssertEqual(ClaudeStateProbe.resolvePhase(busy: true, last: .toolUse("Bash"), kind: "bg")?.phase, .running)
    }

    // MARK: - 停滞判定（决策 007 边界 2）

    func testThinkingStallsAfterTenMinutes() {
        XCTAssertFalse(ClaudeStateProbe.isStalled(busy: true, parked: false, phase: .thinking, idleSeconds: 599))
        XCTAssertTrue(ClaudeStateProbe.isStalled(busy: true, parked: false, phase: .thinking, idleSeconds: 600))
    }

    func testRunningStallsOnlyAfterThirtyMinutes() {
        // 工具（构建、测试）可以跑很久，阈值必须比思考中宽
        XCTAssertFalse(ClaudeStateProbe.isStalled(busy: true, parked: false, phase: .running, idleSeconds: 1799))
        XCTAssertTrue(ClaudeStateProbe.isStalled(busy: true, parked: false, phase: .running, idleSeconds: 1800))
    }

    func testParkedSessionNeverStalls() {
        // 转后台的本体沉默是正常的，活儿由 bg 会话代表（实测那条 busy 挂 8.6 小时就是这种）
        XCTAssertFalse(ClaudeStateProbe.isStalled(busy: true, parked: true, phase: .thinking, idleSeconds: 30_000))
    }

    func testIdleSessionNeverStalls() {
        XCTAssertFalse(ClaudeStateProbe.isStalled(busy: false, parked: false, phase: .waiting, idleSeconds: 30_000))
    }

    // MARK: - 确认框的清除推断（决策 009：没有「框关闭」事件，只能推断）

    func testAttentionClearedWhenTranscriptAdvances() {
        let at = Date()
        // 用户点了允许 → 工具结果落盘 → jsonl mtime 前进到 at 之后
        XCTAssertTrue(ClaudeStateProbe.attentionHandled(
            busy: true, jsonlMtime: at.addingTimeInterval(3), at: at, now: at.addingTimeInterval(4)))
    }

    func testAttentionHeldWhileTranscriptQuiet() {
        let at = Date()
        // 框还开着：Claude 停着等你，jsonl 不再写入
        XCTAssertFalse(ClaudeStateProbe.attentionHandled(
            busy: true, jsonlMtime: at.addingTimeInterval(-10), at: at, now: at.addingTimeInterval(60)))
    }

    func testAttentionClearedWhenNoLongerBusy() {
        let at = Date()
        XCTAssertTrue(ClaudeStateProbe.attentionHandled(
            busy: false, jsonlMtime: at.addingTimeInterval(-10), at: at, now: at.addingTimeInterval(60)))
    }

    func testAttentionExpiresAfterThirtyMinutes() {
        let at = Date()
        // 兜底：漏事件 / crash 残留不能永远卡着一个假的「等你确认」
        XCTAssertFalse(ClaudeStateProbe.attentionHandled(
            busy: true, jsonlMtime: at.addingTimeInterval(-10), at: at, now: at.addingTimeInterval(1799)))
        XCTAssertTrue(ClaudeStateProbe.attentionHandled(
            busy: true, jsonlMtime: at.addingTimeInterval(-10), at: at, now: at.addingTimeInterval(1801)))
    }

    // MARK: - 全局态选取（反应堆显示哪一个）

    func testGlobalPhasePrefersMostActive() {
        let sessions = [session("a", .waiting, idle: 10), session("b", .running, idle: 3), session("c", .thinking, idle: 5)]
        XCTAssertEqual(ClaudeStateProbe.topSession(sessions)?.project, "b", "running 优先级最高")
    }

    func testGlobalPhaseIgnoresStalledAndParked() {
        // 僵尸会话不能把反应堆霸占成"推理中"
        var stalled = session("zombie", .thinking, idle: 9999); stalled.stalled = true
        var parked = session("parked", .running, idle: 10); parked.parked = true
        let sessions = [stalled, parked, session("live", .waiting, idle: 20)]
        XCTAssertEqual(ClaudeStateProbe.topSession(sessions)?.project, "live")
    }

    func testGlobalPhaseTieBreaksOnRecency() {
        // 同为 running 时取最近有动静的那个
        let sessions = [session("old", .running, idle: 300), session("fresh", .running, idle: 2)]
        XCTAssertEqual(ClaudeStateProbe.topSession(sessions)?.project, "fresh")
    }

    func testGlobalPhaseNilWhenAllStalled() {
        var a = session("a", .running, idle: 9999); a.stalled = true
        XCTAssertNil(ClaudeStateProbe.topSession([a]), "全是僵尸时没有全局态，应回落待机")
    }

    // MARK: -

    private func session(_ project: String, _ phase: ClaudePhase, idle: Int) -> SessionState {
        SessionState(id: project, pid: 1, project: project, name: nil, nameIsUserSet: false,
                     kind: "interactive", branch: nil, phase: phase, tool: nil, idleSeconds: idle)
    }
}

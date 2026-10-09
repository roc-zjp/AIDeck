import XCTest
@testable import AIDeck

/// QuotaInstaller 对用户 settings.json 的「外科手术式」改写——全项目唯一写用户配置的代码。
/// 只测纯文本函数，**不碰真实文件**。2026-08-28 曾因正则失配往用户文件里插出第二个 statusLine 键（issues.md）。
final class QuotaInstallerTests: XCTestCase {

    private let ours: [String: Any] = ["type": "command", "command": "/Users/dev/.config/live-desktop/ld-statusline"]

    private func json(_ text: String) -> NSDictionary? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? NSDictionary
    }

    private func statusLineCount(_ text: String) -> Int {
        text.components(separatedBy: "\"statusLine\"").count - 1
    }

    /// 接入（换成我们的）→ 恢复（换回原值）：结果在 JSON 语义上等于原文件，且始终只有一个 statusLine 键
    private func assertRoundTrip(_ original: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try QuotaInstaller.currentStatusLine(in: original)
        let installed = try QuotaInstaller.replacingStatusLine(in: original, with: ours)
        XCTAssertEqual(statusLineCount(installed), 1, "接入后只能有一个 statusLine", file: file, line: line)
        XCTAssertNotNil(json(installed), "接入后必须仍是合法 JSON", file: file, line: line)
        XCTAssertEqual((try QuotaInstaller.currentStatusLine(in: installed) as? [String: Any])?["command"] as? String,
                       ours["command"] as? String, file: file, line: line)

        let restored: String
        if let o = before as? [String: Any] { restored = try QuotaInstaller.replacingStatusLine(in: installed, with: o) }
        else if let s = before as? String { restored = try QuotaInstaller.replacingStatusLine(in: installed, withString: s) }
        else { restored = try QuotaInstaller.removingStatusLine(in: installed) }
        XCTAssertEqual(json(restored), json(original), "恢复后应与原文件语义一致", file: file, line: line)
        XCTAssertLessThanOrEqual(statusLineCount(restored), 1, file: file, line: line)
    }

    func testRoundTripObjectForm() throws {
        try assertRoundTrip("""
        {
          "model": "opus",
          "statusLine": {
            "type": "command",
            "command": "~/.claude/statusline.sh",
            "padding": 0,
            "refreshInterval": 1000,
            "hideVimModeIndicator": false
          },
          "theme": "dark"
        }
        """)
    }

    func testRoundTripStringForm() throws {
        try assertRoundTrip(#"{"statusLine": "~/.claude/statusline.sh", "theme": "dark"}"#)
    }

    func testRoundTripWhenKeyAbsent() throws {
        try assertRoundTrip("{\n  \"theme\": \"dark\"\n}\n")
        try assertRoundTrip("{}")
    }

    func testRoundTripWhenStatusLineIsFirstOrLastKey() throws {
        try assertRoundTrip(#"{"statusLine": {"type": "command", "command": "a"}, "theme": "dark"}"#)
        try assertRoundTrip(#"{"theme": "dark", "statusLine": {"type": "command", "command": "a"}}"#)
        try assertRoundTrip(#"{"statusLine": {"type": "command", "command": "a"}}"#)
    }

    func testPreservesOptionsAndBooleans() throws {
        let t = #"{"statusLine": {"type": "command", "command": "a", "padding": 2, "hideVimModeIndicator": true}}"#
        let installed = try QuotaInstaller.replacingStatusLine(in: t, with: (try QuotaInstaller.currentStatusLine(in: t) as! [String: Any]).merging(ours) { $1 })
        let sl = (json(installed)?["statusLine"] as? [String: Any])
        XCTAssertEqual(sl?["padding"] as? Int, 2)
        XCTAssertEqual(sl?["hideVimModeIndicator"] as? Bool, true, "Bool 不能被写成 1 / 0")
    }

    func testRefusesCommandWithBraces() {
        // jq 过滤器常见：正则认不出这种写法时必须拒绝，而不是当成「没配」再插一个
        let t = #"{"statusLine": {"type": "command", "command": "jq '{a: .b}'"}}"#
        XCTAssertThrowsError(try QuotaInstaller.currentStatusLine(in: t))
    }

    func testRefusesNestedObjectValue() {
        XCTAssertThrowsError(try QuotaInstaller.currentStatusLine(in: #"{"statusLine": {"type": "command", "command": "a", "env": {"X": "1"}}}"#))
    }

    func testRefusesInvalidJSON() {
        // 注意：Foundation 的 JSONSerialization 接受尾逗号（2026-10-09 实测），所以这里不拿尾逗号当非法样本
        XCTAssertThrowsError(try QuotaInstaller.currentStatusLine(in: #"{"statusLine": "a""#))
        XCTAssertThrowsError(try QuotaInstaller.currentStatusLine(in: "// comment\n{}"))
    }

    func testIgnoresLookalikeInsideAnotherString() throws {
        // 另一个字符串值里出现转义过的 "statusLine": {...} 字样，不能被当成真键
        let t = #"{"note": "\"statusLine\": {\"command\": \"decoy\"}", "statusLine": {"type": "command", "command": "real"}}"#
        let v = try QuotaInstaller.currentStatusLine(in: t) as? [String: Any]
        XCTAssertEqual(v?["command"] as? String, "real")
        try assertRoundTrip(t)
    }

    func testEscapesSpecialCharactersInCommand() throws {
        let cmd = "/path with \"quotes\" \\ and\ttab"
        let out = try QuotaInstaller.replacingStatusLine(in: "{}", with: ["type": "command", "command": cmd])
        XCTAssertEqual((json(out)?["statusLine"] as? [String: Any])?["command"] as? String, cmd)
    }
}

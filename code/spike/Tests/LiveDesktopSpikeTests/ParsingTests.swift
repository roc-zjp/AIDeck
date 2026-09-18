import XCTest
@testable import LiveDesktopSpike

/// 两组解析规则的边界。都是纯函数——**不碰 UserDefaults**，
/// 否则测试会写进开发机真实的偏好域（Prefs 的存取器有意不在这里测）。
final class ParsingTests: XCTestCase {

    // MARK: - Claude Code 的项目目录名规则（transcriptURL 靠它猜路径，猜错才全目录搜）

    func testSlugReplacesNonAlphanumerics() {
        XCTAssertEqual(ClaudeStateProbe.slug("/Users/a/b-c"), "-Users-a-b-c")
        XCTAssertEqual(ClaudeStateProbe.slug("/tmp/my project"), "-tmp-my-project")
        XCTAssertEqual(ClaudeStateProbe.slug("/a/b.c/d_e"), "-a-b-c-d-e")
    }

    func testSlugTreatsNonASCIIAsSeparator() {
        // 中文路径：非 ASCII 字符一律换成 -，与 Claude Code 的规则一致
        XCTAssertEqual(ClaudeStateProbe.slug("/项目/x"), "----x")
    }

    // MARK: - ./ld skin <id> <值> 的值解析

    func testParseSkinValueBooleans() {
        for s in ["on", "true", "yes", "ON", "True"] {
            XCTAssertEqual(Prefs.parseSkinValue(s) as? Bool, true, "\(s) 应解析为真")
        }
        for s in ["off", "false", "no", "OFF"] {
            XCTAssertEqual(Prefs.parseSkinValue(s) as? Bool, false, "\(s) 应解析为假")
        }
    }

    func testParseSkinValueNumbers() {
        XCTAssertEqual(Prefs.parseSkinValue("12") as? Double, 12)
        XCTAssertEqual(Prefs.parseSkinValue("0.5") as? Double, 0.5)
        XCTAssertEqual(Prefs.parseSkinValue("-3") as? Double, -3)
    }

    func testParseSkinValueFallsBackToString() {
        // choice 类型的 id 原样保留
        XCTAssertEqual(Prefs.parseSkinValue("random") as? String, "random")
        XCTAssertEqual(Prefs.parseSkinValue("medium") as? String, "medium")
    }

    // MARK: - 偏好的宽容数值解析（runtime 存数字，手工 defaults write 进来的是字符串）

    func testNumAcceptsBothNumberAndString() {
        XCTAssertEqual(Prefs.num(42 as NSNumber), 42)
        XCTAssertEqual(Prefs.num("42"), 42)
        XCTAssertEqual(Prefs.num("-17.5"), -17.5)
        XCTAssertNil(Prefs.num("abc"))
        XCTAssertNil(Prefs.num([1, 2]))
    }
}

import XCTest
@testable import AIDeck

/// `./ld` 写进命令队列的每一行 → ControlCommand（纯解析，不执行、不碰偏好）。
/// 与 `ld` 脚本里 send 的格式一一对应，脚本改了这里要跟着改
final class ControlCommandTests: XCTestCase {
    private func p(_ s: String) -> ControlCommand? { ControlCommand.parse(s) }

    func testHudSubcommands() {
        XCTAssertEqual(p("hud on"), .hud(.visible(true)))
        XCTAssertEqual(p("hud off"), .hud(.visible(false)))
        XCTAssertEqual(p("hud edit"), .hud(.edit))
        XCTAssertEqual(p("hud through"), .hud(.clickThrough(true)))
        XCTAssertEqual(p("hud drag"), .hud(.clickThrough(false)))
        XCTAssertEqual(p("hud float"), .hud(.float(true)))
        XCTAssertEqual(p("hud desktop"), .hud(.float(false)))
        XCTAssertEqual(p("hud auto on"), .hud(.autoFloat(true)))
        XCTAssertEqual(p("hud auto off"), .hud(.autoFloat(false)))
        XCTAssertNil(p("hud auto"), "缺 on/off 不该被当成关")
        XCTAssertEqual(p("hud tl"), .hud(.anchor("tl")))
        XCTAssertEqual(p("hud"), .hud(.anchor("br")), "不带参数沿用旧行为：吸附右下")
    }

    func testSimpleCommands() {
        XCTAssertEqual(p("celebrate"), .celebrate)
        XCTAssertEqual(p("next"), .nextSkin)
        XCTAssertEqual(p("pause"), .togglePause)
        XCTAssertEqual(p("settings"), .settings)
    }

    func testWidgetAndReaction() {
        XCTAssertEqual(p("widget sessions tl"), .widget(id: "sessions", slot: "tl"))
        XCTAssertNil(p("widget sessions"))
        XCTAssertEqual(p("fx toolPulse on"), .reaction(id: "toolPulse", on: true))
        XCTAssertEqual(p("fx toolPulse off"), .reaction(id: "toolPulse", on: false))
    }

    func testModelNameMayContainSpaces() {
        XCTAssertEqual(p("model station"), .model("station"))
        XCTAssertEqual(p("model user/My Dancer.fbx"), .model("user/My Dancer.fbx"))
        XCTAssertNil(p("model"))
    }

    func testSkinValuesKeepTheirTypes() {
        XCTAssertEqual(p("skin gravity on"), .skinSet(id: "gravity", value: .bool(true)))
        XCTAssertEqual(p("skin maxBalls 12"), .skinSet(id: "maxBalls", value: .number(12)))
        XCTAssertEqual(p("skin camera side"), .skinSet(id: "camera", value: .text("side")))
        XCTAssertEqual(p("skin model user/a b.glb"), .skinSet(id: "model", value: .text("user/a b.glb")))
        XCTAssertEqual(p("skin reset"), .skinReset)
        XCTAssertNil(p("skin gravity"))
    }

    func testSkinValueBridgesToPlistTypes() {
        // 执行方把 .any 写进 UserDefaults：必须是 Bool / Double / String，不能是枚举本身（会让 UserDefaults 崩）
        XCTAssertTrue(ControlCommand.SkinValue.bool(true).any is Bool)
        XCTAssertTrue(ControlCommand.SkinValue.number(3).any is Double)
        XCTAssertTrue(ControlCommand.SkinValue.text("x").any is String)
    }

    func testUnknownIsNil() {
        XCTAssertNil(p("explode"))
        XCTAssertNil(p(""))
    }
}

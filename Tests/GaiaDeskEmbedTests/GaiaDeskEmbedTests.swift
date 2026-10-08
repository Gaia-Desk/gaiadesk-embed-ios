import UIKit
import XCTest

@testable import GaiaDeskEmbed

final class GaiaDeskEmbedTests: XCTestCase {
    let token = "gdemb_" + String(repeating: "0123456789abcdef", count: 4)

    func testConfigJSONSaysConsentAndAppCapture() throws {
        let c = GaiaDeskEmbed.Configuration(embedToken: token, company: "Acme", server: URL(string: "http://127.0.0.1:9000"), guided: true, maskedRects: [CGRect(x: 1, y: 2, width: 3, height: 4)])
        let json = try GaiaDeskEmbed.configJSON(c, consentGranted: true)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(o["consent_granted"] as? Bool, true)
        XCTAssertEqual(o["capture"] as? String, "app", "an iOS app shares only itself")
        XCTAssertEqual(o["guided"] as? Bool, true)
        XCTAssertEqual((o["masks"] as? [[String: Double]])?.first?["w"], 3)
        XCTAssertNil(o["window_id"])
    }

    func testEventsParse() {
        XCTAssertEqual(GaiaDeskEmbed.parse(#"{"type":"code","code":"123456789","session_id":"ss_1","mode":"cobrowse"}"#), .code("123456789", sessionId: "ss_1", mode: "cobrowse"))
        XCTAssertEqual(GaiaDeskEmbed.parse(#"{"type":"action","action":"click","applied":false,"reason":"hint_shown"}"#), .action("click", applied: false, reason: "hint_shown"))
        XCTAssertEqual(GaiaDeskEmbed.parse(#"{"type":"ended","reason":"stopped"}"#), .ended(reason: "stopped"))
        XCTAssertNil(GaiaDeskEmbed.parse(#"{"type":"future"}"#))
    }

    func testConsentWording() {
        let (t, m) = GaiaDeskEmbed.consentText(company: "Acme", guided: false)
        XCTAssertEqual(t, "Share this app's screen with Acme support?")
        XCTAssertTrue(m.contains("Nothing outside this app"))
        XCTAssertTrue(GaiaDeskEmbed.consentText(company: "Acme", guided: true).message.contains("pause"))
    }

    func testFramesFitTheLongestSide() {
        XCTAssertTrue(FrameSize.fit(CGSize(width: 1170, height: 2532)) == (590, 1280))
        XCTAssertTrue(FrameSize.fit(CGSize(width: 640, height: 401)) == (640, 400), "even, never upscaled")
    }

    /// The real library: refusals happen before anything is shown or sent.
    @MainActor
    func testTheLibraryRefusesWithoutConsent() {
        XCTAssertThrowsError(try GaiaDeskEmbed.start(.init(embedToken: token, company: "Acme"), consentGranted: false) { _ in }) { e in
            XCTAssertEqual((e as? GaiaDeskEmbedError)?.code, "consent_required")
        }
        XCTAssertThrowsError(try GaiaDeskEmbed.start(.init(embedToken: "gdk_live_secret", company: "Acme"), consentGranted: true) { _ in }) { e in
            XCTAssertEqual((e as? GaiaDeskEmbedError)?.code, "bad_token")
        }
        XCTAssertTrue(GaiaDeskEmbed.buildInfo.contains("\"os\":\"ios\""), GaiaDeskEmbed.buildInfo)
        XCTAssertTrue(GaiaDeskEmbed.buildInfo.contains("\"test_source\":false"))
    }

    // MARK: guided delivery through public UIKit API

    final class Target: NSObject {
        var taps = 0
        @objc func tap() { taps += 1 }
    }

    @MainActor
    func testAClickPressesAUIKitButtonAndAScrollMovesAScrollView() throws {
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        w.rootViewController = root
        w.isHidden = false
        let target = Target()
        let b = UIButton(type: .system)
        b.frame = CGRect(x: 20, y: 100, width: 200, height: 44)
        b.addTarget(target, action: #selector(Target.tap), for: .touchUpInside)
        root.view.addSubview(b)
        let s = UISwitch(frame: CGRect(x: 20, y: 200, width: 60, height: 40))
        root.view.addSubview(s)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 300, width: 390, height: 300))
        scroll.contentSize = CGSize(width: 390, height: 2000)
        root.view.addSubview(scroll)

        XCTAssertTrue(Guided.activate(at: CGPoint(x: 100, y: 120), in: w))
        XCTAssertEqual(target.taps, 1)
        XCTAssertTrue(Guided.activate(at: CGPoint(x: 40, y: 215), in: w))
        XCTAssertTrue(s.isOn, "the switch toggled")
        XCTAssertFalse(Guided.activate(at: CGPoint(x: 300, y: 20), in: w), "nothing to press: the customer gets a hint instead")
        XCTAssertTrue(Guided.scroll(at: CGPoint(x: 100, y: 400), in: w, dx: 0, dy: 5000))
        XCTAssertFalse(Guided.scroll(at: CGPoint(x: 300, y: 20), in: w, dx: 0, dy: 10))
        w.isHidden = true
    }

    @MainActor
    func testTypingGoesToTheFirstResponder() throws {
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        w.rootViewController = root
        w.makeKeyAndVisible()
        let f = UITextField(frame: CGRect(x: 20, y: 100, width: 300, height: 40))
        root.view.addSubview(f)
        XCTAssertTrue(Guided.activate(at: CGPoint(x: 50, y: 120), in: w), "a click focuses the field")
        guard f.isFirstResponder else { throw XCTSkip("no key window in this test host") }
        (Guided.firstResponder() as? UIKeyInput)?.insertText("hi")
        XCTAssertEqual(f.text, "hi")
        XCTAssertNil(Guided.key("Backspace"))
        XCTAssertEqual(f.text, "h")
        XCTAssertEqual(Guided.key("F4"), "unsupported")
        w.isHidden = true
    }

    @MainActor
    func testTheIndicatorIsCoveredByAnyWindowAboveIt() {
        let ind = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        ind.windowLevel = Indicator.level
        let pill = CGRect(x: 100, y: 50, width: 190, height: 36)
        let below = UIWindow(frame: ind.frame)
        below.windowLevel = .normal
        XCTAssertTrue(Indicator.uncovered(pill, in: ind, among: [ind, below]))
        let above = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        above.windowLevel = UIWindow.Level(rawValue: Indicator.level.rawValue + 1)
        above.isHidden = false
        XCTAssertFalse(Indicator.uncovered(pill, in: ind, among: [ind, below, above]), "a window over the pill hides it: no frames")
        above.isHidden = true
        XCTAssertTrue(Indicator.uncovered(pill, in: ind, among: [ind, below, above]))
    }
}

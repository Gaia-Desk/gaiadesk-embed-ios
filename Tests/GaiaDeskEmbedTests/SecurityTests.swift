// The security review's fixes, each pinned by a test that fails without it.
// Most need a real app's window scene: they run hosted (the Examples
// project's GaiaDeskEmbedTests scheme, or scripts/build-sim.sh --test) and
// skip in the package's hostless run.

import PhotosUI
import UniformTypeIdentifiers
import UIKit
import XCTest

@testable import GaiaDeskEmbed

final class SecurityTests: XCTestCase {
    let token = "gdemb_" + String(repeating: "0123456789abcdef", count: 4)

    @MainActor
    func scene() throws -> UIWindowScene {
        guard let s = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("needs a host app (the Examples project's GaiaDeskEmbedTests scheme)")
        }
        return s
    }

    @MainActor
    func window() throws -> UIWindow {
        let w = UIWindow(windowScene: try scene())
        w.frame = w.windowScene!.screen.bounds
        w.rootViewController = UIViewController()
        w.isHidden = false
        return w
    }

    /// A session against a server that is not there: the handle is live, no
    /// agent ever joins. Retries while the previous test's session winds down.
    @MainActor
    func session(masks: [CGRect] = []) throws -> GaiaDeskEmbed {
        let cfg = GaiaDeskEmbed.Configuration(embedToken: token, company: "Acme", server: URL(string: "http://127.0.0.1:9"), guided: true, maskedRects: masks, captureMethod: .snapshot)
        let end = Date().addingTimeInterval(5)
        while true {
            do {
                return try GaiaDeskEmbed.start(cfg, consentGranted: true) { _ in }
            } catch let e as GaiaDeskEmbedError where e.code == "busy" && Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
    }

    // #1: the start-time rects are the app's set; a SwiftUI mask moving later
    // must not drop them.
    @MainActor
    func testStartTimeMasksSurviveALaterMaskChange() throws {
        let card = CGRect(x: 20, y: 130, width: 220, height: 120)
        let embed = try session(masks: [card])
        defer { embed.stop() }
        XCTAssertEqual(embed.appRects, [card])
        let id = UUID()
        let swiftUI = CGRect(x: 1, y: 2, width: 30, height: 40)
        MaskRegistry.shared.set(id, swiftUI)
        defer { MaskRegistry.shared.set(id, nil) }
        embed.masksChanged()
        XCTAssertTrue(embed.sentMasks.contains(card), "the start-time card mask is still sent: \(embed.sentMasks)")
        XCTAssertTrue(embed.sentMasks.contains(swiftUI))
    }

    // #2: masked views are measured again for every frame, so they stay
    // covered as they move.
    @MainActor
    func testMaskedViewsFollowTheirViewAtCaptureTime() throws {
        let w = try window()
        defer { w.isHidden = true }
        let v = UIView(frame: CGRect(x: 10, y: 100, width: 100, height: 50))
        w.rootViewController!.view.addSubview(v)
        let embed = try session()
        defer { embed.stop() }
        try embed.setMaskedViews([v])
        XCTAssertTrue(embed.sentMasks.contains(CGRect(x: 10, y: 100, width: 100, height: 50)))
        v.frame.origin.y = 300 // a scroll, an animation: nothing tells the SDK
        try embed.refreshMasks() // what every captured frame does first
        XCTAssertTrue(embed.sentMasks.contains(CGRect(x: 10, y: 300, width: 100, height: 50)), "\(embed.sentMasks)")
        XCTAssertFalse(embed.sentMasks.contains(CGRect(x: 10, y: 100, width: 100, height: 50)))
    }

    // #8: password fields are masked without being asked, and typing into
    // them (or into anything masked) is refused.
    @MainActor
    func testSecureFieldsAreMaskedAndTypingIntoThemIsRefused() throws {
        let w = try window()
        w.makeKey()
        defer { w.isHidden = true }
        let pw = UITextField(frame: CGRect(x: 20, y: 200, width: 300, height: 40))
        pw.isSecureTextEntry = true
        let plain = UITextField(frame: CGRect(x: 20, y: 400, width: 300, height: 40))
        w.rootViewController!.view.addSubview(pw)
        w.rootViewController!.view.addSubview(plain)
        XCTAssertTrue(Host.scan(excluding: nil).secure.contains(CGRect(x: 20, y: 200, width: 300, height: 40)))
        let embed = try session()
        defer { embed.stop() }
        XCTAssertTrue(embed.currentMasks().contains(CGRect(x: 20, y: 200, width: 300, height: 40)), "masked from the first frame")

        XCTAssertEqual(Guided.refusesTyping(pw, masks: []), "masked")
        XCTAssertNil(Guided.refusesTyping(plain, masks: []))
        XCTAssertEqual(Guided.refusesTyping(plain, masks: [CGRect(x: 0, y: 410, width: 50, height: 5)]), "masked")
        guard pw.becomeFirstResponder(), Guided.firstResponder() === pw else { throw XCTSkip("no first responder in this host") }
        XCTAssertEqual(Guided.deliver(#"{"t":"type","text":"hunter2"}"#, indicator: nil, masks: []), "masked")
        XCTAssertEqual(Guided.deliver(#"{"t":"key","key":"Backspace"}"#, indicator: nil, masks: []), "masked")
        XCTAssertEqual(pw.text ?? "", "")
        XCTAssertTrue(plain.becomeFirstResponder())
        XCTAssertNil(Guided.deliver(#"{"t":"type","text":"hi"}"#, indicator: nil, masks: []))
        XCTAssertEqual(plain.text, "hi")
        plain.resignFirstResponder()
    }

    // #10: no frames while another process's UI is presented over the app.
    @MainActor
    func testOutOfProcessUIStopsFrames() throws {
        _ = try scene()
        XCTAssertFalse(Host.scan(excluding: nil).outOfProcess)
        XCTAssertTrue(Host.isOutOfProcess(PHPickerViewController(configuration: PHPickerConfiguration())))
        XCTAssertTrue(Host.isOutOfProcess(UIActivityViewController(activityItems: ["x"], applicationActivities: nil)))
        XCTAssertTrue(Host.isOutOfProcess(UIDocumentPickerViewController(forOpeningContentTypes: [.data])))
        XCTAssertFalse(Host.isOutOfProcess(UIViewController()))
        // Presented over the host app's own window, as an app would.
        let root = try XCTUnwrap(Host.keyWindow(excluding: nil)?.rootViewController)
        let picker = PHPickerViewController(configuration: PHPickerConfiguration())
        root.present(picker, animated: false)
        let end = Date().addingTimeInterval(3)
        while root.presentedViewController !== picker && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(root.presentedViewController === picker, "presented: \(String(describing: root.presentedViewController))")
        XCTAssertTrue(Host.scan(excluding: nil).outOfProcess, "a presented photo picker blocks frames")
        let host = Host(company: "Acme", method: .snapshot)
        let embed = try session()
        defer { embed.stop() }
        host.attach(embed)
        XCTAssertFalse(host.prepareFrame(), "no frame while it is up")
        root.dismiss(animated: false)
        let gone = Date().addingTimeInterval(3)
        while root.presentedViewController != nil && Date() < gone { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(Host.scan(excluding: nil).outOfProcess)
        XCTAssertTrue(host.prepareFrame())
    }

    // #5: the picture comes from each oriented frame; a portrait-locked app on
    // a rotated device keeps its own orientation.
    func testReplayKitFramesAreTurnedToTheInterface() {
        let buffer = CGSize(width: 1206, height: 2622) // the panel, natively portrait
        let screenPortrait = CGSize(width: 402, height: 874)
        typealias O = CGImagePropertyOrientation
        let cases: [(O?, UIInterfaceOrientation, O)] = [
            (.up, .portrait, .up),
            (nil, .portrait, .up),
            (.right, .portrait, .up), // portrait-locked app, device turned: the app's shape wins
            (.left, .portrait, .up),
            (.left, .landscapeRight, .left), // the attachment agrees: used
            (.right, .landscapeLeft, .right),
            (nil, .landscapeRight, .left),
            (nil, .landscapeLeft, .right),
            (.up, .landscapeLeft, .right), // disagrees: the interface decides
            (.down, .portraitUpsideDown, .down),
            (nil, .portraitUpsideDown, .down),
        ]
        for (attached, interface, want) in cases {
            let got = ReplayKitCapture.orientation(attached: attached, buffer: buffer, interface: interface)
            XCTAssertEqual(got, want, "attached \(String(describing: attached)), interface \(interface.rawValue)")
            let upright = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: buffer)).oriented(got).extent.size
            let pic = ReplayKitCapture.picture(frame: upright, screen: screenPortrait)
            XCTAssertEqual(pic.width > pic.height, interface.isLandscape, "the picture has the interface's shape")
            XCTAssertEqual(pic.width / pic.height, upright.width / upright.height, accuracy: 0.01, "and the frame's")
        }
        XCTAssertEqual(ReplayKitCapture.picture(frame: CGSize(width: 2622, height: 1206), screen: screenPortrait), CGRect(x: 0, y: 0, width: 874, height: 402))
    }

    // #5 in the Simulator: in each orientation the app can take, the screen
    // (the snapshot's picture) and ReplayKit's picture agree.
    @MainActor
    func testEveryOrientationGivesAPictureInWindowPoints() throws {
        let s = try scene()
        guard #available(iOS 16, *) else { throw XCTSkip("iOS 16+") }
        var reached: [UIInterfaceOrientation] = []
        for (mask, o) in [(UIInterfaceOrientationMask.landscapeRight, UIInterfaceOrientation.landscapeRight), (.landscapeLeft, .landscapeLeft), (.portraitUpsideDown, .portraitUpsideDown), (.portrait, .portrait)] {
            s.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            let end = Date().addingTimeInterval(3)
            while s.interfaceOrientation != o && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard s.interfaceOrientation == o else { continue } // e.g. upside down on a Face ID iPhone
            reached.append(o)
            let screen = s.screen.bounds.size
            XCTAssertEqual(screen.width > screen.height, o.isLandscape, "the snapshot's picture (screen bounds) is in interface points")
            let native = CGSize(width: min(screen.width, screen.height) * 3, height: max(screen.width, screen.height) * 3)
            let got = ReplayKitCapture.orientation(attached: nil, buffer: native, interface: o)
            let upright = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: native)).oriented(got).extent.size
            XCTAssertEqual(ReplayKitCapture.picture(frame: upright, screen: screen), CGRect(origin: .zero, size: screen))
            XCTAssertEqual(Host.keyWindow(excluding: nil).map { $0.bounds.size } ?? screen, screen, "window points == picture points")
        }
        XCTAssertTrue(reached.contains(.landscapeRight) && reached.contains(.portrait), "reached \(reached.map(\.rawValue))")
    }

    // #13: the indicator counts as visible only on the screen itself, with
    // nothing over its pill, even inside its own window.
    @MainActor
    func testTheIndicatorIsNotVisibleWhenCoveredOrOffScreen() throws {
        _ = try scene()
        let ind = Indicator(title: "Sharing with Acme", guided: false)
        ind.show()
        defer { ind.close() }
        let w = try XCTUnwrap(ind.window)
        w.layoutIfNeeded()
        XCTAssertTrue(ind.isVisible())
        let pill = try XCTUnwrap(w.rootViewController?.view.subviews.first { $0.accessibilityIdentifier == "gaiadesk.indicator" })
        let cover = UIView(frame: pill.convert(pill.bounds, to: w.rootViewController!.view))
        cover.backgroundColor = .white
        w.rootViewController!.view.addSubview(cover)
        XCTAssertFalse(ind.isVisible(), "a view over the pill in its own window hides it")
        cover.removeFromSuperview()
        XCTAssertTrue(ind.isVisible())
        let home = w.frame
        w.frame = home.offsetBy(dx: 0, dy: -home.height)
        XCTAssertFalse(ind.isVisible(), "a window moved off the screen")
        w.frame = home
        XCTAssertTrue(ind.isVisible())
    }

    // #14: the customer's pause is theirs: the app cannot lift it.
    @MainActor
    func testTheAppCannotUndoTheCustomersPause() throws {
        let embed = try session()
        defer { embed.stop() }
        embed.customerSetPaused(true)
        XCTAssertEqual(embed.pausedSent, true)
        embed.setPaused(false)
        XCTAssertEqual(embed.pausedSent, true, "the app's resume is ignored while the customer paused")
        embed.customerSetPaused(false)
        XCTAssertEqual(embed.pausedSent, false)
        embed.setPaused(true)
        XCTAssertEqual(embed.pausedSent, true, "the app may still pause")
        embed.setPaused(false)
        XCTAssertEqual(embed.pausedSent, false, "and resume its own pause")
    }
}

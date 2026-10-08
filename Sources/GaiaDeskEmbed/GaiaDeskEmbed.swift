// GaiaDeskEmbed for iOS: share your app's screen with your support team from
// a "Get help" button. A Swift layer over libgaiadesk_embed's C API.
//
// What the library enforces (this package cannot skip it): it refuses to
// start without consent; frames are encoded and sent only while this
// package's "Sharing with <company>" indicator reports itself on screen; the
// rects you mask are painted out of every frame before it is encoded; input
// is off unless you allow `guided` AND the session is "cobrowse", and a
// request outside your window or on a mask is refused before it reaches you.
// What this package does: the indicator, capturing ONLY your app (ReplayKit's
// in-app capture, or a snapshot of your app's windows), and delivering guided
// requests to your own views through public UIKit API.

import Foundation
import GaiaDeskEmbedFFI
import UIKit

/// A refusal from the library: `code` is stable (`consent_required`,
/// `bad_token`, `bad_config`, `busy`, …), `message` is for people.
public struct GaiaDeskEmbedError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }

    /// Wrappers (React Native, Flutter) report their own refusals the same way.
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public final class GaiaDeskEmbed {
    /// How the app's screen is captured. Both capture only this app.
    public enum CaptureMethod: String, Sendable {
        /// ReplayKit in-app capture (`RPScreenRecorder.startCapture`): exactly
        /// what the app shows, including video and Metal content. iOS asks the
        /// user to allow screen recording of the app the first time. Not
        /// available in the iOS Simulator (use `.snapshot` there).
        case replayKit
        /// A snapshot of the app's windows (`drawHierarchy`), no system prompt.
        /// Misses content drawn outside UIKit's hierarchy (some video, Metal).
        case snapshot
    }

    public struct Configuration: Sendable {
        /// `gdemb_…`, from your backend (`POST /v1/support/sessions`).
        public var embedToken: String
        /// Shown on the consent dialog and the indicator.
        public var company: String
        /// Default `https://gaiadesk.net`.
        public var server: URL?
        /// Allow guided input (the session must be "cobrowse" too).
        public var guided: Bool
        /// 1 to 30.
        public var fps: Int
        /// Regions painted out from the very first frame: rects in your key
        /// window's coordinates, in points (`rectInWindow` gives one for a
        /// view; SwiftUI views marked `.gaiaDeskMasked()` are added for you).
        public var maskedRects: [CGRect]
        public var captureMethod: CaptureMethod

        public init(embedToken: String, company: String, server: URL? = nil, guided: Bool = false, fps: Int = 15, maskedRects: [CGRect] = [], captureMethod: CaptureMethod = .replayKit) {
            self.embedToken = embedToken
            self.company = company
            self.server = server
            self.guided = guided
            self.fps = fps
            self.maskedRects = maskedRects
            self.captureMethod = captureMethod
        }
    }

    public enum Event: Equatable, Sendable {
        case state(String)
        case code(String, sessionId: String, mode: String)
        case joined(agent: String?)
        case left
        case control(allowed: Bool)
        case action(String, applied: Bool, reason: String?)
        case error(code: String, message: String)
        case ended(reason: String)
    }

    /// The library's version ("0.1.0").
    public static var version: String { String(cString: gd_embed_version()) }

    /// What the bundled binary is (JSON: version, codec, os, arch, test_source).
    public static var buildInfo: String { String(cString: gd_embed_build_info()) }

    /// The session running in this app, if any (one at a time).
    @MainActor public private(set) static weak var current: GaiaDeskEmbed?

    private let lock = NSLock()
    private var handle: OpaquePointer?
    let host: Host

    /// Start sharing. `consent` is your user's YES to a consent dialog:
    /// `requestConsent` (the SDK's), or `recordConsent` after your own. It is
    /// single-use, expires after 10 minutes, and must match the session: the
    /// same company, and guided only if the user was asked about guiding. The
    /// library refuses otherwise. `onEvent` is called on the main queue. Call
    /// on the main thread.
    @MainActor
    public static func start(_ config: Configuration, consent: Consent, onEvent: @escaping (Event) -> Void) throws -> GaiaDeskEmbed {
        var config = config
        let appRects = config.maskedRects
        config.maskedRects = appRects + MaskRegistry.shared.rects + Host.scan(excluding: nil).secure
        let json = try configJSON(config, consent: consent)
        let box = EventBox(onEvent)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        let cb = GdEmbedCallbacks(on_event: { userData, eventJSON in
            guard let userData, let eventJSON else { return }
            let box = Unmanaged<EventBox>.fromOpaque(userData).takeUnretainedValue()
            let event = GaiaDeskEmbed.parse(String(cString: eventJSON))
            if case .some(.ended) = event {
                DispatchQueue.main.async {
                    box.deliver(event)
                    Unmanaged<EventBox>.fromOpaque(userData).release()
                }
            } else if let event {
                DispatchQueue.main.async { box.deliver(event) }
            }
        }, user_data: ctx)
        let host = Host(company: config.company, method: config.captureMethod)
        guard let h = gd_embed_start_mobile(json, cb, host.retainedCallbacks()) else {
            Unmanaged<EventBox>.fromOpaque(ctx).release()
            throw lastError()
        }
        let embed = GaiaDeskEmbed(handle: h, host: host)
        // The start-time rects stay the app's set: later changes (a SwiftUI
        // mask moving, a secure field appearing) are added to them, never
        // replace them.
        embed.appRects = appRects
        embed.sentMasks = config.maskedRects
        host.attach(embed)
        current = embed
        return embed
    }

    private init(handle: OpaquePointer, host: Host) {
        self.handle = handle
        self.host = host
    }

    deinit { stop() }

    /// End the session (`ended` follows with `app_stopped`). Safe to call
    /// more than once; returns at once (the session winds down in the
    /// background).
    public func stop() {
        lock.lock()
        let h = handle
        handle = nil
        lock.unlock()
        guard let h else { return }
        host.detach()
        DispatchQueue.global(qos: .userInitiated).async { gd_embed_stop(h) }
    }

    /// Mask these rects: in your key window's coordinates, in points.
    /// Replaces any earlier set of rects or views (SwiftUI `.gaiaDeskMasked()`
    /// views and secure text fields are always added).
    /// Any thread (applied on the main thread).
    public func setMaskedRects(_ rects: [CGRect]) throws {
        try GaiaDeskEmbed.onMain {
            appRects = rects
            maskedViews = []
            try refreshMasks()
        }
    }

    /// Run `f` on the main thread and wait for it.
    static func onMain<T>(_ f: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try MainActor.assumeIsolated(f) }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(f) }
    }

    /// Mask these views (password fields, card numbers, …). They are
    /// measured again for every frame, so they stay masked as they move.
    /// Replaces any earlier set of rects or views.
    @MainActor
    public func setMaskedViews(_ views: [UIView]) throws {
        appRects = []
        maskedViews = views.map { WeakView($0) }
        try refreshMasks()
    }

    /// Pause (or resume) guided input. A pause your customer chose on the
    /// indicator is theirs: only they can resume it (`setPaused(false)` is
    /// ignored until they do).
    public func setPaused(_ paused: Bool) {
        lock.lock()
        let refused = !paused && customerPaused
        lock.unlock()
        if refused { return }
        sendPaused(paused)
    }

    /// Focus entered (true) or left (false) a secret field the SDK cannot
    /// recognise itself: a wrapper's (React Native, Flutter) or your own
    /// custom one. While true, guided typing and keys are refused (`masked`).
    /// Native `isSecureTextEntry` fields are refused without it.
    public func setSecretFocus(_ secret: Bool) {
        lock.lock()
        secretFocus = secret
        lock.unlock()
    }

    /// Whether focus is in a secret field (`setSecretFocus`).
    var isSecretFocus: Bool {
        lock.lock()
        defer { lock.unlock() }
        return secretFocus
    }

    /// The indicator's Pause / Allow control button: the customer's own
    /// pause, which only they can lift (the library holds it too).
    func customerSetPaused(_ paused: Bool) {
        lock.lock()
        customerPaused = paused
        lock.unlock()
        withHandle { h in
            pausedSent = paused
            _ = gd_embed_customer_pause(h, paused ? 1 : 0)
        }
    }

    private func sendPaused(_ paused: Bool) {
        withHandle { h in
            // -2: the library refused to lift the customer's pause.
            if gd_embed_set_paused(h, paused ? 1 : 0) == 0 { pausedSent = paused }
        }
    }

    /// A view's frame in its window's coordinates, in points: the space mask
    /// rects are in.
    @MainActor
    public static func rectInWindow(_ view: UIView) -> CGRect? {
        guard view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    // MARK: - plumbing

    /// The rects and views the app set (main thread).
    var appRects: [CGRect] = []
    private var maskedViews: [WeakView] = []
    /// What the library was last told to mask (main thread).
    private(set) var sentMasks: [CGRect] = []
    /// Focus is in a secret field, by the app's word (under `lock`).
    private var secretFocus = false
    /// The customer paused guided input on the indicator (under `lock`).
    private var customerPaused = false
    /// The last pause state sent to the library (under `lock`; tests).
    private(set) var pausedSent: Bool?

    @MainActor
    func masksChanged() {
        try? refreshMasks()
    }

    /// Everything masked right now, measured now (main thread): the app's
    /// rects, its views where they are, marked SwiftUI views, and every
    /// secure text field on screen.
    @MainActor
    func currentMasks() -> [CGRect] {
        // Where the views are ON SCREEN now (their presentation layers, which
        // an animation moves long before the model frame gets there), and
        // everything while any of them, or anything holding them, is still
        // animating (a navigation push, the keyboard, UIView.animate): a
        // moving view is never trusted to be where it was measured.
        let views = maskedViews.compactMap(\.view) + Host.scan(excluding: host.indicatorWindow).secureViews
        var rects = appRects + MaskRegistry.shared.rects
        var moving = false
        for v in views {
            if Host.isAnimating(v) { moving = true }
            // Both where it is drawn and where it is set to be (a change not
            // yet committed to the screen): whichever the next frame shows.
            let drawn = Host.presentedRect(v)
            let model = GaiaDeskEmbed.rectInWindow(v)
            if let drawn { rects.append(drawn) }
            if let model, model != drawn { rects.append(model) }
        }
        if moving { rects.append(Host.everything) }
        return rects
    }

    /// Measure the masks again and tell the library when they moved. Called
    /// for every captured frame, before it is pushed (main thread).
    @MainActor
    func refreshMasks() throws {
        let masks = currentMasks()
        guard masks != sentMasks else { return }
        sentMasks = masks
        try withHandle { h in
            let c = masks.map { GdRect(x: Double($0.origin.x), y: Double($0.origin.y), w: Double($0.size.width), h: Double($0.size.height)) }
            let rc = c.withUnsafeBufferPointer { gd_embed_set_mask_rects(h, $0.baseAddress, $0.count) }
            if rc != 0 { throw GaiaDeskEmbed.lastError() }
        }
    }

    /// Run `f` with the live handle, under the lock that `stop` takes (so a
    /// frame or an answer never reaches a freed handle).
    func withHandle(_ f: (OpaquePointer) throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        if let h = handle { try f(h) }
    }

    static func configJSON(_ c: Configuration, consent: Consent?) throws -> String {
        var o: [String: Any] = [
            "embed_token": c.embedToken,
            "consent_granted": consent != nil,
            "company": c.company,
            "capture": "app",
            "guided": c.guided,
            "fps": c.fps,
        ]
        if let consent { o["consent_token"] = consent.token }
        if let s = c.server { o["server"] = s.absoluteString }
        if !c.maskedRects.isEmpty {
            o["masks"] = c.maskedRects.map { ["x": Double($0.origin.x), "y": Double($0.origin.y), "w": Double($0.width), "h": Double($0.height)] }
        }
        let data = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func lastError() -> GaiaDeskEmbedError {
        let raw = String(cString: gd_embed_last_error())
        guard let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return GaiaDeskEmbedError(code: "unknown", message: raw)
        }
        return GaiaDeskEmbedError(code: o["code"] as? String ?? "unknown", message: o["message"] as? String ?? "")
    }

    /// One event's JSON → an `Event` (nil for a kind this version does not know).
    public static func parse(_ json: String) -> Event? {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["type"] as? String else { return nil }
        let s = { (k: String) in o[k] as? String }
        switch t {
        case "state": return s("state").map(Event.state)
        case "code": return .code(s("code") ?? "", sessionId: s("session_id") ?? "", mode: s("mode") ?? "view")
        case "joined": return .joined(agent: s("agent"))
        case "left": return .left
        case "control": return .control(allowed: o["allowed"] as? Bool ?? false)
        case "action": return .action(s("action") ?? "", applied: o["applied"] as? Bool ?? false, reason: s("reason"))
        case "error": return .error(code: s("code") ?? "", message: s("message") ?? "")
        case "ended": return .ended(reason: s("reason") ?? "")
        default: return nil
        }
    }
}

/// A masked view, not kept alive by the mask.
struct WeakView {
    weak var view: UIView?
    init(_ v: UIView) { view = v }
}

/// Holds the app's handler for the C callback's `user_data`.
final class EventBox {
    private let handler: (GaiaDeskEmbed.Event) -> Void
    init(_ handler: @escaping (GaiaDeskEmbed.Event) -> Void) { self.handler = handler }
    func deliver(_ e: GaiaDeskEmbed.Event?) {
        if let e { handler(e) }
    }
}

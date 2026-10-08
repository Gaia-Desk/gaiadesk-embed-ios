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
    private let host: Host

    /// Start sharing. `consentGranted` must be your user's answer to a
    /// consent dialog (`requestConsent`, or your own): the library refuses
    /// without it. `onEvent` is called on the main queue. Call on the main
    /// thread.
    @MainActor
    public static func start(_ config: Configuration, consentGranted: Bool, onEvent: @escaping (Event) -> Void) throws -> GaiaDeskEmbed {
        var config = config
        config.maskedRects += MaskRegistry.shared.rects
        let json = try configJSON(config, consentGranted: consentGranted)
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
    /// Replaces any earlier set (SwiftUI `.gaiaDeskMasked()` views are added).
    public func setMaskedRects(_ rects: [CGRect]) throws {
        try withHandle { h in
            let all = rects + MaskRegistry.shared.rects
            let c = all.map { GdRect(x: Double($0.origin.x), y: Double($0.origin.y), w: Double($0.size.width), h: Double($0.size.height)) }
            let rc = c.withUnsafeBufferPointer { gd_embed_set_mask_rects(h, $0.baseAddress, $0.count) }
            if rc != 0 { throw GaiaDeskEmbed.lastError() }
        }
        appRects = rects
    }

    /// Mask these views (password fields, card numbers, …). Call again after
    /// your layout changes.
    @MainActor
    public func setMaskedViews(_ views: [UIView]) throws {
        try setMaskedRects(views.compactMap(GaiaDeskEmbed.rectInWindow))
    }

    /// Pause (or resume) guided input, as the indicator's own button does.
    public func setPaused(_ paused: Bool) {
        try? withHandle { h in _ = gd_embed_set_paused(h, paused ? 1 : 0) }
    }

    /// A view's frame in its window's coordinates, in points: the space mask
    /// rects are in.
    @MainActor
    public static func rectInWindow(_ view: UIView) -> CGRect? {
        guard view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    // MARK: - plumbing

    /// The rects the app set (re-sent when SwiftUI masks move).
    private var appRects: [CGRect] = []

    func masksChanged() {
        try? setMaskedRects(appRects)
    }

    /// Run `f` with the live handle, under the lock that `stop` takes (so a
    /// frame or an answer never reaches a freed handle).
    func withHandle(_ f: (OpaquePointer) throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        if let h = handle { try f(h) }
    }

    static func configJSON(_ c: Configuration, consentGranted: Bool) throws -> String {
        var o: [String: Any] = [
            "embed_token": c.embedToken,
            "consent_granted": consentGranted,
            "company": c.company,
            "capture": "app",
            "guided": c.guided,
            "fps": c.fps,
        ]
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

/// Holds the app's handler for the C callback's `user_data`.
final class EventBox {
    private let handler: (GaiaDeskEmbed.Event) -> Void
    init(_ handler: @escaping (GaiaDeskEmbed.Event) -> Void) { self.handler = handler }
    func deliver(_ e: GaiaDeskEmbed.Event?) {
        if let e { handler(e) }
    }
}

// The default consent dialog (iOS has no library-drawn one: this is it), and
// SwiftUI's way to mark views as masked.

import GaiaDeskEmbedFFI
import SwiftUI
import UIKit

extension GaiaDeskEmbed {
    /// The consent dialog's wording. Pure.
    public static func consentText(company: String, guided: Bool) -> (title: String, message: String) {
        let title = "Share this app's screen with \(company) support?"
        var message = "\(company)'s support team will see this app's screen until you press Stop. Nothing outside this app is shared."
        if guided {
            message += " They may also point at things and operate this app's buttons and fields; you can pause that at any time."
        }
        return (title, message)
    }

    /// Your user's YES to sharing this app with `company` (and, if `guided`,
    /// to being guided), as the library recorded it: what `start` takes.
    /// Opaque, single-use, valid for 10 minutes; a session must match it.
    public struct Consent: Sendable, Equatable {
        /// The library's single-use token (wrappers carry it across their
        /// bridge). Opaque; never persist it: it expires in 10 minutes and
        /// works once.
        public let token: String
        public let company: String
        public let guided: Bool
    }

    /// Ask the user (a UIAlertController on `presenter`, default: the top
    /// view controller of the key window). Their YES, for `start`; nil when
    /// they declined (or nothing could be shown).
    @MainActor
    public static func requestConsent(company: String, guided: Bool = false, from presenter: UIViewController? = nil) async -> Consent? {
        let (title, message) = consentText(company: company, guided: guided)
        guard let vc = presenter ?? topViewController() else { return nil }
        let agreed = await withCheckedContinuation { cont in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Don't Share", style: .cancel) { _ in cont.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Share", style: .default) { _ in cont.resume(returning: true) })
            vc.present(alert, animated: true)
        }
        return agreed ? try? recordConsent(company: company, guided: guided) : nil
    }

    /// Your own consent dialog said YES: call this right then, with what
    /// the dialog asked (the company named, and whether it said the agent
    /// may guide). Never call it without asking.
    public static func recordConsent(company: String, guided: Bool) throws -> Consent {
        guard let t = gd_embed_record_consent(company, "app", guided ? 1 : 0) else { throw lastError() }
        return Consent(token: String(cString: t), company: company, guided: guided)
    }

    /// For wrappers (React Native, Flutter) that carry a consent across
    /// their bridge: the token `recordConsent` / `requestConsent` gave. The
    /// library checks it (issued here, unused, unexpired, matching).
    public static func consent(token: String, company: String, guided: Bool) -> Consent {
        Consent(token: token, company: company, guided: guided)
    }

    @MainActor
    static func topViewController() -> UIViewController? {
        var vc = Host.keyWindow(excluding: nil)?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

/// SwiftUI views marked `.gaiaDeskMasked()`: their frames, in window points.
final class MaskRegistry {
    static let shared = MaskRegistry()
    private let lock = NSLock()
    private var frames: [UUID: CGRect] = [:]

    var rects: [CGRect] {
        lock.lock()
        defer { lock.unlock() }
        return Array(frames.values)
    }

    func set(_ id: UUID, _ rect: CGRect?) {
        lock.lock()
        let old = frames[id]
        frames[id] = rect
        lock.unlock()
        if old != rect {
            DispatchQueue.main.async { MainActor.assumeIsolated { GaiaDeskEmbed.current?.masksChanged() } }
        }
    }
}

struct GaiaDeskMaskModifier: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { MaskRegistry.shared.set(id, g.frame(in: .global)) }
                        .onChange(of: g.frame(in: .global)) { MaskRegistry.shared.set(id, $0) }
                        .onDisappear { MaskRegistry.shared.set(id, nil) }
                }
            )
    }
}

extension View {
    /// Paint this view out of everything shared with support (card numbers,
    /// balances, passwords). Masks are in place from the first frame when
    /// the view is on screen at `start`, and follow it as it moves.
    public func gaiaDeskMasked() -> some View {
        modifier(GaiaDeskMaskModifier())
    }
}

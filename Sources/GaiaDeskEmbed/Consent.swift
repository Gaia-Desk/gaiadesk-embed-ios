// The default consent dialog (iOS has no library-drawn one: this is it), and
// SwiftUI's way to mark views as masked.

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

    /// Ask the user (a UIAlertController on `presenter`, default: the top
    /// view controller of the key window). Pass the answer to `start`.
    @MainActor
    public static func requestConsent(company: String, guided: Bool = false, from presenter: UIViewController? = nil) async -> Bool {
        let (title, message) = consentText(company: company, guided: guided)
        guard let vc = presenter ?? topViewController() else { return false }
        return await withCheckedContinuation { cont in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Don't Share", style: .cancel) { _ in cont.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Share", style: .default) { _ in cont.resume(returning: true) })
            vc.present(alert, animated: true)
        }
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
            DispatchQueue.main.async { GaiaDeskEmbed.current?.masksChanged() }
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

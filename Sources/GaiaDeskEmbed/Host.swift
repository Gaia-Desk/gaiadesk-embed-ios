// The library's view of this package (`GdMobileHost`): every C callback lands
// here, on one of the library's threads, and hops to the main queue for UI.
// The two answers the library polls (is the indicator visible, where is the
// app's window) are read from state the main thread keeps current, so they
// never wait on the main thread.

import Foundation
import GaiaDeskEmbedFFI
import UIKit

/// A value shared between the main thread and the library's threads.
final class Locked<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    var get: T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ v: T) {
        lock.lock()
        value = v
        lock.unlock()
    }
}

final class Host {
    let company: String
    let method: GaiaDeskEmbed.CaptureMethod
    private weak var embed: GaiaDeskEmbed?
    /// Kept by the main thread for the library's polls.
    let visible = Locked(false)
    let appFrame = Locked<CGRect?>(nil)
    /// Main thread only.
    private var indicator: Indicator?
    private var capture: Capture?
    private var watch: Timer?

    init(company: String, method: GaiaDeskEmbed.CaptureMethod) {
        self.company = company
        self.method = method
    }

    func attach(_ e: GaiaDeskEmbed) { embed = e }

    /// The app stopped: no more frames or answers through the handle.
    func detach() {
        DispatchQueue.main.async { [self] in
            capture?.stop()
            capture = nil
        }
    }

    // MARK: called by the library (any thread)

    func showIndicator(title: String, guided: Bool) -> Bool {
        DispatchQueue.main.async { [self] in
            guard indicator == nil else { return }
            let ind = Indicator(title: title, guided: guided)
            ind.onStop = { [weak self] in self?.embed?.withHandle { h in _ = gd_embed_customer_stop(h) } }
            ind.onPause = { [weak self] paused in self?.embed?.customerSetPaused(paused) }
            indicator = ind
            ind.show()
            startWatching()
        }
        return true
    }

    func setStatus(_ text: String) {
        DispatchQueue.main.async { [self] in indicator?.status = text }
    }

    func setPaused(_ paused: Bool) {
        DispatchQueue.main.async { [self] in indicator?.paused = paused }
    }

    func refreshIndicator() {
        DispatchQueue.main.async { [self] in indicator?.raise() }
    }

    func closeIndicator() {
        DispatchQueue.main.async { [self] in
            watch?.invalidate()
            watch = nil
            visible.set(false)
            indicator?.close()
            indicator = nil
        }
    }

    /// Waits for ReplayKit's answer (the library calls this from its video
    /// thread and allows it 15 seconds; iOS may be asking the user).
    func startCapture(fps: Int) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let ok = Locked(false)
        DispatchQueue.main.async { [self] in
            let c: Capture = method == .replayKit ? ReplayKitCapture(host: self) : SnapshotCapture(host: self)
            capture = c
            c.start(fps: fps) { started in
                ok.set(started)
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 14)
        return ok.get
    }

    func stopCapture() {
        DispatchQueue.main.async { [self] in
            capture?.stop()
            capture = nil
        }
    }

    func deliver(_ json: String, token: UInt64) {
        DispatchQueue.main.async { [self] in
            let reason = MainActor.assumeIsolated { Guided.deliver(json, indicator: indicator, masks: embed?.currentMasks() ?? [], secretFocus: embed?.isSecretFocus ?? false) }
            if token != 0 {
                embed?.withHandle { h in _ = gd_embed_action_result(h, token, reason) }
            }
        }
    }

    /// The session is over (the library's last call).
    func release() {
        DispatchQueue.main.async { [self] in
            capture?.stop()
            capture = nil
            watch?.invalidate()
            watch = nil
            indicator?.close()
            indicator = nil
            visible.set(false)
        }
    }

    // MARK: frames

    /// The indicator's window (main thread), never captured or masked.
    var indicatorWindow: UIWindow? { indicator?.window }

    /// Before each frame (main thread): the masks measured again and pushed
    /// to the library, and whether a frame may be sent at all (not while
    /// another process's UI — a photo picker, Safari, a share sheet — is
    /// presented over the app).
    /// Returns the masks for this frame (window points, measured now), or
    /// nil: no frame.
    @MainActor
    func prepareFrame() -> [CGRect]? {
        guard let embed else { return nil }
        let scan = Host.scan(excluding: indicator?.window)
        held(scan.outOfProcess)
        if scan.outOfProcess { return nil }
        do {
            // The session's list too: the library refuses clicks on masks.
            try embed.refreshMasks()
        } catch {
            return nil // masks fail closed: no frame the library could not mask
        }
        return embed.sentMasks
    }

    /// Main thread: whether frames are held for out-of-process UI.
    private var pictureHeld = false

    /// Tell the agent when the picture stops and starts again.
    @MainActor
    private func held(_ now: Bool) {
        guard now != pictureHeld else { return }
        pictureHeld = now
        embed?.withHandle { h in _ = gd_embed_notice(h, now ? "picture_paused" : "picture_resumed") }
    }

    /// One BGRA picture for the library, with the masks measured for it
    /// (painted on this frame whatever the session's list says); false: stop
    /// capturing.
    func push(_ base: UnsafeRawPointer, width: Int, height: Int, stride: Int, picture: CGRect, masks: [CGRect]) -> Bool {
        var going = false
        embed?.withHandle { h in
            let pic = GdRect(x: Double(picture.origin.x), y: Double(picture.origin.y), w: Double(picture.width), h: Double(picture.height))
            let rects = masks.map { GdRect(x: Double($0.origin.x), y: Double($0.origin.y), w: Double($0.width), h: Double($0.height)) }
            let rc = rects.withUnsafeBufferPointer {
                gd_embed_push_frame_masked(h, base.assumingMemoryBound(to: UInt8.self), UInt32(width), UInt32(height), stride, pic, $0.baseAddress, $0.count)
            }
            going = rc != 1
        }
        return going
    }

    // MARK: main thread

    /// Recomputes the polled state four times a second.
    private func startWatching() {
        watch?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.observe() }
        RunLoop.main.add(t, forMode: .common)
        watch = t
        observe()
    }

    private func observe() {
        visible.set(indicator?.isVisible() ?? false)
        appFrame.set(Host.keyWindow(excluding: indicator?.window).map { $0.convert($0.bounds, to: $0.screen.coordinateSpace) })
    }

    /// What a frame must respect, found by walking the app's windows (main
    /// thread): every secure text field's rect (window coordinates, masked
    /// automatically) and whether out-of-process UI is presented.
    @MainActor
    static func scan(excluding: UIWindow?) -> (secure: [CGRect], secureViews: [UIView], outOfProcess: Bool) {
        guard let scene = Indicator.scene() else { return ([], [], false) }
        var secure: [CGRect] = []
        var secureViews: [UIView] = []
        var remote = false
        for w in scene.windows where w !== excluding && !(w is IndicatorWindow) && !w.isHidden {
            if isSystemInputWindow(w) { continue }
            var vc = w.rootViewController
            while let v = vc {
                if isOutOfProcess(v) { remote = true }
                vc = v.presentedViewController
            }
            walk(w) { v in
                if v.isHidden || v.alpha < 0.01 { return false }
                if (v as? UITextField)?.isSecureTextEntry == true || (v as? UITextView)?.isSecureTextEntry == true {
                    secure.append(v.convert(v.bounds, to: nil))
                    secureViews.append(v)
                }
                if NSStringFromClass(type(of: v)) == "_UIRemoteView" { remote = true }
                return true
            }
        }
        return (secure, secureViews, remote)
    }

    /// A mask covering any window: painted while masked views move.
    static let everything = CGRect(x: -100_000, y: -100_000, width: 300_000, height: 300_000)

    /// Where `v` is on screen now, in its window's points: from the
    /// presentation layers (what is being drawn mid-animation), not the
    /// model frames (where an animation will END). Nil when not in a window.
    static func presentedRect(_ v: UIView) -> CGRect? {
        guard let w = v.window else { return nil }
        if let pl = v.layer.presentation(), let wl = w.layer.presentation() {
            return pl.convert(pl.bounds, to: wl)
        }
        return v.convert(v.bounds, to: nil)
    }

    /// Whether `v` or any view holding it (up to its window) has a running
    /// animation.
    static func isAnimating(_ v: UIView) -> Bool {
        var cur: UIView? = v
        while let x = cur {
            if let keys = x.layer.animationKeys(), !keys.isEmpty { return true }
            cur = x.superview
        }
        return false
    }

    /// View controllers whose content another process draws.
    static let outOfProcessClasses = ["PHPickerViewController", "SFSafariViewController", "UIActivityViewController", "UIDocumentPickerViewController",
                                      "UIImagePickerController", "MFMailComposeViewController", "MFMessageComposeViewController", "CNContactPickerViewController",
                                      "QLPreviewController", "UICloudSharingController", "EKEventEditViewController", "PKAddPassesViewController"]

    static func isOutOfProcess(_ vc: UIViewController) -> Bool {
        outOfProcessClasses.contains { name in NSClassFromString(name).map { vc.isKind(of: $0) } ?? false }
    }

    /// The keyboard's and text effects' windows (system input, not the app's content).
    static func isSystemInputWindow(_ w: UIWindow) -> Bool {
        let n = NSStringFromClass(type(of: w))
        return n.contains("Keyboard") || n.contains("TextEffects")
    }

    private static func walk(_ v: UIView, _ visit: (UIView) -> Bool) {
        guard visit(v) else { return }
        for s in v.subviews { walk(s, visit) }
    }

    /// The app's key window (never the indicator's).
    static func keyWindow(excluding: UIWindow?) -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let windows = active?.windows.filter { $0 !== excluding && !$0.isHidden } ?? []
        return windows.first { $0.isKeyWindow } ?? windows.first { $0.windowLevel == .normal }
    }

    // MARK: the C table

    static func from(_ p: UnsafeMutableRawPointer?) -> Host { Unmanaged<Host>.fromOpaque(p!).takeUnretainedValue() }

    func retainedCallbacks() -> GdMobileHost {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        return GdMobileHost(
            ctx: ctx,
            show_indicator: { ctx, title, _, guided in
                Host.from(ctx).showIndicator(title: title.map { String(cString: $0) } ?? "", guided: guided != 0) ? 1 : 0
            },
            indicator_visible: { ctx in Host.from(ctx).visible.get ? 1 : 0 },
            set_status: { ctx, text in Host.from(ctx).setStatus(text.map { String(cString: $0) } ?? "") },
            set_indicator_paused: { ctx, p in Host.from(ctx).setPaused(p != 0) },
            refresh_indicator: { ctx in Host.from(ctx).refreshIndicator() },
            close_indicator: { ctx in Host.from(ctx).closeIndicator() },
            start_capture: { ctx, _, fps in Host.from(ctx).startCapture(fps: Int(fps)) ? 1 : 0 },
            stop_capture: { ctx in Host.from(ctx).stopCapture() },
            app_frame: { ctx, out in
                guard let r = Host.from(ctx).appFrame.get, let out else { return 0 }
                out.pointee = GdRect(x: Double(r.origin.x), y: Double(r.origin.y), w: Double(r.width), h: Double(r.height))
                return 1
            },
            deliver: { ctx, json, token in Host.from(ctx).deliver(json.map { String(cString: $0) } ?? "", token: token) },
            release: { ctx in
                let h = Unmanaged<Host>.fromOpaque(ctx!)
                h.takeUnretainedValue().release()
                // Balanced on the main queue, after release()'s own work there.
                DispatchQueue.main.async { h.release() }
            }
        )
    }
}

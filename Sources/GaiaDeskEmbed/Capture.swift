// Capturing THIS app only, as BGRA pictures for the library (which masks and
// encodes them). Two ways, both limited to the app by iOS itself:
//
// * ReplayKit's in-app capture: what the app shows on screen, including
//   video and Metal. iOS asks the user once ("Allow screen recording in
//   <app>?") and draws its own recording indication. It never sees other
//   apps, the Home Screen or system UI, and stops when the app leaves the
//   foreground. Not in the iOS Simulator.
// * a snapshot of the app's own windows (`drawHierarchy`) at the session's
//   frame rate: no prompt, works in the Simulator, misses content that is not
//   drawn through UIKit's hierarchy.
//
// The indicator's own window is never in a snapshot.

import CoreImage
import CoreMedia
import ReplayKit
import UIKit

protocol Capture: AnyObject {
    /// Main thread. `done` says (once, on the main thread) whether frames will come.
    func start(fps: Int, done: @escaping (Bool) -> Void)
    func stop()
}

enum FrameSize {
    /// The longest side a picture is sent at.
    static let maxSide = 1280

    /// `pixels` scaled to fit `maxSide`, both sides even. Pure.
    static func fit(_ pixels: CGSize, maxSide: Int = FrameSize.maxSide) -> (Int, Int) {
        let longest = max(pixels.width, pixels.height)
        guard longest >= 2 else { return (2, 2) }
        let s = min(1, CGFloat(maxSide) / longest)
        let w = max(2, Int((pixels.width * s).rounded(.down)) & ~1)
        let h = max(2, Int((pixels.height * s).rounded(.down)) & ~1)
        return (w, h)
    }
}

/// The app's windows drawn into a bitmap on the main thread.
final class SnapshotCapture: Capture {
    private weak var host: Host?
    private var timer: Timer?
    private var ctx: CGContext?

    init(host: Host) { self.host = host }

    func start(fps: Int, done: @escaping (Bool) -> Void) {
        let t = Timer(timeInterval: 1.0 / Double(max(1, min(30, fps))), repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        done(true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ctx = nil
    }

    private func tick() {
        guard let host, UIApplication.shared.applicationState == .active, let scene = Indicator.scene() else { return }
        // The masks measured now, for this very picture; nothing while
        // another process's UI is presented.
        guard MainActor.assumeIsolated({ host.prepareFrame() }) else { return }
        let windows = scene.windows.filter { !($0 is IndicatorWindow) && !$0.isHidden && $0.alpha > 0.01 }.sorted { $0.windowLevel < $1.windowLevel }
        guard let screen = windows.first?.screen ?? Optional(scene.screen) else { return }
        let picture = screen.bounds
        let (w, h) = FrameSize.fit(CGSize(width: picture.width * screen.scale, height: picture.height * screen.scale))
        if ctx == nil || ctx?.width != w || ctx?.height != h {
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        }
        guard let ctx, let data = ctx.data else { return }
        ctx.saveGState()
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // UIKit's top-left origin, in points.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / picture.width, y: -CGFloat(h) / picture.height)
        UIGraphicsPushContext(ctx)
        for win in windows {
            let r = win.convert(win.bounds, to: screen.coordinateSpace)
            win.drawHierarchy(in: r, afterScreenUpdates: false)
        }
        UIGraphicsPopContext()
        ctx.restoreGState()
        _ = host.push(UnsafeRawPointer(data), width: w, height: h, stride: ctx.bytesPerRow, picture: picture)
    }
}

/// ReplayKit's in-app capture, scaled and converted to BGRA off the main thread.
final class ReplayKitCapture: Capture {
    private weak var host: Host?
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let interval = Locked(1.0 / 15)
    private var last: CFTimeInterval = 0
    private var buffer: CVPixelBuffer?
    private var running = false

    init(host: Host) { self.host = host }

    func start(fps: Int, done: @escaping (Bool) -> Void) {
        let rec = RPScreenRecorder.shared()
        interval.set(1.0 / Double(max(1, min(30, fps))))
        guard rec.isAvailable else { return done(false) }
        rec.isMicrophoneEnabled = false
        running = true
        rec.startCapture(handler: { [weak self] sample, type, error in
            guard type == .video, error == nil else { return }
            self?.frame(sample)
        }, completionHandler: { error in
            DispatchQueue.main.async { done(error == nil) }
        })
    }

    func stop() {
        guard running else { return }
        running = false
        RPScreenRecorder.shared().stopCapture { _ in }
    }

    /// On ReplayKit's queue.
    private func frame(_ sample: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard now - last >= interval.get * 0.9, let px = CMSampleBufferGetImageBuffer(sample), let host else { return }
        last = now
        // On the main thread, for this frame: the masks measured now, whether
        // a frame may go at all, and the app's interface orientation and
        // screen size.
        let main = DispatchQueue.main.sync { () -> (Bool, UIInterfaceOrientation, CGSize) in
            let scene = Indicator.scene()
            return (MainActor.assumeIsolated { host.prepareFrame() }, scene?.interfaceOrientation ?? .portrait, scene?.screen.bounds.size ?? UIScreen.main.bounds.size)
        }
        guard main.0 else { return }
        let attached = (CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber).flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) }
        let buffer0 = CGSize(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
        var img = CIImage(cvPixelBuffer: px).oriented(Self.orientation(attached: attached, buffer: buffer0, interface: main.1))
        // The picture is the screen in the app's interface orientation, the
        // shape of this oriented frame (mask rects are in its points).
        let picture = Self.picture(frame: img.extent.size, screen: main.2)
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
        let (w, h) = FrameSize.fit(img.extent.size)
        img = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
        if buffer == nil || CVPixelBufferGetWidth(buffer!) != w || CVPixelBufferGetHeight(buffer!) != h {
            buffer = nil
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        }
        guard let out = buffer else { return }
        ci.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(out) else { return }
        _ = host.push(UnsafeRawPointer(base), width: w, height: h, stride: CVPixelBufferGetBytesPerRow(out), picture: picture)
    }

    /// How to turn ReplayKit's buffer upright for the app's interface. The
    /// attachment (the device's orientation) is used when it agrees with the
    /// interface's shape; when it does not (an app locked to portrait on a
    /// rotated device, or no attachment) the interface orientation decides,
    /// so the picture always matches the app's window coordinates. Pure.
    static func orientation(attached: CGImagePropertyOrientation?, buffer: CGSize, interface: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        let wantLandscape = interface.isLandscape
        if let a = attached {
            let swaps = [.left, .right, .leftMirrored, .rightMirrored].contains(a)
            let landscape = swaps ? buffer.height > buffer.width : buffer.width > buffer.height
            if landscape == wantLandscape { return a }
        }
        let bufferLandscape = buffer.width > buffer.height
        switch interface {
        case .landscapeRight: return bufferLandscape ? .up : .left
        case .landscapeLeft: return bufferLandscape ? .down : .right
        case .portraitUpsideDown: return bufferLandscape ? .left : .down
        default: return bufferLandscape ? .right : .up
        }
    }

    /// The picture rect for an upright frame of `frame` pixels: the screen
    /// (points) in the same shape. Pure.
    static func picture(frame: CGSize, screen: CGSize) -> CGRect {
        let long = max(screen.width, screen.height), short = min(screen.width, screen.height)
        return frame.width > frame.height ? CGRect(x: 0, y: 0, width: long, height: short) : CGRect(x: 0, y: 0, width: short, height: long)
    }
}

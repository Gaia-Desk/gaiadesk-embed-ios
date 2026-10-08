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
    private let picture = Locked(CGRect.zero)
    private let interval = Locked(1.0 / 15)
    private var last: CFTimeInterval = 0
    private var buffer: CVPixelBuffer?
    private var running = false

    init(host: Host) { self.host = host }

    func start(fps: Int, done: @escaping (Bool) -> Void) {
        let rec = RPScreenRecorder.shared()
        interval.set(1.0 / Double(max(1, min(30, fps))))
        picture.set(Indicator.scene()?.screen.bounds ?? UIScreen.main.bounds)
        guard rec.isAvailable else { return done(false) }
        rec.isMicrophoneEnabled = false
        running = true
        rec.startCapture(handler: { [weak self] sample, type, error in
            guard type == .video, error == nil else { return }
            self?.frame(sample)
        }, completionHandler: { error in
            DispatchQueue.main.async { done(error == nil) }
        })
        // Rotation changes the picture's shape.
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.picture.set(Indicator.scene()?.screen.bounds ?? UIScreen.main.bounds)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        NotificationCenter.default.removeObserver(self)
        RPScreenRecorder.shared().stopCapture { _ in }
    }

    /// On ReplayKit's queue.
    private func frame(_ sample: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard now - last >= interval.get * 0.9, let px = CMSampleBufferGetImageBuffer(sample), let host else { return }
        last = now
        var img = CIImage(cvPixelBuffer: px)
        if let o = CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: o.uint32Value) {
            img = img.oriented(orientation)
        }
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
        _ = host.push(UnsafeRawPointer(base), width: w, height: h, stride: CVPixelBufferGetBytesPerRow(out), picture: picture.get)
    }
}

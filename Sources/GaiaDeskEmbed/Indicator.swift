// The "Sharing with <company> · Stop" indicator: a window of its own above
// everything the app draws (and above the keyboard), transparent and
// touch-through except for its pill. It also draws the agent's pointer and
// the "tap here" hints of guided mode. Main thread only.
//
// The library sends frames only while `isVisible()` says so (polled four
// times a second by `Host`): the pill is in its window, nothing of the app's
// covers it, its window is shown, and the app is active in the foreground.
// The window's title is never "GaiaDesk" (`accessibilityLabel` included).

import UIKit

/// The indicator's window: touches pass through everywhere but the pill.
final class IndicatorWindow: UIWindow {
    weak var pill: UIView?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let pill, !pill.isHidden else { return nil }
        let p = convert(point, to: pill)
        return pill.point(inside: p, with: event) ? pill.hitTest(p, with: event) : nil
    }
}

final class Indicator: NSObject {
    /// Above alerts and the keyboard's windows.
    static let level = UIWindow.Level(rawValue: 10_000_010)

    private(set) var window: IndicatorWindow?
    private let pill = UIView()
    private let label = UILabel()
    private let stopButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let overlay = UIView()
    private var pointer: UIView?
    private var pointerHide: DispatchWorkItem?
    let title: String
    let guided: Bool
    var onStop: (() -> Void)?
    var onPause: ((Bool) -> Void)?

    var status: String = "" {
        didSet { label.text = status.isEmpty ? title : status }
    }

    var paused = false {
        didSet { pauseButton.setTitle(paused ? "Allow control" : "Pause control", for: .normal) }
    }

    init(title: String, guided: Bool) {
        self.title = title
        self.guided = guided
        super.init()
    }

    func show() {
        guard let scene = Indicator.scene() else { return }
        let w = IndicatorWindow(windowScene: scene)
        w.windowLevel = Indicator.level
        w.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = true
        w.rootViewController = root
        overlay.frame = root.view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        root.view.addSubview(overlay)
        buildPill(in: root.view)
        w.pill = pill
        w.isHidden = false
        window = w
    }

    private func buildPill(in view: UIView) {
        pill.backgroundColor = UIColor(red: 0.80, green: 0.10, blue: 0.12, alpha: 0.96)
        pill.layer.cornerRadius = 18
        pill.layer.shadowOpacity = 0.25
        pill.layer.shadowRadius = 6
        pill.layer.shadowOffset = CGSize(width: 0, height: 2)
        pill.accessibilityIdentifier = "gaiadesk.indicator"
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.accessibilityIdentifier = "gaiadesk.indicator.status"
        let dot = UIView()
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        for (b, t, id) in [(stopButton, "Stop", "gaiadesk.indicator.stop"), (pauseButton, "Pause control", "gaiadesk.indicator.pause")] {
            b.setTitle(t, for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
            b.backgroundColor = UIColor.white.withAlphaComponent(0.22)
            b.layer.cornerRadius = 12
            b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
            b.accessibilityIdentifier = id
        }
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        pauseButton.isHidden = !guided
        let row = UIStackView(arrangedSubviews: [dot, label, pauseButton, stopButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(row)
        view.addSubview(pill)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: pill.topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -5),
            pill.topAnchor.constraint(equalTo: g.topAnchor, constant: 4),
            pill.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: g.leadingAnchor, constant: 8),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor, constant: -8),
        ])
    }

    @objc private func stopTapped() { onStop?() }

    @objc private func pauseTapped() {
        paused.toggle()
        onPause?(paused)
    }

    /// Keep it shown and on top.
    func raise() {
        guard let w = window else { return }
        w.isHidden = false
        w.windowLevel = Indicator.level
        w.alpha = 1
    }

    func close() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    /// What the library's frames depend on.
    func isVisible() -> Bool {
        guard let w = window, !w.isHidden, w.alpha > 0.9, pill.window === w, !pill.isHidden, pill.alpha > 0.9 else { return false }
        guard UIApplication.shared.applicationState == .active, let scene = w.windowScene, scene.activationState == .foregroundActive else { return false }
        let frame = pill.convert(pill.bounds, to: w)
        guard frame.width >= 40, frame.height >= 20, w.bounds.contains(frame) else { return false }
        return Indicator.uncovered(frame, in: w, among: scene.windows)
    }

    /// No other window above `w` covers `frame` (`w`'s coordinates). Pure
    /// apart from UIKit's geometry.
    static func uncovered(_ frame: CGRect, in w: UIWindow, among windows: [UIWindow]) -> Bool {
        for other in windows where other !== w && !other.isHidden && other.alpha > 0.01 && other.windowLevel >= w.windowLevel {
            if other.convert(other.bounds, to: w).intersects(frame) { return false }
        }
        return true
    }

    // MARK: guided-mode drawing (window points == the app window's)

    func showPointer(at p: CGPoint) {
        let v = pointer ?? {
            let d = UIView(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
            d.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
            d.layer.cornerRadius = 9
            d.layer.borderColor = UIColor.white.cgColor
            d.layer.borderWidth = 2
            d.isUserInteractionEnabled = false
            d.accessibilityIdentifier = "gaiadesk.pointer"
            overlay.addSubview(d)
            pointer = d
            return d
        }()
        v.center = p
        v.isHidden = false
        pointerHide?.cancel()
        let hide = DispatchWorkItem { [weak v] in v?.isHidden = true }
        pointerHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: hide)
    }

    /// A pulsing ring with `text` beside it, for a few seconds.
    func showRing(at p: CGPoint, text: String?) {
        let ring = UIView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        ring.center = p
        ring.layer.cornerRadius = 28
        ring.layer.borderWidth = 4
        ring.layer.borderColor = UIColor.systemOrange.cgColor
        ring.isUserInteractionEnabled = false
        ring.accessibilityIdentifier = "gaiadesk.hint"
        overlay.addSubview(ring)
        var views: [UIView] = [ring]
        if let text {
            let l = UILabel()
            l.text = " \(text) "
            l.font = .systemFont(ofSize: 14, weight: .bold)
            l.textColor = .white
            l.backgroundColor = .systemOrange
            l.layer.cornerRadius = 6
            l.clipsToBounds = true
            l.sizeToFit()
            l.center = CGPoint(x: p.x, y: p.y + 46)
            overlay.addSubview(l)
            views.append(l)
        }
        UIView.animate(withDuration: 0.6, delay: 0, options: [.autoreverse, .repeat, .allowUserInteraction]) {
            ring.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            views.forEach { $0.removeFromSuperview() }
        }
    }

    /// Whether a point (window coordinates) is on the pill.
    func onPill(_ p: CGPoint) -> Bool {
        guard let w = window else { return false }
        return pill.convert(pill.bounds, to: w).insetBy(dx: -8, dy: -8).contains(p)
    }

    static func scene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

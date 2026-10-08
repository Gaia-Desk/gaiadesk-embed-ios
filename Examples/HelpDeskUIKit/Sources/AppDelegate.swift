// HelpDeskUIKit: a UIKit app ("Acme Bank") with a Get help button.
//
// Your backend creates the support session (POST /v1/support/sessions with a
// secret key) and hands the app the embed token; here it comes from the text
// field or the launch environment. The red "card number" view is masked: your
// support team sees it painted black. The Buy button is a UIButton, so in a
// guided session the agent's click presses it (iOS delivers guided input to
// UIKit controls through their public actions).
//
// Test hooks (environment; `xcrun simctl launch` passes SIMCTL_CHILD_*):
//   GAIADESK_EMBED_TOKEN, GAIADESK_SERVER     the session
//   GAIADESK_DEMO_AUTOSTART=1                 press Get help at launch
//   GAIADESK_DEMO_TEST_CONSENT=1              answer the consent dialog "Share" (tests only)
//   GAIADESK_DEMO_GUIDED=1                    allow guided input
//   GAIADESK_DEMO_CAPTURE=snapshot            capture by snapshot (the Simulator has no ReplayKit)
//   GAIADESK_DEMO_CMD=1                       run stop|pause|resume written to <app tmp>/gaiadesk-demo-cmd
// URLs: helpdeskuikit://stop, helpdeskuikit://pause, helpdeskuikit://resume.
// Every event is printed to stdout as one JSON line.

import GaiaDeskEmbed
import UIKit

let env = ProcessInfo.processInfo.environment

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = DeskViewController()
        w.makeKeyAndVisible()
        window = w
        watchDemoCommands()
        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        demoCommand(url.host ?? "")
    }
}

/// stop | pause | resume, for the running session.
@MainActor @discardableResult
func demoCommand(_ what: String) -> Bool {
    guard let help = GaiaDeskEmbed.current else { return false }
    switch what {
    case "stop": help.stop()
    case "pause": help.setPaused(true)
    case "resume": help.setPaused(false)
    default: return false
    }
    emit(["type": "demo_cmd", "cmd": what])
    return true
}

/// Tests (GAIADESK_DEMO_CMD=1): a command written to <tmp>/gaiadesk-demo-cmd
/// is run and the file removed (the Simulator asks before opening a URL).
@MainActor
func watchDemoCommands() {
    guard env["GAIADESK_DEMO_CMD"] == "1" else { return }
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gaiadesk-demo-cmd")
    try? FileManager.default.removeItem(at: file)
    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
        guard let cmd = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        Task { @MainActor in demoCommand(cmd.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

final class DeskViewController: UIViewController {
    var help: GaiaDeskEmbed?
    let token = UITextField()
    let status = UILabel()
    let card = UIView()
    let blue = UIView()
    let buy = UIButton(type: .system)
    var bought = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGreen
        let title = UILabel(frame: CGRect(x: 20, y: 70, width: 340, height: 30))
        title.text = "Acme Bank"
        title.font = .boldSystemFont(ofSize: 26)
        view.addSubview(title)
        card.frame = CGRect(x: 20, y: 130, width: 220, height: 120)
        card.backgroundColor = .systemRed
        let cardLabel = UILabel(frame: CGRect(x: 10, y: 50, width: 200, height: 20))
        cardLabel.text = "Card 4242 4242 4242 4242"
        card.addSubview(cardLabel)
        view.addSubview(card)
        blue.frame = CGRect(x: 250, y: 130, width: 120, height: 120)
        blue.backgroundColor = .systemBlue
        view.addSubview(blue)
        buy.frame = CGRect(x: 20, y: 280, width: 160, height: 50)
        buy.setTitle("Buy", for: .normal)
        buy.backgroundColor = .white
        buy.addTarget(self, action: #selector(buyPressed), for: .touchUpInside)
        view.addSubview(buy)
        token.frame = CGRect(x: 20, y: 360, width: 340, height: 40)
        token.borderStyle = .roundedRect
        token.placeholder = "gdemb_… (from your backend)"
        token.text = env["GAIADESK_EMBED_TOKEN"]
        view.addSubview(token)
        let get = UIButton(type: .system)
        get.frame = CGRect(x: 20, y: 420, width: 160, height: 50)
        get.setTitle("Get help", for: .normal)
        get.backgroundColor = .white
        get.addTarget(self, action: #selector(getHelp), for: .touchUpInside)
        view.addSubview(get)
        status.frame = CGRect(x: 20, y: 490, width: 340, height: 60)
        status.numberOfLines = 0
        status.text = "Press Get help to share this app with Acme support."
        view.addSubview(status)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let box = { (v: UIView) -> [Double] in
            let r = GaiaDeskEmbed.rectInWindow(v) ?? .zero
            return [r.origin.x, r.origin.y, r.width, r.height].map { Double($0) }
        }
        let b = view.window?.bounds ?? .zero
        emit(["type": "demo", "pid": Int(ProcessInfo.processInfo.processIdentifier), "build": GaiaDeskEmbed.buildInfo, "frame": [Double(b.width), Double(b.height)], "card": box(card), "blue": box(blue), "buy": box(buy)])
        if env["GAIADESK_DEMO_AUTOSTART"] == "1" { getHelp() }
    }

    @objc func buyPressed() {
        bought += 1
        emit(["bought": bought])
    }

    @objc func getHelp() {
        Task { @MainActor in
            let guided = env["GAIADESK_DEMO_GUIDED"] == "1"
            let agreed = env["GAIADESK_DEMO_TEST_CONSENT"] == "1" ? true : await GaiaDeskEmbed.requestConsent(company: "Acme", guided: guided)
            guard agreed else { return }
            let method: GaiaDeskEmbed.CaptureMethod = env["GAIADESK_DEMO_CAPTURE"] == "snapshot" ? .snapshot : .replayKit
            let server = env["GAIADESK_SERVER"].flatMap(URL.init(string:))
            let masked = [GaiaDeskEmbed.rectInWindow(card)].compactMap { $0 }
            do {
                help = try GaiaDeskEmbed.start(.init(embedToken: token.text ?? "", company: "Acme", server: server, guided: guided, maskedRects: masked, captureMethod: method), consentGranted: agreed) { [weak self] e in
                    self?.on(e)
                }
            } catch let e as GaiaDeskEmbedError {
                emit(["start_error": e.code, "message": e.message])
                status.text = "Could not start: \(e.message)"
            } catch {}
        }
    }

    func on(_ e: GaiaDeskEmbed.Event) {
        switch e {
        case let .state(s): emit(["type": "state", "state": s])
        case let .code(c, sid, mode):
            emit(["type": "code", "code": c, "session_id": sid, "mode": mode])
            status.text = "Your support code: \(c)"
        case let .joined(agent): emit(["type": "joined", "agent": agent ?? NSNull()])
        case .left: emit(["type": "left"])
        case let .control(allowed): emit(["type": "control", "allowed": allowed])
        case let .action(a, applied, reason): emit(["type": "action", "action": a, "applied": applied, "reason": reason ?? NSNull()])
        case let .error(code, message): emit(["type": "error", "code": code, "message": message])
        case let .ended(reason):
            emit(["type": "ended", "reason": reason])
            status.text = "Sharing ended (\(reason))."
            help = nil
        }
    }
}

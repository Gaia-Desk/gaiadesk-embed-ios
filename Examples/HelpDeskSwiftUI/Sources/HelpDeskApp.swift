// HelpDeskSwiftUI: a SwiftUI app ("Acme Bank") with a Get help button.
//
// The card is marked `.gaiaDeskMasked()`: support sees it painted black, from
// the first frame. SwiftUI views are not UIKit controls, so in a guided
// session iOS gives the agent a pointer and "Tap here" hints on them (the
// customer taps), and real delivery for text fields' typing and scrolling of
// UIKit-backed scroll views.
//
// Test hooks: the same environment as HelpDeskUIKit (GAIADESK_EMBED_TOKEN,
// GAIADESK_SERVER, GAIADESK_DEMO_AUTOSTART, GAIADESK_DEMO_TEST_CONSENT,
// GAIADESK_DEMO_GUIDED, GAIADESK_DEMO_CAPTURE=snapshot, GAIADESK_DEMO_CMD) and URLs
// helpdeskswiftui://stop|pause|resume. Events are printed as JSON lines.

import GaiaDeskEmbed
import SwiftUI

let env = ProcessInfo.processInfo.environment

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}

@main
struct HelpDeskApp: App {
    @StateObject private var model = HelpModel()

    var body: some Scene {
        WindowGroup {
            DeskView()
                .environmentObject(model)
                .onOpenURL { url in model.control(url.host ?? "") }
                .onAppear { model.watchCommands() }
        }
    }
}

@MainActor
final class HelpModel: ObservableObject {
    @Published var token = env["GAIADESK_EMBED_TOKEN"] ?? ""
    @Published var status = "Press Get help to share this app with Acme support."
    @Published var bought = 0
    private var help: GaiaDeskEmbed?

    func getHelp() async {
        let guided = env["GAIADESK_DEMO_GUIDED"] == "1"
        let agreed = env["GAIADESK_DEMO_TEST_CONSENT"] == "1" ? true : await GaiaDeskEmbed.requestConsent(company: "Acme", guided: guided)
        guard agreed else { return }
        let method: GaiaDeskEmbed.CaptureMethod = env["GAIADESK_DEMO_CAPTURE"] == "snapshot" ? .snapshot : .replayKit
        do {
            help = try GaiaDeskEmbed.start(.init(embedToken: token, company: "Acme", server: env["GAIADESK_SERVER"].flatMap(URL.init(string:)), guided: guided, captureMethod: method), consentGranted: agreed) { [weak self] e in
                self?.on(e)
            }
        } catch let e as GaiaDeskEmbedError {
            emit(["start_error": e.code, "message": e.message])
            status = "Could not start: \(e.message)"
        } catch {}
    }

    func control(_ what: String) {
        switch what {
        case "stop": help?.stop()
        case "pause": help?.setPaused(true)
        case "resume": help?.setPaused(false)
        default: return
        }
        emit(["type": "demo_cmd", "cmd": what])
    }

    private var watching = false

    /// Tests (GAIADESK_DEMO_CMD=1): a command written to <tmp>/gaiadesk-demo-cmd
    /// is run and the file removed (the Simulator asks before opening a URL).
    func watchCommands() {
        guard env["GAIADESK_DEMO_CMD"] == "1", !watching else { return }
        watching = true
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gaiadesk-demo-cmd")
        try? FileManager.default.removeItem(at: file)
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let cmd = try? String(contentsOf: file, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: file)
            Task { @MainActor in self?.control(cmd.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    func on(_ e: GaiaDeskEmbed.Event) {
        switch e {
        case let .state(s): emit(["type": "state", "state": s])
        case let .code(c, sid, mode):
            emit(["type": "code", "code": c, "session_id": sid, "mode": mode])
            status = "Your support code: \(c)"
        case let .joined(agent): emit(["type": "joined", "agent": agent ?? NSNull()])
        case .left: emit(["type": "left"])
        case let .control(allowed): emit(["type": "control", "allowed": allowed])
        case let .action(a, applied, reason): emit(["type": "action", "action": a, "applied": applied, "reason": reason ?? NSNull()])
        case let .error(code, message): emit(["type": "error", "code": code, "message": message])
        case let .ended(reason):
            emit(["type": "ended", "reason": reason])
            status = "Sharing ended (\(reason))."
            help = nil
        }
    }
}

struct DeskView: View {
    @EnvironmentObject var model: HelpModel
    @State private var boxes: [String: CGRect] = [:]

    var body: some View {
        GeometryReader { _ in
            VStack(alignment: .leading, spacing: 16) {
                Text("Acme Bank").font(.largeTitle.bold())
                HStack(spacing: 10) {
                    ZStack {
                        Color.red
                        Text("Card 4242 4242 4242 4242").font(.footnote)
                    }
                    .frame(width: 220, height: 120)
                    .gaiaDeskMasked()
                    .background(probe("card"))
                    Color.blue.frame(width: 120, height: 120).background(probe("blue"))
                }
                Button("Buy") {
                    model.bought += 1
                    emit(["bought": model.bought])
                }
                .frame(width: 160, height: 50)
                .background(Color.white)
                .background(probe("buy"))
                TextField("gdemb_… (from your backend)", text: $model.token)
                    .textFieldStyle(.roundedBorder)
                Button("Get help") { Task { await model.getHelp() } }
                    .frame(width: 160, height: 50)
                    .background(Color.white)
                Text(model.status)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.green.ignoresSafeArea())
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let r = { (k: String) in boxes[k].map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? [] }
                    let size = UIScreen.main.bounds.size
                    emit(["type": "demo", "pid": Int(ProcessInfo.processInfo.processIdentifier), "build": GaiaDeskEmbed.buildInfo, "frame": [Double(size.width), Double(size.height)], "card": r("card"), "blue": r("blue"), "buy": r("buy")])
                    if env["GAIADESK_DEMO_AUTOSTART"] == "1" { Task { await model.getHelp() } }
                }
            }
        }
    }

    /// Records a view's frame in window points (for the end-to-end test).
    func probe(_ key: String) -> some View {
        GeometryReader { g in
            Color.clear.onAppear { boxes[key] = g.frame(in: .global) }
        }
    }
}

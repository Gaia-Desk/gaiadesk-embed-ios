# GaiaDeskEmbed (iOS)

A **"Get help" button for your iPhone and iPad app**. Your customer taps it and agrees; **your app's
screen** is shared with **your** support team, who see it in the GaiaDesk console's Support page and,
if you allow it, guide them through it.

- Swift Package (and CocoaPod) wrapping `libgaiadesk_embed`, a prebuilt static XCFramework
  (device arm64; simulator arm64 + x86_64). iOS 15+.
- **Consent first**: the library refuses to start until your user has agreed. Use
  `requestConsent` (an alert with the right wording) or your own dialog.
- **Only your app, always.** ReplayKit's in-app capture (iOS itself limits it to your app, asks the
  user once and shows its own recording indication) or a snapshot of your app's own windows. Other
  apps, the Home Screen and system UI are never captured; sharing pauses when your app leaves the
  foreground. (ReplayKit's system-wide broadcast is not used.)
- A visible **"Sharing with Acme · Stop"** indicator for as long as anything is shared. The library
  sends frames only while the indicator reports itself on screen, unobscured, with your app active.
- **Mask** card numbers, balances, anything: painted black by the library *before* a frame is
  encoded. Masks fail closed.
- **View-only by default.** Guided mode (opt-in, see below) is delivered inside your app through
  public UIKit API only.
- No install, no extension, nothing written to disk.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/Gaia-Desk/gaiadesk-embed-ios.git", from: "0.1.0"),
// target:
.product(name: "GaiaDeskEmbed", package: "gaiadesk-embed-ios"),
```

CocoaPods: `pod 'GaiaDeskEmbed', '~> 0.1'`.

SwiftPM downloads the native library (`GaiaDeskEmbedFFI.xcframework`) from this repository's release
and checks it against the checksum in `Package.swift`. To build against a local copy
(`scripts/fetch-binary.sh 0.1.0` puts the release's in `Frameworks/`), set
`GAIADESK_EMBED_LOCAL_BINARY=1`.

## Quick start

Your backend creates a support session with a secret API key (scope `support`) and hands the app
its `embed_token`; the session's `mode` (`view` or `cobrowse`) is your backend's choice:

```sh
curl -s -X POST https://api.gaiadesk.net/v1/support/sessions \
  -H "Authorization: Bearer $GAIADESK_API_KEY" -H "Content-Type: application/json" \
  -d '{"mode": "view", "customer": {"name": "Ada", "plan": "pro"}}'
# → {"id": "ss_…", "join_code": "123456789", "embed_token": "gdemb_…", …}
```

(Never ship a key in the app: the token comes from your backend.)

```swift
import GaiaDeskEmbed

@MainActor func getHelp(token: String) async {
    guard await GaiaDeskEmbed.requestConsent(company: "Acme") else { return }
    do {
        help = try GaiaDeskEmbed.start(
            .init(embedToken: token, company: "Acme", maskedRects: [GaiaDeskEmbed.rectInWindow(cardView)].compactMap { $0 }),
            consentGranted: true
        ) { event in
            switch event {
            case let .code(code, _, _): print("support code", code)   // read it to the agent
            case let .joined(agent): print(agent ?? "an agent", "is viewing")
            case let .ended(reason): print("ended:", reason)
            default: break
            }
        }
    } catch let e as GaiaDeskEmbedError {
        print("could not start:", e.code, e.message)
    } catch {}
}
```

SwiftUI: mark sensitive views with `.gaiaDeskMasked()`; they are masked from the first frame and
follow their view as it moves.

```swift
Text(card.number).gaiaDeskMasked()
```

### Configuration

| Field | |
|---|---|
| `embedToken` | `gdemb_…`, from your backend |
| `company` | shown on the consent dialog and the indicator |
| `server` | default `https://gaiadesk.net` |
| `guided` | `false` (default). `true` allows guided input in a `cobrowse` session |
| `fps` | 1–30 (default 15) |
| `maskedRects` | regions painted out from the first frame: your key window's coordinates, in points |
| `captureMethod` | `.replayKit` (default) or `.snapshot` (no system prompt; misses video/Metal; the Simulator's only option) |

### Masking

Pass the regions you know at start (`rectInWindow(_:)` turns a view into one) or mark SwiftUI views
`.gaiaDeskMasked()`: an agent can join straight away, and only start-time masks are guaranteed to
cover the first frame. Later, `setMaskedViews(_:)` / `setMaskedRects(_:)` replace the set (marked
SwiftUI views are always added). If the app's window cannot be located, the whole picture is
painted out.

### Guided mode

Only when your app passes `guided: true` **and** your backend created the session as `cobrowse`;
your customer can pause it from the indicator (or you call `setPaused(true)`). **On iOS guided mode
is partial**, because iOS has no public way to synthesise a touch:

| The agent | What happens in your app |
|---|---|
| clicks a `UIControl` | its action fires (buttons: `touchUpInside`/`primaryActionTriggered`; switches toggle; segmented controls select; text fields focus) |
| clicks a table/collection cell | it is selected through your delegate |
| clicks anything else (SwiftUI views, custom gestures, web content) | your customer sees a **"Tap here"** ring at that spot; the agent is told `hint_shown` |
| scrolls | the `UIScrollView` under the point scrolls |
| types / presses Enter, Backspace, arrows, Home, End, Escape | delivered to the first responder |
| moves the pointer / highlights | a pointer dot / ring is drawn over your app |

A click on the indicator, or on a masked region, or while your app is not active is refused. The
console tells the agent it is guiding an iPhone/iPad app with partial control.

### Events

| Event | |
|---|---|
| `.state(s)` | `starting`, `waiting`, `connected`, `ended` |
| `.code(code, sessionId:, mode:)` | registered; `code` is what the agent joins with |
| `.joined(agent:)` / `.left` | an agent joined / left |
| `.control(allowed:)` | guided input paused or resumed |
| `.action(_, applied:, reason:)` | a guided request and its outcome (`view_only`, `control_paused`, `masked`, `outside_app`, `not_focused`, `embed_ui`, `hint_shown`, `not_editable`, …) |
| `.error(code:, message:)` | e.g. `capture_failed`, `connect_failed`, `indicator_unavailable` |
| `.ended(reason:)` | `stopped` (the customer), `app_stopped`, `disconnected`, `expired`, `error` — always last |

Events arrive on the main queue. One session at a time (a second `start` throws `busy`).

## Examples

`Examples/HelpDeskExamples.xcodeproj` (generated from `Examples/project.yml` with XcodeGen) has two
apps, "Acme Bank" in **UIKit** (`HelpDeskUIKit`) and in **SwiftUI** (`HelpDeskSwiftUI`), each with a
masked card, a Buy button and Get help. Their test hooks (environment variables, `helpdesk*://stop`
URLs) drive the GaiaDesk end-to-end test in the Simulator.

## Tests

```sh
export GAIADESK_EMBED_LOCAL_BINARY=1   # with Frameworks/GaiaDeskEmbedFFI.xcframework in place
xcodebuild test -project Examples/HelpDeskExamples.xcodeproj -scheme GaiaDeskEmbedTests \
  -destination 'platform=iOS Simulator,name=iPhone 17'      # hosted in an app: every test runs
xcodebuild test -scheme GaiaDeskEmbed -destination 'platform=iOS Simulator,name=iPhone 17'
                                       # hostless: the two UIKit-delivery tests skip
```

Without Xcode's iOS platform installed, `scripts/build-sim.sh --test` builds and runs the same suite
with swiftc.

## Licence

The Swift sources here are MIT (`LICENSE`). The prebuilt `libgaiadesk_embed` binary is licensed
under the GaiaDesk Native Binary Licence (`LICENSE-BINARY`): free to use in your apps, linked into
them, unmodified.

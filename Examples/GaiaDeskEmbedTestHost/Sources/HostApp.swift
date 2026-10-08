// The app the GaiaDeskEmbedTests bundle runs inside under `xcodebuild test`
// (TEST_HOST): UIKit delivers control actions and first responder only in a
// real app's window scene. It shows one empty window; XCTest does the rest.
// (scripts/build-sim.sh --test uses Tests/TestHost instead, which runs the
// suite itself.)

import UIKit

@main
final class HostApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = UIViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

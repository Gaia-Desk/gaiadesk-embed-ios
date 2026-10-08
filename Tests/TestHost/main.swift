// Runs GaiaDeskEmbedTests inside a real UIApplication in the iOS Simulator,
// for machines where `xcodebuild test` cannot reach a simulator (Xcode 26
// without its iOS 26 platform download): scripts/build-sim.sh --test builds
// this host with the tests linked in and runs it. Prints XCTest's report and
// one last line, `GAIADESK-TESTS passed=<n> failed=<n>`, then exits.

import UIKit
import XCTest

final class HostDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = UIViewController()
        w.makeKeyAndVisible()
        window = w
        DispatchQueue.main.async {
            let suite = XCTestSuite.default
            suite.run()
            let run = suite.testRun!
            print("GAIADESK-TESTS passed=\(run.executionCount - run.totalFailureCount) failed=\(run.totalFailureCount) skipped=\(run.skipCount)")
            fflush(stdout)
            exit(run.hasSucceeded ? 0 : 1)
        }
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(HostDelegate.self))

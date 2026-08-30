import Foundation
import XCTest

/// The test host is `OmniAgent.app` itself, so `UserDefaults.standard` inside
/// a test is the developer's real `digital.bruno.omniagent` domain — the one
/// the installed app reads its launch gate (`auth.signedIn`), sidebar state and
/// window frames from. One test signing a model out on the standard domain
/// signed the real install out on every suite run (2026-08-30). This is the
/// bundle-wide backstop: snapshot the domain before the first test, put it
/// back after the last one. Tests should still inject throwaway defaults; this
/// only makes forgetting to cost nothing.
///
/// Registered as the test bundle's `NSPrincipalClass` (see the test target's
/// `INFOPLIST_KEY_NSPrincipalClass`), which XCTest instantiates on load.
@objc(RealPreferencesGuard)
final class RealPreferencesGuard: NSObject, XCTestObservation {
    static let domain = Bundle.main.bundleIdentifier ?? "digital.bruno.omniagent"
    private var snapshot: [String: Any]?

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        snapshot = UserDefaults.standard.persistentDomain(forName: Self.domain)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        guard let snapshot else { return }
        UserDefaults.standard.setPersistentDomain(snapshot, forName: Self.domain)
    }
}

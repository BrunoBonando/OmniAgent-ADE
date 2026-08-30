import XCTest
@testable import OmniAgent

final class WebInspectorPolicyTests: XCTestCase {
    private func defaults(_ value: Bool?) -> UserDefaults {
        let d = UserDefaults(suiteName: "WebInspectorPolicyTests.\(UUID())")!
        if let value { d.set(value, forKey: WebInspectorPolicy.defaultsKey) }
        return d
    }
    func testDebugBuildsAlwaysInspect() {
        XCTAssertTrue(WebInspectorPolicy.isEnabled(defaults: defaults(nil), debugBuild: true))
        XCTAssertTrue(WebInspectorPolicy.isEnabled(defaults: defaults(false), debugBuild: true))
    }
    func testReleaseBuildsInspectOnlyWhenTheDefaultOptsIn() {
        XCTAssertFalse(WebInspectorPolicy.isEnabled(defaults: defaults(nil), debugBuild: false))
        XCTAssertTrue(WebInspectorPolicy.isEnabled(defaults: defaults(true), debugBuild: false))
    }

    /// The tests build under the Debug configuration, so `#if DEBUG` must be
    /// true here. It silently was not: the project defined no
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, which made every `isDebugBuild`
    /// in the app permanently false. This asserts the setting stays.
    func testTheTestHostIsADebugBuild() {
        XCTAssertTrue(WebInspectorPolicy.isDebugBuild)
    }
}

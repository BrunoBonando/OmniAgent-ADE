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
}

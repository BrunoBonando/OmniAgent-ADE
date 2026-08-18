import AppKit
import XCTest

@testable import OmniAgent

/// The FILES tree's single-vs-double press rule, as a pure value. The tree's
/// rows run their own mouse handling, so AppKit's `clickCount` never reaches
/// `activate(_:)` — this is what stands in for it.
final class DoublePressDetectorTests: XCTestCase {
    func testSecondPressWithinIntervalIsDouble() {
        var detector = DoublePressDetector(interval: 0.4)
        XCTAssertFalse(detector.register("/a", at: 10.0))
        XCTAssertTrue(detector.register("/a", at: 10.3))
        XCTAssertFalse(detector.register("/a", at: 10.5), "a recognised double resets")
    }

    func testDifferentTargetResets() {
        var detector = DoublePressDetector(interval: 0.4)
        XCTAssertFalse(detector.register("/a", at: 10.0))
        XCTAssertFalse(detector.register("/b", at: 10.1))
    }

    func testLatePressIsSingle() {
        var detector = DoublePressDetector(interval: 0.4)
        XCTAssertFalse(detector.register("/a", at: 10.0))
        XCTAssertFalse(detector.register("/a", at: 11.0))
    }

    /// A third press right after a double is a *single* on that target again,
    /// not a second double — which is what makes triple-click read as
    /// "double, then single" rather than "double, then double".
    func testTriplePressIsDoubleThenSingle() {
        var detector = DoublePressDetector(interval: 0.4)
        XCTAssertFalse(detector.register("/a", at: 10.0))
        XCTAssertTrue(detector.register("/a", at: 10.1))
        XCTAssertFalse(detector.register("/a", at: 10.2))
        XCTAssertTrue(detector.register("/a", at: 10.3))
    }

    /// The default is the user's own double-click speed, not a hard-coded
    /// number — the tree has to feel like every other list on the machine.
    func testDefaultIntervalIsTheSystemDoubleClickInterval() {
        XCTAssertEqual(DoublePressDetector().interval, NSEvent.doubleClickInterval)
    }
}

import XCTest
@testable import OmniAgent

final class ClaudeUsageLimitsTests: XCTestCase {
    /// The real shape, captured from `claude -p "/usage"` on 2026-08-25.
    private let sample = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 9% used · resets Aug 25 at 2:10pm (Europe/Berlin)
    Current week (all models): 37% used · resets Aug 28 at 11am (Europe/Berlin)
    Current week (Fable): 10% used · resets Aug 28 at 11am (Europe/Berlin)
    """

    func testParsesSessionAndWeek() {
        let limits = ClaudeUsageLimits.parse(sample)
        XCTAssertEqual(limits.sessionPercent, 9)
        XCTAssertEqual(limits.sessionResets, "Aug 25 at 2:10pm")
        XCTAssertEqual(limits.weekPercent, 37)
        XCTAssertEqual(limits.weekResets, "Aug 28 at 11am")
    }

    func testParsesThePerModelWeeklyLine() {
        let limits = ClaudeUsageLimits.parse(sample)
        XCTAssertEqual(limits.modelName, "Fable")
        XCTAssertEqual(limits.modelPercent, 10)
    }

    /// A failed or changed `/usage` must never blank the bar or throw — every
    /// field is optional and garbage yields all-nil.
    func testGarbageYieldsAllNilRatherThanThrowing() {
        let limits = ClaudeUsageLimits.parse("command not found\n")
        XCTAssertNil(limits.sessionPercent)
        XCTAssertNil(limits.weekPercent)
        XCTAssertNil(limits.modelPercent)
    }

    func testEmptyInput() {
        XCTAssertEqual(ClaudeUsageLimits.parse(""), ClaudeUsageLimits.parse("   \n  "))
    }
}

import XCTest

@testable import OmniAgent

/// The allowlist parser. Its whole reason for existing is in
/// `testUnknownTagsInAFenceSurviveUntouched`.
final class PaneAppSystemBlocksTests: XCTestCase {
    func testSplitsARecognisedBlockOutOfProse() {
        let segments = SystemBlockSplitter.split(
            "before\n<system-reminder>\nbe careful\n</system-reminder>\nafter"
        )
        XCTAssertEqual(segments, [
            .prose("before"),
            .system(SystemBlock(kind: .systemReminder, body: "be careful")),
            .prose("after"),
        ])
    }

    func testSplitsATaskNotificationWithNestedChildren() {
        let segments = SystemBlockSplitter.split(
            "<task-notification>\n<task-id>abc</task-id>\n<status>completed</status>\n</task-notification>"
        )
        XCTAssertEqual(segments.count, 1)
        guard case .system(let block) = segments[0] else { return XCTFail("not a system block") }
        XCTAssertEqual(block.kind, .taskNotification)
        XCTAssertTrue(block.body.contains("<task-id>abc</task-id>"))
    }

    /// THE TRAP. Bruno's 528 transcripts contain `<div>` (204), `<path>` (138),
    /// `<string>` (501) and `<private>` (364) — every one of them his own code,
    /// in SVG, HTML and plist under discussion. A generic tag matcher would
    /// silently delete it. Nothing outside the allowlist is ever a block.
    func testUnknownTagsInAFenceSurviveUntouched() {
        let source = """
        here is some svg

        ```xml
        <div class="x">
          <path d="M0 0 L10 10"/>
          <string>value</string>
        </div>
        ```
        """
        XCTAssertEqual(SystemBlockSplitter.split(source), [.prose(source)])
    }

    func testAnUnclosedBlockDegradesToProse() {
        let source = "text\n<system-reminder>\nnever closed"
        XCTAssertEqual(SystemBlockSplitter.split(source), [.prose(source)])
    }

    func testTotalTokensIsRecognised() {
        let segments = SystemBlockSplitter.split("<total_tokens>15000000 tokens left</total_tokens>")
        XCTAssertEqual(segments, [
            .system(SystemBlock(kind: .totalTokens, body: "15000000 tokens left")),
        ])
    }

    func testTextWithNoBlocksIsOneProseSegment() {
        XCTAssertEqual(SystemBlockSplitter.split("just words"), [.prose("just words")])
    }
}

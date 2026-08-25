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
          <group><span>label</span></group>
          <private>secret</private>
        </div>
        ```
        """
        XCTAssertEqual(SystemBlockSplitter.split(source), [.prose(source)])
    }

    /// The allowlist itself, pinned. Every name here was measured in Bruno's
    /// 528 transcripts and every one *not* here was measured too — `<div>`,
    /// `<path>`, `<string>`, `<private>`, `<group>`, `<span>` are his own code
    /// under discussion. Adding a case has to be a deliberate act with this
    /// test in front of you, not a one-line widening nobody reviews.
    func testTheAllowlistIsExactlyTheseSevenNames() {
        XCTAssertEqual(Set(SystemBlockKind.allCases.map(\.rawValue)), [
            "task-notification",
            "system-reminder",
            "command-name",
            "command-message",
            "command-args",
            "local-command-stdout",
            "total_tokens",
        ])
    }

    /// THE TRAP'S SECOND HALF, and the reachable one. The allowlist stops a
    /// generic matcher eating `<div>`; nothing stopped it eating an
    /// **allowlisted** name *quoted inside a fence*, which this repo's own
    /// transcripts are full of. `<total_tokens>` renders as nothing at all,
    /// so it was silently deleted from the middle of the user's code — and
    /// the fence it left behind was unbalanced, so `MarkdownBlock.parse`'s
    /// unterminated-fence rule swallowed the rest of the message.
    func testAnAllowlistedTagInsideAFenceIsNotTornOutOfIt() {
        let source = """
        the harness appends this to every prompt:

        ```text
        <total_tokens>15000000 tokens left</total_tokens>
        <system-reminder>be careful</system-reminder>
        ```

        which is why the count moves.
        """
        XCTAssertEqual(SystemBlockSplitter.split(source), [.prose(source)])
    }

    /// And a real block *after* a fence that quotes one is still folded away:
    /// the fence is skipped over, not treated as the end of the scan.
    func testARealBlockAfterAQuotedOneIsStillRecognised() {
        let source = """
        ```text
        <system-reminder>quoted</system-reminder>
        ```
        <system-reminder>actual</system-reminder>
        """
        let segments = SystemBlockSplitter.split(source)
        XCTAssertEqual(segments.count, 2)
        guard case .prose(let prose) = segments[0] else { return XCTFail("not prose") }
        XCTAssertTrue(prose.contains("<system-reminder>quoted</system-reminder>"), "the fence is intact")
        XCTAssertTrue(prose.hasSuffix("```"), "and still closed")
        XCTAssertEqual(segments[1], .system(SystemBlock(kind: .systemReminder, body: "actual")))
    }

    func testAnUnclosedBlockDegradesToProse() {
        let source = "text\n<system-reminder>\nnever closed"
        XCTAssertEqual(SystemBlockSplitter.split(source), [.prose(source)])
    }

    /// One unclosed opening used to `break` the whole scan, so every
    /// well-formed block after it in the same reply stayed raw prose. It is
    /// skipped over now instead.
    func testAWellFormedBlockAfterAnUnclosedOneIsStillRecognised() {
        let segments = SystemBlockSplitter.split(
            "<system-reminder>never closed\n<command-name>/usage</command-name>\ntail"
        )
        XCTAssertEqual(segments, [
            .prose("<system-reminder>never closed"),
            .system(SystemBlock(kind: .commandName, body: "/usage")),
            .prose("tail"),
        ])
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

import AppKit
import XCTest

@testable import OmniAgent

/// `PaneAppView`: rows for a fed transcript, the fence splitter, markdown
/// typography, the empty state, composer submission, and the poll timer's
/// `isLive` gate. Not wired into any pane yet — that is Task 3.
final class PaneAppViewTests: XCTestCase {
    private func makeView() -> PaneAppView {
        PaneAppView(sessionID: "session-1", cwd: "/tmp/pane-app-view-tests")
    }

    // MARK: - Rows

    /// One row per fed message, in order; the right role label on each; and
    /// a `.tool` block's label carries both its name and its detail.
    func testRowsRenderRoleLabelsAndToolBlockContent() throws {
        let view = makeView()
        let messages: [TranscriptMessage] = [
            TranscriptMessage(id: "1", isUser: true, blocks: [.text("Hi there")]),
            TranscriptMessage(id: "2", isUser: false, blocks: [
                .text("On it."),
                .tool(name: "Read", detail: "/x.swift"),
            ]),
        ]
        view.appendMessages(messages)

        let rows = view.descendants(PaneAppMessageRowView.self)
        XCTAssertEqual(rows.count, messages.count)

        let firstLabels = rows[0].descendants(NSTextField.self)
        XCTAssertEqual(firstLabels.first?.stringValue, "You")
        XCTAssertEqual(firstLabels.first?.textColor, ShellPalette.inkTertiary)

        let secondLabels = rows[1].descendants(NSTextField.self)
        XCTAssertEqual(secondLabels.first?.stringValue, "Claude")
        XCTAssertEqual(secondLabels.first?.textColor, ShellPalette.accent)

        let toolLine = try XCTUnwrap(secondLabels.first { $0.stringValue.contains("Read") })
        XCTAssertTrue(toolLine.stringValue.contains("/x.swift"))
    }

    // MARK: - Fence splitting

    func testSplitFencesProducesTheProseAndCodeSequence() {
        let text = "before\n```swift\nlet x = 1\nlet y = 2\n```\nafter"
        XCTAssertEqual(
            PaneAppView.splitFences(text),
            [.prose("before"), .code("let x = 1\nlet y = 2"), .prose("after")]
        )
    }

    func testSplitFencesRunsAnUnterminatedFenceToTheEnd() {
        let text = "before\n```\ncode one\ncode two"
        XCTAssertEqual(
            PaneAppView.splitFences(text),
            [.prose("before"), .code("code one\ncode two")]
        )
    }

    func testSplitFencesReturnsExactlyOneSegmentForProseOnlyText() {
        let text = "just some prose\nacross two lines"
        XCTAssertEqual(PaneAppView.splitFences(text), [.prose(text)])
    }

    // MARK: - Markdown

    /// `**bold**` produces a bold run; every other run keeps the exact base
    /// font, and the colour is applied across the whole string.
    func testAttributedMarkdownAppliesBaseFontAndColourWithABoldRun() throws {
        let attributed = PaneAppView.attributedMarkdown("plain **bold** text")
        XCTAssertEqual(attributed.string, "plain bold text")

        let whole = NSRange(location: 0, length: attributed.length)
        var everyRunHasBaseColour = true
        attributed.enumerateAttribute(.foregroundColor, in: whole) { value, _, _ in
            if (value as? NSColor) != ShellPalette.ink { everyRunHasBaseColour = false }
        }
        XCTAssertTrue(everyRunHasBaseColour, "colour must apply across the whole result")

        let plainFont = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(plainFont, ShellFont.ui(13), "a plain run keeps the exact base font")

        let boldRange = (attributed.string as NSString).range(of: "bold")
        let boldFont = try XCTUnwrap(attributed.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: - Empty state

    func testEmptyStateIsVisibleUntilTheFirstMessageArrives() throws {
        let view = makeView()
        let empty = try XCTUnwrap(view.descendants(NSTextField.self).first { $0.stringValue == "Nothing yet." })
        XCTAssertFalse(empty.isHidden)

        view.appendMessages([TranscriptMessage(id: "1", isUser: true, blocks: [.text("hi")])])
        XCTAssertTrue(empty.isHidden)
    }

    // MARK: - Composer submit

    /// Enter with text calls `onSubmit` once with the trimmed string and
    /// clears the field; Enter with whitespace-only text does neither.
    /// Fires through the control's own target/action pair — exactly what a
    /// real Enter keypress in an `NSTextField` invokes — rather than
    /// simulating a key event through a window this test does not need.
    func testComposerSubmitTrimsAndClearsButIgnoresWhitespaceOnly() throws {
        let view = makeView()
        let field = try XCTUnwrap(view.primaryResponderView as? NSTextField)
        var submitted: [String] = []
        view.onSubmit = { submitted.append($0) }

        field.stringValue = "   "
        _ = field.sendAction(field.action, to: field.target)
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(field.stringValue, "   ", "whitespace-only input is left untouched")

        field.stringValue = "  hello there  "
        _ = field.sendAction(field.action, to: field.target)
        XCTAssertEqual(submitted, ["hello there"])
        XCTAssertEqual(field.stringValue, "")
    }

    // MARK: - isLive gates the timer

    func testIsLiveGatesTheTimer() {
        let view = makeView()
        XCTAssertNil(view.pollTimer)

        view.isLive = true
        XCTAssertNotNil(view.pollTimer)

        view.isLive = false
        XCTAssertNil(view.pollTimer)
    }

    // MARK: - Scroll pinning

    /// A user who has scrolled up to read earlier messages must not be
    /// yanked back down by a reply arriving behind their back —
    /// `isScrolledToBottom()` is measured before a single row is appended,
    /// so a position set between two `appendMessages` calls must survive the
    /// second one untouched. This is also a regression guard for a real bug
    /// self-review found in this exact path: `appendMessages` originally
    /// only forced layout inside its `wasAtBottom` branch, leaving
    /// `messageStack`'s height stale for the *next* call's measurement
    /// whenever the user had scrolled away from the bottom.
    func testAppendingWhileScrolledUpLeavesThePositionUnchanged() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        view.appendMessages(manyMessages(count: 10, startingAt: 0))

        let clip = try scrollClipView(in: view)
        // The append above found nothing on screen yet, so
        // `isScrolledToBottom()` was trivially true and scrolled to the
        // bottom; scroll back to the top to simulate a user reading earlier
        // messages.
        clip.scroll(to: .zero)
        let scrolledPosition = clip.bounds.origin
        XCTAssertEqual(scrolledPosition, .zero, "the view must actually have overflowed for this test to mean anything")

        view.appendMessages(manyMessages(count: 10, startingAt: 10))
        XCTAssertEqual(clip.bounds.origin, scrolledPosition, "a user scrolled up must not be moved by a later append")
    }

    /// The complementary case: a user already at the bottom follows new
    /// messages down.
    func testAppendingWhileAtTheBottomScrollsToTheBottom() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        view.appendMessages(manyMessages(count: 10, startingAt: 0))

        let clip = try scrollClipView(in: view)
        let documentHeight = try messageStackHeight(in: view)
        XCTAssertEqual(
            clip.bounds.maxY, documentHeight, accuracy: 1,
            "the initial append (nothing on screen yet) scrolls to the bottom"
        )

        view.appendMessages(manyMessages(count: 10, startingAt: 10))
        let newDocumentHeight = try messageStackHeight(in: view)
        XCTAssertGreaterThan(newDocumentHeight, documentHeight, "the second batch must actually have grown the content")
        XCTAssertEqual(
            clip.bounds.maxY, newDocumentHeight, accuracy: 1,
            "still at the bottom, so the second append follows the new messages down"
        )
    }

    private func manyMessages(count: Int, startingAt offset: Int) -> [TranscriptMessage] {
        (0..<count).map { index in
            TranscriptMessage(
                id: "msg-\(offset + index)",
                isUser: index.isMultiple(of: 2),
                blocks: [.text("Message number \(offset + index), with enough words in it to take up some real vertical space in the row.")]
            )
        }
    }

    private func scrollClipView(in view: PaneAppView) throws -> NSClipView {
        try XCTUnwrap(view.descendants(ShellScrollView.self).first).contentView
    }

    private func messageStackHeight(in view: PaneAppView) throws -> CGFloat {
        let scroll = try XCTUnwrap(view.descendants(ShellScrollView.self).first)
        return try XCTUnwrap(scroll.documentView).frame.height
    }

    // MARK: - Offscreen render

    /// A full layout pass at a real pane size, with a couple of rendered
    /// messages — one with a fenced code block, one with a tool call — and
    /// the composer beneath, neither throws nor collapses. Drops a PNG when
    /// `PANE_RENDER_DIR` is set
    /// (`TEST_RUNNER_PANE_RENDER_DIR=/tmp/pane-app ./macos/build.sh test`).
    func testTheAppViewLaysOutOffscreen() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        view.appendMessages([
            TranscriptMessage(id: "1", isUser: true, blocks: [.text("Can you check the build?")]),
            TranscriptMessage(id: "2", isUser: false, blocks: [
                .text("Sure — running it now. Here's the **relevant** bit:\n\n```swift\nlet x = 1\n```"),
                .tool(name: "Bash", detail: "./macos/build.sh test"),
            ]),
        ])
        let window = show(view)
        defer { window.close() }

        let rep = try XCTUnwrap(render(view))
        saveRenderForInspection(rep, named: "pane-app-view")

        XCTAssertEqual(rep.pixelsWide, 420)
        XCTAssertEqual(rep.pixelsHigh, 640)
    }

    // MARK: - Offscreen render helpers
    // Copied from `DeskCanvasNodeViewsTests.swift:531-560` — this repo's
    // per-file render-drop convention rather than a shared helper.

    /// A window, because a layer-backed view with no window never runs
    /// `draw(_:)` and the render comes back empty — the test would then pass
    /// for the wrong reason.
    private func show(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        return window
    }

    /// Renders a view's whole layer tree — `cacheDisplay` draws `draw(_:)`
    /// output only, which misses the layer-backed fills and strokes this view
    /// is built from.
    private func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        view.layer?.render(in: context.cgContext)
        return rep
    }

    /// Nothing reads this in CI; it exists so Bruno can eyeball a render.
    /// `xcodebuild test`'s `TEST_RUNNER_` prefix is stripped and the rest
    /// handed straight to the test host's environment, so
    /// `TEST_RUNNER_PANE_RENDER_DIR=/tmp/pane-app ./macos/build.sh test` drops
    /// a PNG per named render there; unset, this is a no-op.
    private func saveRenderForInspection(_ rep: NSBitmapImageRep, named name: String) {
        guard
            let dir = ProcessInfo.processInfo.environment["PANE_RENDER_DIR"],
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

private extension NSView {
    /// Every match, in tree order — depth-first, the same idiom
    /// `WorkspaceShellTests` uses to find rows that live in a private stack.
    func descendants<View: NSView>(_ type: View.Type) -> [View] {
        var found: [View] = []
        for subview in subviews {
            if let match = subview as? View { found.append(match) }
            found += subview.descendants(type)
        }
        return found
    }
}

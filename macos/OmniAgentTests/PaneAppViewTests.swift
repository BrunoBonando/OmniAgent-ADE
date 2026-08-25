import AppKit
import CoreImage
import XCTest

@testable import OmniAgent

/// `PaneAppView`: rows for a fed transcript, the markdown block scanner,
/// inline markdown typography, the empty state, composer submission, the poll
/// timer's `isLive` gate — and the reader → view seam, where a real view is
/// pointed at a real JSONL file and driven through its actual polling path.
final class PaneAppViewTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneAppViewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    /// The conversation the 880pt cap actually has to survive: `.text`
    /// blocks of long, unbroken single-line prose. A wrapping `NSTextField`
    /// reports its *single-line* width as its intrinsic width, so each of
    /// these wants well over a thousand points and pushes outward on
    /// anything holding the column in.
    private static let longProse: [TranscriptMessage] = [
        TranscriptMessage(id: "1", isUser: true, blocks: [
            .text(
                "Walk me through how the transcript column is supposed to lay itself out when the "
                + "pane is dragged very wide, and why the composer underneath it ends up lining up "
                + "with the prose above it rather than spanning the whole pane on its own."
            ),
        ]),
        TranscriptMessage(id: "2", isUser: false, blocks: [
            .text(
                "The transcript sits in a centred column capped at eight hundred and eighty points "
                + "wide, so prose keeps a readable measure no matter how far the pane is opened, and "
                + "the composer reuses that exact column so the two agree edge for edge on screen."
            ),
            .text(
                "On a pane narrower than the column itself the cap gives way at a forty point leading "
                + "floor rather than clipping against the pane's edge, which is the same escape hatch "
                + "the home screen's own content column uses, for the same reason and at the same size."
            ),
        ]),
    ]

    /// A table far wider than the column, rendered into the same
    /// horizontally-scrolling card a fenced code block gets.
    private static let wideTableMarkdown = """
    | column one heading | column two heading | column three heading | column four heading | column five heading |
    | --- | --- | --- | --- | --- |
    | a fairly long cell | another fairly long cell | a third fairly long cell | a fourth long cell | a fifth long cell |
    """

    /// A view fed by hand. Its `home` is a directory that does not exist, so
    /// a tick that does slip through resolves nothing and reads no file —
    /// these tests are about what `appendMessages` draws, not about polling.
    private func makeView() -> PaneAppView {
        PaneAppView(
            sessionID: "session-1",
            cwd: "/tmp/pane-app-view-tests",
            home: URL(fileURLWithPath: "/tmp/pane-app-view-tests-no-home")
        )
    }

    // MARK: - Ground

    /// App mode is not a terminal, so it does not wear terminal black. It takes
    /// the workspace ground's own gradient — the one `PaneGroundView` paints
    /// behind the grid — because the reason panes go opaque ("a terminal theme
    /// with any transparency washes its own text out") is about the terminal,
    /// and there is no terminal theme here to protect.
    func testTheAppViewPaintsTheWorkspaceGroundGradient() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()

        let gradient = try XCTUnwrap(view.layer as? CAGradientLayer, "not a flat fill")
        let colors = try XCTUnwrap(gradient.colors as? [CGColor])
        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(colors[0], PaneGroundView.colors[0].cgColor)
        XCTAssertEqual(colors[1], PaneGroundView.colors[1].cgColor)
    }

    /// And it is lit from the same end as the ground it borrows — which end
    /// the light is at is not free: a gradient's unit space is y-up and
    /// whether that survives depends on the view's flippedness, so it is
    /// rendered and anchored by a marker at the top of the screen, exactly
    /// like `testTheGroundUnderThePanesIsLitFromTheTop` does for the ground.
    func testTheAppViewGroundIsLitFromTheTopLikeTheWorkspaceGround() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        view.appendMessages(Self.longProse)
        let window = show(view)
        defer { window.close() }
        // Unflipped, so the top of the screen is the *high* y.
        let marker = NSView(frame: NSRect(x: 0, y: view.bounds.height - 6, width: 300, height: 6))
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.green.cgColor
        view.addSubview(marker)
        window.displayIfNeeded()
        view.layoutSubtreeIfNeeded()

        let image = try XCTUnwrap(render(view))
        // Two points in from the right edge: the column is centred and capped,
        // so this strip is the ground itself rather than any row's fill.
        func pixel(_ row: Int) -> NSColor {
            image.colorAt(x: image.pixelsWide - 2, y: row)?.usingColorSpace(.sRGB) ?? .black
        }
        let anchor = try XCTUnwrap(
            (0..<image.pixelsHigh).first { pixel($0).greenComponent > 0.8 },
            "the marker has to show up, or the render proves nothing"
        )
        let rows = anchor < image.pixelsHigh / 2
            ? Array(0..<image.pixelsHigh)
            : Array((0..<image.pixelsHigh).reversed())
        let top = pixel(rows[rows.count / 10])
        let bottom = pixel(rows[rows.count - rows.count / 20])
        XCTAssertGreaterThan(top.brightnessComponent, bottom.brightnessComponent + 0.02, "lit from the top")
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

    // MARK: - Turns

    /// One reply arrives as several assistant rows — Claude Code writes each
    /// tool call as its own. They are one turn, and get one role label.
    func testGroupMergesConsecutiveSameRoleMessages() {
        let turns = TranscriptTurn.group([
            TranscriptMessage(id: "1", isUser: true, blocks: [.text("hi")]),
            TranscriptMessage(id: "2", isUser: false, blocks: [.text("on it")]),
            TranscriptMessage(id: "3", isUser: false, blocks: [.tool(name: "Bash", detail: "ls")]),
            TranscriptMessage(id: "4", isUser: false, blocks: [.text("done")]),
        ])

        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns[0].isUser)
        XCTAssertEqual(turns[1].id, "2", "a turn keeps its first message's id")
        XCTAssertEqual(turns[1].blocks.count, 3, "blocks concatenate in order")
        XCTAssertEqual(turns[1].blocks.first, .text("on it"))
    }

    /// A poll landing another assistant row extends the turn already on screen
    /// rather than opening a second one — and says which turn to redraw.
    func testAppendExtendsTheLastTurnWhenTheRoleMatches() {
        var turns = TranscriptTurn.group([
            TranscriptMessage(id: "1", isUser: false, blocks: [.text("a")]),
        ])
        let changed = TranscriptTurn.append(
            [TranscriptMessage(id: "2", isUser: false, blocks: [.text("b")])],
            to: &turns
        )

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].blocks.count, 2)
        XCTAssertEqual(changed, 0)
    }

    /// A role flip opens a new turn, and only that new turn needs drawing.
    func testAppendOpensANewTurnWhenTheRoleFlips() {
        var turns = TranscriptTurn.group([
            TranscriptMessage(id: "1", isUser: false, blocks: [.text("a")]),
        ])
        let changed = TranscriptTurn.append(
            [TranscriptMessage(id: "2", isUser: true, blocks: [.text("b")])],
            to: &turns
        )

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(changed, 1)
    }

    /// The view stamps one role label per turn, not one per row.
    func testOneRoleLabelPerTurn() {
        let view = makeView()
        view.appendMessages([
            TranscriptMessage(id: "1", isUser: false, blocks: [.text("on it")]),
            TranscriptMessage(id: "2", isUser: false, blocks: [.tool(name: "Bash", detail: "ls")]),
            TranscriptMessage(id: "3", isUser: false, blocks: [.tool(name: "Read", detail: "/x")]),
        ])

        let rows = view.descendants(PaneAppMessageRowView.self)
        XCTAssertEqual(rows.count, 1)
        let labels = view.descendants(NSTextField.self).filter { $0.stringValue == "Claude" }
        XCTAssertEqual(labels.count, 1)
    }

    /// The mechanism Task 2 turns on, at the view level: a *second*
    /// `appendMessages` that extends the turn already on screen must rebuild
    /// that one row in place, and a third that flips role must add one beside
    /// it. Every other turn test either calls `appendMessages` once or works
    /// on `TranscriptTurn` directly, so the remove-and-rebuild loop had only
    /// ever run with nothing to remove — an off-by-one in it would duplicate
    /// or drop a row and nothing would notice.
    func testASecondAppendRebuildsTheGrowingTurnInPlace() {
        let view = makeView()
        view.appendMessages([
            TranscriptMessage(id: "1", isUser: true, blocks: [.text("hi")]),
            TranscriptMessage(id: "2", isUser: false, blocks: [.text("on it")]),
        ])
        XCTAssertEqual(view.descendants(PaneAppMessageRowView.self).count, 2)

        // Same role as the row already on screen: it grows, it does not
        // gain a neighbour.
        view.appendMessages([TranscriptMessage(id: "3", isUser: false, blocks: [.text("done")])])
        XCTAssertEqual(view.descendants(PaneAppMessageRowView.self).count, 2)
        XCTAssertEqual(rowTexts(of: view), ["hi", "on it done"])

        // A role flip opens a row instead, leaving the rebuilt one alone.
        view.appendMessages([TranscriptMessage(id: "4", isUser: true, blocks: [.text("thanks")])])
        XCTAssertEqual(view.descendants(PaneAppMessageRowView.self).count, 3)
        XCTAssertEqual(rowTexts(of: view), ["hi", "on it done", "thanks"])
    }

    // MARK: - Tool labels

    /// A `Bash` command is routinely a multi-line script. The tool line is a
    /// line to skim, not a script to read: however many newlines the detail
    /// carries, the label stays exactly one line tall.
    func testToolLabelStaysOneLineForAMultiLineCommand() {
        let single = PaneAppView.toolLabel(name: "Bash", detail: "echo one")
        let multi = PaneAppView.toolLabel(
            name: "Bash",
            detail: "echo one\necho two\necho three\necho four"
        )
        XCTAssertEqual(
            multi.intrinsicContentSize.height,
            single.intrinsicContentSize.height,
            accuracy: 0.5
        )
    }

    /// And it flattens to *one* space per break, whatever the breaks are: a
    /// blank line, a `\r\n`, or a detail that opens or closes with a newline
    /// all used to leave doubled or dangling spaces in the label.
    func testToolLabelCollapsesRunsOfNewlinesToASingleSpace() {
        XCTAssertEqual(
            PaneAppView.toolLabel(name: "Bash", detail: "\r\necho one\n\necho two\n").stringValue,
            "▸ Bash  echo one echo two"
        )
    }

    // MARK: - Markdown blocks

    func testParseSplitsFencedCodeFromProse() {
        let blocks = MarkdownBlock.parse("before\n```\nlet x = 1\n```\nafter")
        XCTAssertEqual(blocks, [
            .paragraph("before"),
            .code("let x = 1"),
            .paragraph("after"),
        ])
    }

    /// A reply still being written ends mid-fence every time it is polled. An
    /// unterminated fence runs to the end rather than being treated as an error.
    func testParseLetsAnUnterminatedFenceRunToTheEnd() {
        let blocks = MarkdownBlock.parse("intro\n```\nstill typing")
        XCTAssertEqual(blocks, [.paragraph("intro"), .code("still typing")])
    }

    func testParseReadsHeadingsAndTheirLevel() {
        let blocks = MarkdownBlock.parse("## Results\ntext")
        XCTAssertEqual(blocks, [.heading(level: 2, text: "Results"), .paragraph("text")])
    }

    func testParseGroupsListItems() {
        let blocks = MarkdownBlock.parse("- one\n- two\n\nafter")
        XCTAssertEqual(blocks, [
            .list(items: ["one", "two"], ordered: false),
            .paragraph("after"),
        ])
    }

    func testParseReadsAnOrderedList() {
        let blocks = MarkdownBlock.parse("1. first\n2. second")
        XCTAssertEqual(blocks, [.list(items: ["first", "second"], ordered: true)])
    }

    /// The shape that reads as raw pipes today — note the empty leading header
    /// cell, which is exactly what a `wc -l` table produces.
    func testParseReadsATable() {
        let blocks = MarkdownBlock.parse("| | lines |\n|---|---|\n| Swift | 69158 |")
        XCTAssertEqual(blocks, [
            .table(header: ["", "lines"], rows: [["Swift", "69158"]]),
        ])
    }

    /// Ragged rows are ordinary markdown and stay a table — Task 4's renderer
    /// pads them. Only a missing delimiter row disqualifies one.
    func testParseKeepsARaggedTable() {
        let blocks = MarkdownBlock.parse("| a | b |\n|---|---|\n| 1 |")
        XCTAssertEqual(blocks, [.table(header: ["a", "b"], rows: [["1"]])])
    }

    /// Pipe lines with no delimiter row are not a table. They fall back to the
    /// paragraph they came from — losing formatting beats losing content.
    func testParsePipeLinesWithoutADelimiterStayProse() {
        let blocks = MarkdownBlock.parse("| a | b |\n| 1 | 2 |")
        XCTAssertEqual(blocks, [.paragraph("| a | b |\n| 1 | 2 |")])
    }

    /// Prose wrapped across several lines is one paragraph, not one paragraph
    /// per line. The scanner only breaks a paragraph on a blank line or a
    /// line that opens another block — and the block-per-line regression is
    /// invisible in every other fixture here, all of which are single-line,
    /// while on screen it would change the spacing of every reply.
    func testParseKeepsAMultiLineParagraphWhole() {
        let blocks = MarkdownBlock.parse("first line\nsecond line\nthird line")
        XCTAssertEqual(blocks, [.paragraph("first line\nsecond line\nthird line")])
    }

    func testParseKeepsBlocksInOrder() {
        let blocks = MarkdownBlock.parse("# Title\npara\n- item\n```\ncode\n```")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("para"),
            .list(items: ["item"], ordered: false),
            .code("code"),
        ])
    }

    // MARK: - Block views

    /// Columns pad to their widest cell, header included, so the table lines up
    /// the way the terminal's does. A rule row separates header from body.
    func testRenderTablePadsColumnsToTheirWidestCell() {
        let rendered = PaneAppView.renderTable(
            header: ["", "lines"],
            rows: [["Swift", "69158"], ["CSS", "9726"]]
        )
        let lines = rendered.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "       lines")
        XCTAssertTrue(lines[1].hasPrefix("─────"))
        XCTAssertEqual(lines[2], "Swift  69158")
        XCTAssertEqual(lines[3], "CSS    9726")
    }

    /// A ragged row is padded out to the table's column count rather than
    /// throwing the alignment off or crashing on a missing index.
    func testRenderTablePadsARaggedRow() {
        let rendered = PaneAppView.renderTable(header: ["a", "b"], rows: [["1"]])
        let lines = rendered.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[2], "1")
    }

    /// One column is where both halves of the renderer degenerate: nothing to
    /// `joined(separator: "  ")` between, and the trailing-space trim is the
    /// only thing left keeping the padding off the end of every line.
    func testRenderTableWithASingleColumn() {
        let rendered = PaneAppView.renderTable(header: ["name"], rows: [["Swift"], ["CSS"]])

        XCTAssertEqual(rendered.components(separatedBy: "\n"), ["name", "─────", "Swift", "CSS"])
    }

    /// A body row *wider* than its header. Ordinary enough in markdown, and
    /// the failure mode of the obvious simplification (`columns =
    /// header.count`) is not a misrender: it is `Array(repeating:count:)`
    /// with a negative count, which traps — an app crash on well-formed
    /// input.
    func testRenderTableKeepsABodyRowWiderThanItsHeader() {
        let rendered = PaneAppView.renderTable(header: ["a"], rows: [["1", "2"]])
        let lines = rendered.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "a")
        XCTAssertEqual(lines[2], "1  2", "the column the header never had is still rendered")
    }

    /// A table reaches the row as one monospaced card, not as prose.
    func testATableRendersAsAMonospacedBlock() {
        let row = PaneAppMessageRowView(turn: TranscriptTurn(
            id: "1",
            isUser: false,
            blocks: [.text("| a | b |\n|---|---|\n| 1 | 2 |")]
        ))
        let monospaced = row.descendants(NSTextField.self).filter {
            $0.font?.fontName == ShellFont.mono(12).fontName
        }

        XCTAssertEqual(monospaced.count, 1)
        XCTAssertTrue(monospaced[0].stringValue.contains("─"))
    }

    /// A heading is visibly bigger than body prose — the difference a reader
    /// scans by.
    func testAHeadingIsLargerThanBodyProse() {
        let heading = PaneAppView.headingLabel(level: 2, text: "Results")
        let prose = PaneAppView.proseLabel("Results")
        let headingSize = heading.font?.pointSize ?? 0
        let proseSize = prose.font?.pointSize ?? 0

        XCTAssertGreaterThan(headingSize, proseSize)
        XCTAssertEqual(heading.stringValue, "Results")
    }

    /// A heading runs through the same inline parser its paragraphs do —
    /// `### The \`parse\` scanner` is routine Claude output, and a plain
    /// label printed its backticks. The code run is monospaced at the
    /// *heading's* size, not body size.
    func testAHeadingRendersInlineCodeRatherThanItsBackticks() throws {
        let heading = PaneAppView.headingLabel(level: 2, text: "The `parse` scanner")
        XCTAssertEqual(heading.stringValue, "The parse scanner", "no literal backticks")

        let attributed = heading.attributedStringValue
        let codeRange = (attributed.string as NSString).range(of: "parse")
        let codeFont = try XCTUnwrap(
            attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(codeFont, ShellFont.mono(15))

        let plainFont = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(plainFont, ShellFont.ui(15, .semibold), "the rest keeps the heading's own weight")
    }

    /// List items get their marker and stay one view per item, so a long item
    /// wraps under its own bullet instead of under the one above.
    func testAListRendersOneMarkedRowPerItem() {
        let list = PaneAppView.listView(items: ["one", "two"], ordered: false)
        let labels = list.descendants(NSTextField.self)

        XCTAssertEqual(labels.count, 4, "a marker and a body label per item")
        XCTAssertEqual(labels[0].stringValue, "•")
        XCTAssertEqual(labels[1].stringValue, "one")
    }

    func testAnOrderedListNumbersItsItems() {
        let list = PaneAppView.listView(items: ["one", "two"], ordered: true)
        let labels = list.descendants(NSTextField.self)

        XCTAssertEqual(labels[0].stringValue, "1.")
        XCTAssertEqual(labels[2].stringValue, "2.")
    }

    // MARK: - Work groups

    func testWorkSummaryNamesASingleCall() {
        XCTAssertEqual(PaneAppView.workSummary(for: ["Bash"]), "Bash")
    }

    func testWorkSummaryCountsAHomogeneousRun() {
        XCTAssertEqual(PaneAppView.workSummary(for: ["Bash", "Bash", "Bash"]), "3 Bash calls")
    }

    /// Mixed runs get a neutral count — "3 Bash calls" would be a lie and
    /// listing every name is the wall of text this exists to remove.
    func testWorkSummaryFallsBackToStepsForAMixedRun() {
        XCTAssertEqual(PaneAppView.workSummary(for: ["Bash", "Read", "Edit"]), "3 steps")
    }

    /// Consecutive tool calls become one group, collapsed, with the detail
    /// built but hidden — expansion must not have to re-derive anything.
    func testConsecutiveToolCallsCollapseIntoOneGroup() {
        let row = PaneAppMessageRowView(turn: TranscriptTurn(id: "1", isUser: false, blocks: [
            .text("on it"),
            .tool(name: "Bash", detail: "ls"),
            .tool(name: "Bash", detail: "pwd"),
            .text("done"),
        ]))

        let groups = row.descendants(PaneAppWorkGroupView.self)
        XCTAssertEqual(groups.count, 1)
        XCTAssertFalse(groups[0].isExpanded)

        let summaries = row.descendants(NSTextField.self).filter { $0.stringValue == "2 Bash calls" }
        XCTAssertEqual(summaries.count, 1)
    }

    /// Prose on both sides of a run keeps its place — work reads where it
    /// happened, rather than being hoisted to the top of the turn. A run of
    /// two so it actually collapses into a group (a run of one renders
    /// inline and would not exercise this ordering at all).
    func testProseKeepsItsPlaceAroundAWorkGroup() {
        let row = PaneAppMessageRowView(turn: TranscriptTurn(id: "1", isUser: false, blocks: [
            .text("on it"),
            .tool(name: "Bash", detail: "ls"),
            .tool(name: "Bash", detail: "pwd"),
            .text("done"),
        ]))
        let body = row.descendants(NSStackView.self).first!
        let kinds = body.arrangedSubviews.map { $0 is PaneAppWorkGroupView }

        XCTAssertEqual(kinds, [false, false, true, false], "role label, prose, group, prose")
    }

    /// A run of exactly one call is not the wall of shell commands the
    /// collapse exists to remove — it renders inline, exactly as it did
    /// before work groups existed, with no group to expand at all.
    func testASingleToolCallRendersInlineRatherThanCollapsing() {
        let row = PaneAppMessageRowView(turn: TranscriptTurn(id: "1", isUser: false, blocks: [
            .tool(name: "Read", detail: "/x.swift"),
        ]))

        XCTAssertEqual(row.descendants(PaneAppWorkGroupView.self).count, 0)

        let inline = row.descendants(NSTextField.self).filter { $0.stringValue.hasPrefix("▸") }
        XCTAssertEqual(inline.count, 1)
        XCTAssertEqual(inline[0].stringValue, "▸ Read  /x.swift")
    }

    /// Two runs separated by prose stay two groups — the prose between them
    /// must not let them merge into one.
    func testTwoRunsSeparatedByProseProduceTwoGroups() {
        let row = PaneAppMessageRowView(turn: TranscriptTurn(id: "1", isUser: false, blocks: [
            .tool(name: "Bash", detail: "ls"),
            .tool(name: "Bash", detail: "pwd"),
            .text("in between"),
            .tool(name: "Bash", detail: "whoami"),
            .tool(name: "Bash", detail: "date"),
        ]))

        XCTAssertEqual(row.descendants(PaneAppWorkGroupView.self).count, 2)
    }

    func testExpandingAWorkGroupRevealsItsCalls() {
        let group = PaneAppWorkGroupView(calls: [("Bash", "ls"), ("Bash", "pwd")])
        let detail = group.descendants(NSTextField.self).filter { $0.stringValue.hasPrefix("▸") }
        XCTAssertEqual(detail.count, 2, "detail is built up front, not on expand")
        let collapsedHeight = group.fittingSize.height

        group.toggle()

        XCTAssertTrue(group.isExpanded)
        XCTAssertFalse(detail[0].isHiddenOrHasHiddenAncestor)
        // Unhiding alone is not revealing: a stack that never relaid out
        // would pass the assertion above and still draw nothing but the
        // header. The group has to get taller.
        XCTAssertGreaterThan(group.fittingSize.height, collapsedHeight)
    }

    /// A reply lands a row every ~0.3s for as long as it runs, and each one
    /// rebuilds the growing turn's row from scratch. A group the user opened
    /// mid-reply has to come back open, or it slams shut on the next poll and
    /// goes on doing it for the rest of the turn.
    func testAnExpandedWorkGroupSurvivesItsTurnGrowing() throws {
        let view = makeView()
        view.appendMessages([
            TranscriptMessage(id: "1", isUser: false, blocks: [
                .tool(name: "Bash", detail: "ls"),
                .tool(name: "Bash", detail: "pwd"),
            ]),
        ])
        let group = try XCTUnwrap(view.descendants(PaneAppWorkGroupView.self).first)
        group.toggle()
        XCTAssertTrue(group.isExpanded)

        // The rest of the same reply — the reader drops `tool_result` rows,
        // so this stays one turn and that row is destroyed and rebuilt.
        view.appendMessages([TranscriptMessage(id: "2", isUser: false, blocks: [.text("done")])])

        XCTAssertEqual(view.descendants(PaneAppMessageRowView.self).count, 1)
        let rebuilt = try XCTUnwrap(view.descendants(PaneAppWorkGroupView.self).first)
        XCTAssertFalse(rebuilt === group, "the row really was rebuilt, so this is not a trivial pass")
        XCTAssertTrue(rebuilt.isExpanded, "an expanded group must not snap shut mid-reply")
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

    // MARK: - Composer

    /// The transcript runs the full height of the view and scrolls *behind*
    /// the composer, with enough bottom inset that the last message can clear
    /// the glass instead of parking under it.
    func testTranscriptScrollsBehindTheComposer() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.scrollView.frame.height, view.frame.height, accuracy: 0.5)
        XCTAssertGreaterThan(view.scrollView.contentInsets.bottom, 40)

        // Derived from the real, laid-out glass, not an authored constant:
        // the inset has to track the container's own height (plus its
        // margin off the view's edge) exactly, so a font or controls-row
        // change can never silently desync it. `+ 20`, not the pre-redesign
        // `+ 12`: the composer sits slightly further off the bottom edge now.
        let glassContainer = try XCTUnwrap(view.composerField.superview)
        XCTAssertEqual(
            view.scrollView.contentInsets.bottom, glassContainer.frame.height + 20, accuracy: 0.5
        )
    }

    /// The transcript is centred in the same 880pt column `HomeView`'s own
    /// content uses (`HomeView.swift:275-292`), not spread across the full
    /// pane, on a window wide enough that the escape hatch never engages.
    ///
    /// Through `show(_:)`, not a bare `layoutSubtreeIfNeeded()`: a column
    /// width fight (the `.defaultHigh` 880pt preference against the required
    /// 40pt leading floor) only resolves the way production actually lays it
    /// out — `messageStack`/`composerGlass` capped, `self` untouched — inside
    /// a real window; unwindowed, Auto Layout has nothing pinning `self`'s
    /// own frame as fixed and the two ends of that fight land inconsistently
    /// with each other (confirmed with a throwaway offscreen probe).
    func testTheMessageColumnIsCappedAt880ptAndCentred() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
        let window = show(view)
        defer { window.close() }

        // Fed, not empty. An empty stack has no content pushing back against
        // the cap, so it measures 880pt whether or not the cap actually
        // holds — which is precisely how a full-width transcript once shipped
        // under a green version of this test.
        view.appendMessages(Self.longProse)
        view.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(view.scrollView.documentView)
        let column = try XCTUnwrap(content.subviews.first, "messageStack, the transcript column")

        XCTAssertEqual(column.frame.width, 880, accuracy: 0.5)
        XCTAssertEqual(column.frame.midX, content.frame.midX, accuracy: 0.5, "centred, not just capped")
    }

    /// The same cap at the width Bruno's real window runs at, where the gap
    /// between 880pt and the pane is wide enough for a whole paragraph to fit
    /// on one unwrapped line — the shape the bug was actually reported in.
    ///
    /// Separate from the 1400pt case above rather than replacing it: a cap
    /// that survives a 1400pt pane and not a 2000pt one is a cap that is
    /// really just "whatever the widest label wants", and only the wider
    /// pane tells those two apart.
    func testTheMessageColumnStaysCappedOnAVeryWidePaneWithProse() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 2000, height: 900)
        let window = show(view)
        defer { window.close() }

        view.appendMessages(Self.longProse)
        view.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(view.scrollView.documentView)
        let column = try XCTUnwrap(content.subviews.first, "messageStack, the transcript column")

        XCTAssertEqual(column.frame.width, 880, accuracy: 0.5)
        XCTAssertEqual(column.frame.midX, content.frame.midX, accuracy: 0.5, "centred, not just capped")

        // The rows too, not just the stack around them: a row is pinned to
        // the stack's width, so a row wider than the cap means the cap was
        // read as a suggestion somewhere further down the chain.
        for row in view.descendants(PaneAppMessageRowView.self) {
            XCTAssertLessThanOrEqual(row.frame.width, 880.5, "a row spilling past the column")
        }
    }

    /// Long unbroken content that deliberately refuses to wrap — a code
    /// fence with a very long line, and a wide table, both of which render
    /// into the horizontally-scrolling card — must overflow *inside* the
    /// card, never by widening the column that holds it.
    func testAWideCodeBlockScrollsInsteadOfWideningTheColumn() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 2000, height: 900)
        let window = show(view)
        defer { window.close() }

        let longLine = String(repeating: "let averyLongIdentifierName = compute(argument:) // ", count: 12)
        view.appendMessages([
            TranscriptMessage(id: "1", isUser: false, blocks: [
                .text("```\n\(longLine)\n```"),
            ]),
            TranscriptMessage(id: "2", isUser: false, blocks: [
                .text(Self.wideTableMarkdown),
            ]),
        ])
        view.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(view.scrollView.documentView)
        let column = try XCTUnwrap(content.subviews.first, "messageStack, the transcript column")

        XCTAssertEqual(column.frame.width, 880, accuracy: 0.5)

        // The overflow has to land somewhere, and the card's own scroll view
        // is where: its document is wider than the card that clips it.
        let cards = view.descendants(NSScrollView.self).filter { $0 !== view.scrollView }
        XCTAssertFalse(cards.isEmpty, "the code fence and the table both render into a card")
        XCTAssertTrue(
            cards.contains { ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width },
            "the long line overflows inside the card rather than widening the column"
        )
    }

    /// The same escape hatch `HomeView`'s column uses: on a window too
    /// narrow for 880pt, the column gives way at a 40pt leading floor rather
    /// than clipping against the pane's edge. See `testTheMessageColumnIsCappedAt880ptAndCentred`
    /// for why this goes through `show(_:)`.
    func testTheMessageColumnGivesWayOnANarrowWindow() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        let window = show(view)
        defer { window.close() }

        // Fed for the same reason the wide case is: whatever holds the cap
        // down must still be breakable by the required leading floor once
        // there is real content pushing the other way.
        view.appendMessages(Self.longProse)
        view.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(view.scrollView.documentView)
        let column = try XCTUnwrap(content.subviews.first)

        XCTAssertLessThan(column.frame.width, 880)
        XCTAssertEqual(column.frame.minX, 40, accuracy: 0.5)
    }

    /// The composer sits in the transcript's own centred column, at the
    /// design's taller vertical rhythm — roughly `HomeView`'s composer card
    /// proportions (`HomeView.swift`, `buildComposer()`), not the
    /// pre-redesign ~75pt. See `testTheMessageColumnIsCappedAt880ptAndCentred`
    /// for why this goes through `show(_:)`.
    func testTheComposerIsTallerAndCentredInTheSameColumn() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
        let window = show(view)
        defer { window.close() }

        let glass = try XCTUnwrap(view.composerField.superview)

        XCTAssertGreaterThanOrEqual(glass.frame.height, 100)
        XCTAssertLessThanOrEqual(glass.frame.height, 115)
        XCTAssertEqual(glass.frame.width, 880, accuracy: 0.5, "the same column width as the transcript")
        XCTAssertEqual(glass.frame.midX, view.frame.midX, accuracy: 0.5, "centred in the pane")
    }

    /// The composer's glass is the approval card's own material
    /// (`WorkspaceGlass.sheet`, `NSGlassEffectView` with `.style = .regular`)
    /// — not a hand-picked stand-in — so the two agree when both are on
    /// screen. Pins the actual type/material rather than a looser structural
    /// fact, precisely because a looser check (blend mode alone, on any
    /// visual-effect view) is what let a wrong material through review once
    /// already.
    func testTheComposerSitsOnGlass() throws {
        let view = makeView()
        // `composerField`'s superview is the glass container — the tests have
        // no direct access to `composerGlass`, which stays `private`.
        let container = try XCTUnwrap(view.composerField.superview)

        // Never an `NSVisualEffectView` stand-in, on any OS: that was the
        // wrong material (dark HUD chrome, meant for a floating window panel)
        // applied unconditionally, and is exactly the regression this test
        // exists to catch.
        XCTAssertTrue(view.descendants(NSVisualEffectView.self).isEmpty)

        guard #available(macOS 26.0, *) else {
            // No glass to ask for pre-26 — same rule `WorkspaceGlass.sheet`
            // documents for every other caller — so the fallback is the
            // plain flat card `SidebarAccountRowView` also falls back to,
            // painted directly on the container's own layer.
            XCTAssertTrue(container.subviews.isEmpty, "no panel layered on top pre-26")
            XCTAssertNotNil(container.layer?.backgroundColor, "the flat-card fallback paints its own layer")
            return
        }
        let glass = try XCTUnwrap(container.subviews.first as? NSGlassEffectView)
        XCTAssertEqual(glass.style, .regular, "the approval card's own material")
        XCTAssertNil(glass.tintColor, "no wash of colour over it")
    }

    /// Focus has to be visible. `focusRingType` is `.none` and the field's
    /// own bordered container is gone (it folded into the glass), so without
    /// a stroke of its own a focused composer is pixel-identical to an idle
    /// one and nothing on screen says where keystrokes are going.
    func testFocusingTheComposerStrokesTheGlass() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = show(view)
        defer { window.close() }
        let container = try XCTUnwrap(view.composerField.superview)
        let restingWidth = container.layer?.borderWidth ?? 0

        XCTAssertTrue(window.makeFirstResponder(view.composerField), "the composer takes focus")

        XCTAssertEqual(container.layer?.borderWidth, 1)
        XCTAssertEqual(
            container.layer?.borderColor,
            ShellPalette.accent.withAlphaComponent(0.5).cgColor,
            "the accent stroke, the same one the field's own container wore before Task 6"
        )

        // And it goes away again: a permanent stroke says "focused" forever.
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(container.layer?.borderWidth, restingWidth)
    }

    /// The focus glow: `PaneWorkspaceView.updateWorkingRing`'s own idiom at
    /// its core — a spinning `CAGradientLayer`, created only while wanted
    /// and removed from its superlayer entirely (not merely hidden) once it
    /// is not. Focusing a live, key-window composer must create the
    /// container, with the gradient inside it spinning; blurring it must
    /// remove the container rather than leaving a paused animation behind.
    /// `reducedMotionForTesting`/`isKeyWindowForTesting` are set explicitly
    /// here (not left to `nil`/the live setting) so this passes on any
    /// runner regardless of its own Reduce Motion setting or whether its
    /// app is active, rather than only on the ones lucky enough to have
    /// both already lined up.
    func testFocusingALiveComposerCreatesTheGlowAndBlurRemovesIt() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.isLive = true
        view.reducedMotionForTesting = false
        view.isKeyWindowForTesting = true
        let window = show(view)
        defer { window.close() }
        let glass = try XCTUnwrap(view.composerField.superview)

        XCTAssertNil(glowContainer(on: glass), "no glow before focus")

        XCTAssertTrue(window.makeFirstResponder(view.composerField))
        let gradient = try XCTUnwrap(glowGradient(on: glass), "focus creates the glow")
        XCTAssertNotNil(gradient.animation(forKey: "om-spin"), "and it spins")

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNil(glowContainer(on: glass), "blur removes it entirely, not just hides it")

        view.isLive = false
    }

    /// A pane in Terminal mode (`isLive == false`) never spends the glow's
    /// animated blur on a composer nobody is looking at, even if it somehow
    /// takes focus. `reducedMotionForTesting`/`isKeyWindowForTesting` set
    /// explicitly, same reason as above — without them this passed
    /// vacuously (nil either way, for a reason unrelated to `isLive`) on a
    /// runner with Reduce Motion on, or simply because this test host's own
    /// `NSApplication` is never active and no window it creates genuinely
    /// becomes key, without either ever actually exercising the `isLive`
    /// gate this test is named for.
    func testTheGlowIsNotCreatedWhenThePaneIsNotLive() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.reducedMotionForTesting = false
        view.isKeyWindowForTesting = true
        let window = show(view)
        defer { window.close() }
        let glass = try XCTUnwrap(view.composerField.superview)

        XCTAssertTrue(window.makeFirstResponder(view.composerField))
        XCTAssertNil(glowContainer(on: glass))
    }

    /// Reduce Motion's fallback is the border stroke alone
    /// (`testFocusingTheComposerStrokesTheGlass`); the glow itself must not
    /// be created at all. `ShellMotion.reduced` reads a live, global
    /// accessibility setting nothing here can flip, so `reducedMotionForTesting`
    /// is the seam that forces this path regardless of the test runner's own
    /// setting — see its doc comment in `PaneAppView.swift`.
    func testTheGlowIsNotCreatedUnderReduceMotion() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.isLive = true
        view.reducedMotionForTesting = true
        view.isKeyWindowForTesting = true
        let window = show(view)
        defer { window.close() }
        let glass = try XCTUnwrap(view.composerField.superview)

        XCTAssertTrue(window.makeFirstResponder(view.composerField))
        XCTAssertNil(glowContainer(on: glass), "no glow under Reduce Motion")
        XCTAssertEqual(glass.layer?.borderWidth, 1, "the stroke fallback still works")

        view.isLive = false
    }

    /// The fix for "sweeps as a bar rather than circling": a `CAGradientLayer`'s
    /// own *shape* rotates with its `transform`, so if the glow's bled,
    /// non-square rect were the layer that spins, it would sweep its own
    /// corners through the frame as it turns. Structurally, that means the
    /// container found by `glowContainer` must never itself carry the spin
    /// animation, must be masked by an even-odd `CAShapeLayer`, and the
    /// gradient inside it — the layer that *does* carry the spin — must be
    /// square and at least as large as the container's own diagonal, so no
    /// rotation angle can uncover a corner of the container it sits in.
    func testTheGlowMasksANonRotatingContainerRatherThanRotatingItsOwnShape() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.isLive = true
        view.reducedMotionForTesting = false
        view.isKeyWindowForTesting = true
        let window = show(view)
        defer { window.close() }
        let glass = try XCTUnwrap(view.composerField.superview)
        XCTAssertTrue(window.makeFirstResponder(view.composerField))

        let container = try XCTUnwrap(glowContainer(on: glass))
        XCTAssertNil(container.animation(forKey: "om-spin"), "the container itself never rotates")
        let mask = try XCTUnwrap(container.mask as? CAShapeLayer)
        XCTAssertEqual(mask.fillRule, .evenOdd)
        XCTAssertNotNil(mask.path, "a band, not the container's whole (unmasked) rect")

        let gradient = try XCTUnwrap(glowGradient(on: glass))
        XCTAssertNotNil(gradient.animation(forKey: "om-spin"), "the gradient inside it is what spins")
        XCTAssertEqual(gradient.frame.width, gradient.frame.height, accuracy: 0.5, "square")
        XCTAssertGreaterThanOrEqual(
            gradient.frame.width,
            hypot(container.frame.width, container.frame.height) - 0.5,
            "big enough that no rotation angle can uncover a corner of the container"
        )

        view.isLive = false
    }

    /// The halo must never bleed past the glass's own margin off the pane's
    /// bottom edge: `PaneWorkspaceView.roundChildren` masks every pane
    /// (this view included) to its own rounded rect, so bleed past that
    /// margin is a straight cut across the halo rather than a fade, at the
    /// pane's own edge.
    func testTheGlowNeverBleedsPastTheComposersOwnBottomMargin() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.isLive = true
        view.reducedMotionForTesting = false
        view.isKeyWindowForTesting = true
        let window = show(view)
        defer { window.close() }
        let glass = try XCTUnwrap(view.composerField.superview)
        XCTAssertTrue(window.makeFirstResponder(view.composerField))

        let container = try XCTUnwrap(glowContainer(on: glass))
        let bleed = glass.bounds.minY - container.frame.minY
        let margin = view.scrollView.contentInsets.bottom - glass.frame.height

        XCTAssertGreaterThan(bleed, 0, "the halo actually bleeds outward")
        XCTAssertLessThanOrEqual(bleed, margin, "never further than the glass's own bottom margin")

        view.isLive = false
    }

    /// A window resigning key runs none of this view's own focus callbacks
    /// (`HomeComposerField.onFocusChange` fires only from
    /// `textDidEndEditing`, which losing key status alone does not trigger)
    /// — so the glow's own gate has to check key status directly, and has
    /// to be re-evaluated when it changes, rather than trusting focus alone
    /// once and never again. Drives `isKeyWindowForTesting` directly rather
    /// than a real window's key status: confirmed directly (see that
    /// property's own doc comment) that no window this test host creates
    /// ever genuinely becomes key, `makeKeyAndOrderFront` included, since
    /// its `NSApplication` is never the active app under `xcodebuild test`.
    func testTheGlowStopsWhenTheWindowIsNoLongerKeyAndResumesWhenItIsAgain() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.isLive = true
        view.reducedMotionForTesting = false
        view.isKeyWindowForTesting = true
        let window = show(view)
        defer { window.close() }
        let glass = try XCTUnwrap(view.composerField.superview)
        XCTAssertTrue(window.makeFirstResponder(view.composerField))
        XCTAssertNotNil(glowContainer(on: glass), "focused, live, key: the glow is up")

        view.isKeyWindowForTesting = false
        XCTAssertNil(glowContainer(on: glass), "and it stops when the window is no longer key, even though focus never changed")

        view.isKeyWindowForTesting = true
        XCTAssertNotNil(glowContainer(on: glass), "and resumes when it becomes key again")

        view.isLive = false
    }

    /// Structural, not visual: confirms the mask's and the gradient's
    /// blurs are the one deliberate number `composerGlowBlurRadius`
    /// documents, chosen small enough to fit inside the band it lives in
    /// (`composerGlowBleed`) rather than being clipped by it — not that the
    /// result actually *reads* as a soft out-of-focus halo, which nothing
    /// short of a human looking at it can judge.
    func testTheGlowsBlurRadiusFitsWithinTheBandItSoftens() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.isLive = true
        view.reducedMotionForTesting = false
        view.isKeyWindowForTesting = true
        let window = show(view)
        defer { window.close() }
        let glass = try XCTUnwrap(view.composerField.superview)
        XCTAssertTrue(window.makeFirstResponder(view.composerField))

        let container = try XCTUnwrap(glowContainer(on: glass))
        let mask = try XCTUnwrap(container.mask as? CAShapeLayer)
        let gradient = try XCTUnwrap(glowGradient(on: glass))
        let maskBlur = try XCTUnwrap(mask.filters?.first as? CIFilter)
        let gradientBlur = try XCTUnwrap(gradient.filters?.first as? CIFilter)
        let maskRadius = try XCTUnwrap(maskBlur.value(forKey: kCIInputRadiusKey) as? CGFloat)
        let gradientRadius = try XCTUnwrap(gradientBlur.value(forKey: kCIInputRadiusKey) as? CGFloat)
        let bleed = glass.bounds.minY - container.frame.minY

        XCTAssertEqual(maskRadius, gradientRadius, "one deliberate number, not two independent guesses")
        XCTAssertGreaterThan(maskRadius, 0, "actually blurred, not a hard edge")
        XCTAssertLessThanOrEqual(maskRadius, bleed, "the blur's own spread has to fit the band it lives in")

        view.isLive = false
    }

    /// A live pane resize calls `layout()`, and so `layOutComposerGlow`,
    /// every frame — rebuilding the mask's path and `CIFilter` on every one
    /// of them would be wasteful when the band's size has not actually
    /// changed, so the mask must be reused (same object) across an
    /// unrelated layout pass and only replaced when the size genuinely
    /// moves.
    func testTheGlowsMaskIsRebuiltOnlyWhenTheBandsSizeChanges() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.isLive = true
        view.reducedMotionForTesting = false
        view.isKeyWindowForTesting = true
        let window = show(view)
        defer { window.close() }
        let glass = try XCTUnwrap(view.composerField.superview)
        XCTAssertTrue(window.makeFirstResponder(view.composerField))
        let container = try XCTUnwrap(glowContainer(on: glass))
        let firstMask = try XCTUnwrap(container.mask)

        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(container.mask === firstMask, "an unrelated layout pass must not rebuild an unchanged band")

        view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(container.mask === firstMask, "the band actually shrank, so the mask must be rebuilt")

        view.isLive = false
    }

    /// These are plain data layers this view drives by hand every layout
    /// pass, not view-backed layers reacting to a user gesture — without
    /// `CATransaction.setDisableActions(true)` in `layOutComposerGlow`,
    /// Core Animation's own default 0.25s implicit action would fire on
    /// `container`'s frame every time a pane resize moves it, and the halo
    /// would visibly lag the glass rather than tracking it. Verifiable
    /// structurally (no implicit animation got attached); whether the
    /// result actually tracks smoothly on screen is not.
    func testTheGlowsFrameDoesNotPickUpAnImplicitAnimationAcrossAResize() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.isLive = true
        view.reducedMotionForTesting = false
        view.isKeyWindowForTesting = true
        let window = show(view)
        defer { window.close() }
        let glass = try XCTUnwrap(view.composerField.superview)
        XCTAssertTrue(window.makeFirstResponder(view.composerField))
        let container = try XCTUnwrap(glowContainer(on: glass))

        view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        view.layoutSubtreeIfNeeded()

        XCTAssertNil(container.animation(forKey: "position"), "setDisableActions must suppress the implicit frame action")
        XCTAssertNil(container.animation(forKey: "bounds"))

        view.isLive = false
    }

    /// The container `updateComposerGlow` inserts directly on
    /// `composerGlass.layer` — found by its `CAShapeLayer` mask, which
    /// nothing else on this glass ever sets, the same idiom
    /// `PaneWorkspaceViewTests` uses to find `updateWorkingRing`'s layer.
    private func glowContainer(on glass: NSView) -> CALayer? {
        glass.layer?.sublayers?.first { $0.mask is CAShapeLayer }
    }

    /// The spinning gradient inside `glowContainer(on:)`.
    private func glowGradient(on glass: NSView) -> CAGradientLayer? {
        glowContainer(on: glass)?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
    }

    /// Attach puts the path into the draft, which is what the transport can
    /// carry and what Claude Code already understands.
    func testAttachInsertsThePathIntoTheDraft() {
        let view = makeView()
        view.composerField.stringValue = "look at"
        view.insertAttachment(path: "/tmp/a.swift")

        XCTAssertEqual(view.composerField.stringValue, "look at /tmp/a.swift")
    }

    func testAttachIntoAnEmptyDraftLeavesNoLeadingSpace() {
        let view = makeView()
        view.insertAttachment(path: "/tmp/a.swift")

        XCTAssertEqual(view.composerField.stringValue, "/tmp/a.swift")
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

    // MARK: - The reader → view seam

    /// Two facts about the very first tick, both asserted synchronously and
    /// neither of them timing-dependent.
    ///
    /// It goes out in the same turn as `isLive`: a repeating `Timer` alone
    /// first fires one interval in, which is a third of a second of "Nothing
    /// yet." on every switch into App view before the whole conversation pops
    /// in at once.
    ///
    /// And when that assignment returns, nothing must have been resolved yet.
    /// `ClaudeModel.resolvedTranscriptURL` lists `~/.claude/projects` and
    /// stats a candidate under every directory in it — ~40 syscalls, repeated
    /// on every tick for as long as the transcript has not appeared — which
    /// `EngineModel`'s own header (`EngineLauncher.swift`) forbids on the main
    /// thread. The reader is built out of that resolution, so a reader
    /// standing here already is proof the syscalls ran here too.
    func testTheFirstPollFiresAtOnceAndResolvesTheTranscriptOffTheMainThread() throws {
        let (view, transcript) = try makeViewOnATempTranscript()
        try write([row("r1", "hello")], to: transcript)

        view.isLive = true
        XCTAssertTrue(view.pollInFlight, "the first tick goes out with isLive, not 0.3s behind it")
        XCTAssertNil(view.reader, "and nothing stat'd ~/.claude on this thread to build one")

        waitForPoll(in: view)
        view.isLive = false

        XCTAssertNotNil(view.reader, "resolved by the time the poll lands — on the background queue")
        XCTAssertEqual(rowTexts(of: view), ["hello"])
    }

    /// The shrink join, which nothing crossed before this: the reader answers
    /// a rewritten transcript by re-reading it from byte zero
    /// (`ClaudeTranscriptTests.testFileShrinkingResetsAndRereadsFromTheStart`),
    /// and this view never removed a row — so without the reset signal the
    /// stale conversation stayed on screen with the rewritten one appended
    /// beneath it. Reachable whenever Claude compacts or `/clear`s while the
    /// App view is up.
    func testARewrittenTranscriptReplacesTheConversationRatherThanDoublingIt() throws {
        let (view, transcript) = try makeViewOnATempTranscript()
        let opening = ["the first message", "the second message"]
        // Alternating roles: two same-role rows would merge into one turn
        // (Task 2) and this test is about row *count* surviving a reset, not
        // about grouping.
        try write([row("one", opening[0]), row("two", opening[1], isUser: false)], to: transcript)

        view.isLive = true
        waitForPoll(in: view) { !rowTexts(of: $0).isEmpty }
        XCTAssertEqual(rowTexts(of: view), opening)

        // Replaced whole and shorter than the reader's offset — what
        // compaction leaves behind.
        try write([row("one", "compacted")], to: transcript)
        waitForPoll(in: view) { rowTexts(of: $0) != opening }
        view.isLive = false

        XCTAssertEqual(
            rowTexts(of: view), ["compacted"],
            "the rewritten transcript replaces the conversation; it is not appended to it"
        )
    }

    /// A poll that lands after the pane has gone down must keep its messages.
    /// `poll()` advanced the reader's byte offset on the background queue, so
    /// rows dropped on the way in are gone for the reader's life — which is
    /// the pane's life — leaving a hole in the middle of the conversation that
    /// nothing can refill. And a pane goes down mid-read routinely rather than
    /// by a millisecond race: `camera`'s didSet runs a visibility pass per
    /// pinch event, so any zoom-out over a live App view is a candidate.
    func testAPollLandingAfterThePaneGoesDownKeepsItsMessages() throws {
        let (view, transcript) = try makeViewOnATempTranscript()
        let both = ["the first message", "the second message"]
        // Alternating roles: two same-role rows would merge into one turn
        // (Task 2) and this test is about both rows surviving a mid-read
        // pane teardown, not about grouping.
        try write([row("one", both[0]), row("two", both[1], isUser: false)], to: transcript)

        view.isLive = true
        XCTAssertTrue(view.pollInFlight, "the read is out on the background queue")

        // The pinch: the visibility pass flips this false and stops the timer,
        // while that read is already past `poll()`.
        view.isLive = false
        XCTAssertNil(view.pollTimer, "so nothing will ever poll again to re-offer these rows")

        waitForPoll(in: view)
        XCTAssertEqual(
            rowTexts(of: view), both,
            "rows the reader already consumed have nowhere else to come from"
        )
    }

    // MARK: - Polling helpers

    /// A real view over a transcript this test owns: a `~/.claude` tree under
    /// a temp home, so the view finds the file through
    /// `ClaudeModel.resolvedTranscriptURL` exactly as it does in the app,
    /// rather than being handed a URL no production path would produce.
    private func makeViewOnATempTranscript() throws -> (view: PaneAppView, transcript: URL) {
        let home = tempDirectory.appendingPathComponent("home")
        let cwd = "/tmp/pane-app-view-polling"
        let sessionID = "polling-session"
        let url = ClaudeModel.transcriptURL(sessionID: sessionID, cwd: cwd, home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let view = PaneAppView(sessionID: sessionID, cwd: cwd, home: home)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        return (view, url)
    }

    /// Waits for a poll cycle to land — an event, not a sleep: `onPollLanded`
    /// fires on the main queue at the end of every cycle, whatever it found.
    /// `until` picks the *right* cycle, since the timer goes on firing every
    /// 0.3s and a poll that finds nothing new lands too.
    private func waitForPoll(
        in view: PaneAppView,
        until predicate: @escaping (PaneAppView) -> Bool = { _ in true }
    ) {
        let landed = expectation(description: "a poll cycle lands")
        // Cycles behind the one being waited for are not an API violation.
        landed.assertForOverFulfill = false
        view.onPollLanded = { [weak view] in
            guard let view, predicate(view) else { return }
            landed.fulfill()
        }
        wait(for: [landed], timeout: 5)
        view.onPollLanded = nil
    }

    /// Atomically, because that is how a compacted transcript arrives: the
    /// file at this path is replaced whole rather than edited in place.
    private func write(_ rows: [String], to url: URL) throws {
        try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// `isUser` defaults to `true` for every existing call site that only
    /// ever wrote one role. Two rows written with the same role now merge
    /// into one `TranscriptTurn` (Task 2) — a caller after two *distinct*
    /// rows must alternate it, the same way a real transcript alternates a
    /// prompt and a reply.
    private func row(_ id: String, _ text: String, isUser: Bool = true) -> String {
        let type = isUser ? "user" : "assistant"
        return #"{"type":"\#(type)","uuid":"\#(id)","isSidechain":false,"message":{"content":"\#(text)"}}"#
    }

    // MARK: - Scroll pinning

    /// A user who has scrolled up to read earlier messages must not be
    /// yanked back down by a reply arriving behind their back —
    /// `isScrolledToBottom()` is measured before a single row is appended, so
    /// a scroll position set between appends must survive later ones
    /// untouched.
    ///
    /// This is a *third*-call test, not a second-call one, on purpose: it is
    /// the regression guard for a real bug self-review found and fixed in
    /// this exact path (`appendMessages` originally forced layout only
    /// inside its `wasAtBottom` branch, leaving `messageStack`'s height stale
    /// for the *next* call's measurement). A second call cannot catch that
    /// bug — its own `isScrolledToBottom()` reads against whatever the
    /// *first* call already laid out, and the first call is always trivially
    /// "at bottom" against an empty list, so layout runs regardless of the
    /// bug. The staleness only becomes observable at a third call, measuring
    /// against a height the second call left stale under the bug. Verified
    /// by temporarily reverting the fix: this test failed against the
    /// reverted code and passes against the fix (see the task report).
    func testAppendingWhileScrolledUpLeavesThePositionUnchangedAcrossAThirdAppend() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)

        // Nothing on screen yet, so this first append is trivially "at
        // bottom" — accurate under the historical bug too, which only ever
        // skipped the *non*-"at bottom" branch.
        view.appendMessages(manyMessages(count: 10, startingAt: 0))
        let clip = try scrollClipView(in: view)
        let heightAfterFirstBatch = try messageStackHeight(in: view)

        // Scroll well clear of the bottom before the second append, so its
        // own `isScrolledToBottom()` reads false and — under the reverted
        // bug — skips the layout pass that would otherwise refresh
        // `messageStack.frame.height`.
        clip.scroll(to: .zero)
        view.appendMessages(manyMessages(count: 10, startingAt: 10))
        XCTAssertEqual(clip.bounds.origin, .zero, "still scrolled up after the second append")

        // Reposition to exactly where the first append's bottom was. Read
        // against a *stale* height (unchanged since the first append) this
        // looks like "at bottom"; read against the *true* height (grown by
        // the second append's rows) it does not — exactly the discrepancy
        // the historical bug produced.
        clip.scroll(to: NSPoint(x: 0, y: max(0, heightAfterFirstBatch - clip.bounds.height)))
        let positionBeforeThirdAppend = clip.bounds.origin

        view.appendMessages(manyMessages(count: 10, startingAt: 20))
        XCTAssertEqual(
            clip.bounds.origin, positionBeforeThirdAppend,
            "a user who was not at the true bottom must not be yanked down by a third append"
        )
    }

    /// The complementary case: a user already at the bottom follows new
    /// messages down — all the way down.
    ///
    /// "The bottom" is the end of the *scrollable range*, not the document's
    /// bottom edge: `contentInsets.bottom` pads the range by the glass
    /// composer's height precisely so the last row can travel past it.
    /// Pinning `clip.bounds.maxY` to the document height alone (which this
    /// test did until the whole-branch review) asserts the exact position
    /// that leaves the newest reply sitting under the composer, and is why
    /// that bug shipped.
    func testAppendingWhileAtTheBottomScrollsToTheBottom() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        view.appendMessages(manyMessages(count: 10, startingAt: 0))

        let clip = try scrollClipView(in: view)
        let inset = view.scrollView.contentInsets.bottom
        XCTAssertGreaterThan(inset, 40, "the composer's clearance is what makes this test mean anything")
        let documentHeight = try messageStackHeight(in: view)
        XCTAssertEqual(
            clip.bounds.maxY, documentHeight + inset, accuracy: 1,
            "the initial append (nothing on screen yet) scrolls to the bottom"
        )

        view.appendMessages(manyMessages(count: 10, startingAt: 10))
        let newDocumentHeight = try messageStackHeight(in: view)
        XCTAssertGreaterThan(newDocumentHeight, documentHeight, "the second batch must actually have grown the content")
        XCTAssertEqual(
            clip.bounds.maxY, newDocumentHeight + inset, accuracy: 1,
            "still at the bottom, so the second append follows the new messages down"
        )
    }

    /// What the inset is *for*, asserted where a reader can see it: after an
    /// append that follows the conversation down, the last row's bottom edge
    /// is clear of the glass composer rather than behind it.
    ///
    /// Measured in the view's own coordinates against the glass's real frame,
    /// so it holds whatever the composer's height works out to. Under the
    /// pre-review `scrollToBottom` this row's bottom sat at y = 0 — a whole
    /// clearance under the glass.
    func testTheNewestRowScrollsClearOfTheComposer() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        view.appendMessages(manyMessages(count: 10, startingAt: 0))

        let glass = try XCTUnwrap(view.composerField.superview)
        let lastRow = try XCTUnwrap(view.descendants(PaneAppMessageRowView.self).last)
        let rowInView = lastRow.convert(lastRow.bounds, to: view)

        XCTAssertGreaterThanOrEqual(
            rowInView.minY, glass.frame.maxY - 1,
            "the newest message must not park under the composer"
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

    /// A full layout pass at a real pane size, with one message of every kind
    /// this view knows how to draw — prose, a heading, a list, a fenced code
    /// block, a table, an inline single tool call and a collapsed work group
    /// — behind the glass composer, neither throws nor collapses. Drops a PNG
    /// when `PANE_RENDER_DIR` is set
    /// (`TEST_RUNNER_PANE_RENDER_DIR=/tmp/pane-app ./macos/build.sh test`).
    ///
    /// The fixture is deliberately the whole vocabulary: this is the only
    /// test that lays every block kind out together at a real width, so a
    /// constraint that only conflicts in company shows up here or nowhere.
    func testTheAppViewLaysOutOffscreen() throws {
        let view = makeView()
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        view.appendMessages([
            TranscriptMessage(id: "1", isUser: true, blocks: [.text("Can you check the build?")]),
            TranscriptMessage(id: "2", isUser: false, blocks: [
                .text("""
                Sure — running it now. Here's the **relevant** bit:

                ## Findings

                - the scanner keeps its fences
                - the table lines up

                ```swift
                let x = 1
                ```

                | target | tests |
                |---|---|
                | OmniAgent | 1280 |
                | mcp-server | 42 |
                """),
                .tool(name: "Read", detail: "macos/OmniAgent/PaneAppView.swift"),
                .text("Then the suite:"),
                .tool(name: "Bash", detail: "./macos/build.sh test"),
                .tool(name: "Bash", detail: "git status --short"),
            ]),
        ])
        let window = show(view)
        defer { window.close() }

        // The vocabulary really is all on screen — a fixture that silently
        // stopped producing a group or a table would still render.
        XCTAssertEqual(view.descendants(PaneAppWorkGroupView.self).count, 1, "the two Bash calls")
        let labels = view.descendants(NSTextField.self).map(\.stringValue)
        XCTAssertTrue(labels.contains { $0.contains("─") }, "the table's rule row")
        XCTAssertTrue(labels.contains("▸ Read  macos/OmniAgent/PaneAppView.swift"), "the inline single call")

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
    ///
    /// `view` is added to a plain, unconstrained *host* rather than made the
    /// window's own `contentView` directly — the same shape
    /// `PaneContainerView.applyLayout` actually embeds `PaneAppView` in
    /// (`appView?.frame = surface.frame`, an ordinary `addSubview`, never an
    /// `NSLayoutConstraint` from the superview). Confirmed the hard way: with
    /// `view` *as* `contentView`, `messageStack`/`composerGlass`'s new
    /// `.defaultHigh` 880pt column preference gives `NSWindow` something to
    /// resize the whole window to fit, and both the window and `view` balloon
    /// out past whatever frame the test set — a resize that never happens
    /// through a host with no Auto Layout constraints of its own reaching
    /// into `view`, exactly like the real container.
    private func show(_ view: NSView) -> NSWindow {
        let host = NSView(frame: view.frame)
        host.addSubview(view)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
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

/// What the conversation reads as on screen, one string per row, the role
/// label aside — which is where a duplicated conversation becomes visible.
/// A free function rather than a method so the escaping poll predicates can
/// use it without capturing the test case.
private func rowTexts(of view: PaneAppView) -> [String] {
    view.descendants(PaneAppMessageRowView.self).map { row in
        row.descendants(NSTextField.self).dropFirst().map(\.stringValue).joined(separator: " ")
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

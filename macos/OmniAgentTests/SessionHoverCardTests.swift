import AppKit
import SwiftTerm
import XCTest

@testable import OmniAgent

/// The sidebar's hover card: the activity ledger behind "since when", the
/// wording, the typed-out output line, and where the panel lands.
final class SessionHoverCardTests: XCTestCase {
    private let t0: Double = 1_700_000_000_000

    // MARK: - The ledger

    /// thinking -> tool -> thinking is one run of work. The card says "started
    /// 20:14", and it has to mean the moment the agent picked the task up, not
    /// the last time it hopped between two busy states.
    func testOneRunSurvivesHoppingBetweenThinkingAndTools() throws {
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        ledger.record(paneID: "a", status: .toolExecution, at: t0 + 5_000)
        ledger.record(paneID: "a", status: .thinking, at: t0 + 9_000)

        let activity = try XCTUnwrap(ledger.activity(for: "a"))
        XCTAssertEqual(activity.busySince, t0)
        XCTAssertEqual(activity.runMs(now: t0 + 12_000), 12_000)
    }

    /// The run ends when the pane settles, and its time is banked.
    func testActiveTimeAccumulatesAcrossRuns() {
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        ledger.record(paneID: "a", status: .ready, at: t0 + 10_000)
        ledger.record(paneID: "a", status: .thinking, at: t0 + 30_000)

        let activity = ledger.activity(for: "a")
        XCTAssertEqual(activity?.settledActiveMs, 10_000)
        // 10s banked, plus 5s of the run in progress.
        XCTAssertEqual(activity?.activeMs(now: t0 + 35_000), 15_000)
        XCTAssertEqual(activity?.runMs(now: t0 + 35_000), 5_000)
    }

    /// A settled pane has no clock running — a card that updates ten times a
    /// second showing a frozen duration reads as broken.
    func testASettledPaneHasNoRunningClock() {
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        ledger.record(paneID: "a", status: .ready, at: t0 + 4_000)

        XCTAssertNil(ledger.activity(for: "a")?.busySince)
        XCTAssertNil(ledger.activity(for: "a")?.runMs(now: t0 + 9_000))
        XCTAssertNil(HoverCardModel.timingLine(ledger.activity(for: "a"), now: t0 + 9_000))
    }

    /// The daemon repeats a status freely. A repeat must not restart the clock
    /// or count a second tool run.
    func testARepeatedStatusChangesNothing() {
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .toolExecution, at: t0)
        ledger.record(paneID: "a", status: .toolExecution, at: t0 + 3_000)
        ledger.record(paneID: "a", status: .toolExecution, at: t0 + 6_000)

        XCTAssertEqual(ledger.activity(for: "a")?.busySince, t0)
        XCTAssertEqual(ledger.activity(for: "a")?.toolRuns, 1)
    }

    func testEveryTripToAToolIsCounted() {
        var ledger = PaneActivityLedger()
        for step in 0..<3 {
            ledger.record(paneID: "a", status: .thinking, at: t0 + Double(step) * 2_000)
            ledger.record(paneID: "a", status: .toolExecution, at: t0 + Double(step) * 2_000 + 500)
        }
        XCTAssertEqual(ledger.activity(for: "a")?.toolRuns, 3)
    }

    /// A closed pane takes its history with it — a ledger that only grows is a
    /// leak with a slow fuse.
    func testAClosedPaneIsForgotten() {
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        ledger.forget(paneID: "a")
        XCTAssertNil(ledger.activity(for: "a"))

        // And forgetting really clears the status memory, not just the counts:
        // the next run starts its own clock.
        ledger.record(paneID: "a", status: .thinking, at: t0 + 60_000)
        XCTAssertEqual(ledger.activity(for: "a")?.busySince, t0 + 60_000)
    }

    // MARK: - The wording

    func testDurationsReadAsTheDesignWritesThem() {
        XCTAssertEqual(HoverCardModel.duration(9_000), "9s")
        XCTAssertEqual(HoverCardModel.duration(252_000), "4m 12s")
        XCTAssertEqual(HoverCardModel.duration(3_840_000), "1h 04m")
    }

    func testTheTailIsTheBeginningOfTheLineAndAnEllipsis() {
        let long = String(repeating: "x", count: 100)
        let snipped = HoverCardModel.snippet(long)
        XCTAssertEqual(snipped?.count, HoverCardModel.tailLimit + 1)
        XCTAssertTrue(snipped?.hasSuffix("…") ?? false)
        // Short enough to fit keeps its own ending.
        XCTAssertEqual(HoverCardModel.snippet("  Editing the parser  "), "Editing the parser")
        XCTAssertNil(HoverCardModel.snippet("   "))
    }

    /// Tokens are not in this line, deliberately: nothing in the native app
    /// counts them, and a number the app cannot know is worse than no number.
    func testTotalsCountToolRuns() {
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        ledger.record(paneID: "a", status: .toolExecution, at: t0 + 1_000)

        let totals = HoverCardModel.totalsLine(ledger.activity(for: "a"), now: t0 + 60_000)
        XCTAssertEqual(totals, "1 tool run")

        ledger.record(paneID: "a", status: .thinking, at: t0 + 61_000)
        ledger.record(paneID: "a", status: .toolExecution, at: t0 + 62_000)
        XCTAssertEqual(
            HoverCardModel.totalsLine(ledger.activity(for: "a"), now: t0 + 120_000),
            "2 tool runs"
        )
        // The active total is deliberately absent: the timing line above is
        // already a clock, and the same fact twice is noise.
        XCTAssertFalse(totals?.contains("active") ?? false)
        // Nothing has happened yet -> nothing to say.
        XCTAssertNil(HoverCardModel.totalsLine(nil, now: t0))
    }

    func testAWorkingTerminalSaysWhenItStartedAndForHowLong() {
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        let model = HoverCardModel.pane(
            terminal(),
            status: .thinking,
            activity: ledger.activity(for: "a"),
            tail: "Editing SessionConnection.swift and a great deal more besides",
            now: t0 + 252_000
        )

        XCTAssertEqual(model.status, "Working")
        XCTAssertEqual(model.accent, ShellPalette.blue)
        XCTAssertTrue(model.pulses)
        XCTAssertTrue(model.mark)
        XCTAssertEqual(model.timing, "started \(HoverCardModel.clock(t0)) · 4m 12s")
        XCTAssertEqual(model.engine, .claude)
        XCTAssertEqual(model.tail?.count, HoverCardModel.tailLimit + 1)
    }

    /// Ready is the mark alone, green: the card saying "nothing running"
    /// without spending a word on it. The last line an idle pane printed is not
    /// news, and a mark pulsing beside it would be a lie.
    func testAReadyTerminalIsTheMarkAloneAndNoOutputLine() {
        let model = HoverCardModel.pane(
            terminal(),
            status: .ready,
            activity: nil,
            tail: "Editing SessionConnection.swift",
            now: t0
        )
        XCTAssertEqual(model.status, "Ready")
        XCTAssertEqual(model.accent, ShellPalette.green)
        XCTAssertFalse(model.pulses)
        XCTAssertNil(model.timing)
        XCTAssertNil(model.totals)
        XCTAssertNil(model.tail, "settled: no line, whatever the terminal still shows")
        XCTAssertTrue(model.mark, "but the mark is there, green")
    }

    /// And the body follows it: the row stays, the words go.
    func testTheWorkingLineIsAMarkWithWordsAndThenAMarkWithout() {
        let body = HoverCardBodyView()
        body.tailField.animates = false

        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        body.apply(
            HoverCardModel.pane(
                terminal(),
                status: .thinking,
                activity: ledger.activity(for: "a"),
                tail: "Building modal rename component",
                now: t0 + 1_000
            )
        )
        XCTAssertFalse(body.tailField.isHidden)
        XCTAssertEqual(body.tailField.typedText, "Building modal rename component")
        XCTAssertEqual(body.workingMark.contentTintColor, ShellPalette.blue)
        XCTAssertEqual(body.tailField.textColor, ShellPalette.blue, "the working line is blue")
        XCTAssertNotNil(body.workingMark.layer?.animation(forKey: "om-pulse") ?? nil)

        body.apply(HoverCardModel.pane(terminal(), status: .ready, activity: nil, now: t0))
        XCTAssertTrue(body.tailField.isHidden, "ready is the mark alone")
        XCTAssertEqual(body.workingMark.contentTintColor, ShellPalette.green)
        XCTAssertNil(body.workingMark.layer?.animation(forKey: "om-pulse") ?? nil, "and it is still")
    }

    func testAWaitingTerminalSaysSo() {
        let model = HoverCardModel.pane(terminal(), status: .awaitingApproval, activity: nil, now: t0)
        XCTAssertEqual(model.status, "Waiting for you")
        XCTAssertEqual(model.accent, ShellPalette.amber)
    }

    /// Editors and browsers have no engine, no status and no output — they get
    /// the card too, saying what they actually hold.
    func testEditorAndBrowserCardsShowWhatTheyHold() {
        var editor = EditorPaneModel()
        editor.open(path: "/Users/x/Code/thing/main.swift", kind: .file, asPreview: false)
        editor.open(path: "/Users/x/Code/thing/other.swift", kind: .file, asPreview: false)
        editor.setDirty(true, at: 1)

        let editorPane = PaneDescriptor(sessionID: "e", group: "g", title: "main.swift", kind: .editor)
        let editorCard = HoverCardModel.pane(editorPane, status: nil, activity: nil, editor: editor, now: t0)
        XCTAssertEqual(editorCard.status, "Editor")
        XCTAssertFalse(editorCard.mark, "an editor has no agent, so nothing to mark")
        XCTAssertEqual(editorCard.totals, "2 tabs · 1 unsaved")
        XCTAssertEqual(editorCard.accent, ShellPalette.amber, "unsaved work is the one thing worth a colour")
        XCTAssertNil(editorCard.tail)

        let browserPane = PaneDescriptor(
            sessionID: "b",
            group: "g",
            title: "Example",
            kind: .browser,
            browserURL: "https://example.com/x"
        )
        let browserCard = HoverCardModel.pane(browserPane, status: nil, activity: nil, now: t0)
        XCTAssertEqual(browserCard.status, "Browser")
        XCTAssertEqual(browserCard.meta, "https://example.com/x")
        XCTAssertNil(browserCard.engine)
    }

    /// A session summarises its panes, worst state first: asking beats
    /// working beats done, the same order its row's dots read in.
    func testASessionSummarisesItsPanes() {
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        ledger.record(paneID: "b", status: .thinking, at: t0 + 60_000)

        let panes = ["a", "b", "c"].reduce(into: [String: PaneDescriptor]()) { out, id in
            out[id] = PaneDescriptor(sessionID: id, group: "s", engine: .claude, cwd: "/Users/x/Code")
        }
        let node = SessionGroupNode(
            id: "s",
            project: "p",
            name: "Refactor",
            label: "Refactor",
            cwd: "/Users/x/Code",
            paneIDs: ["a", "b", "c"],
            isCurrent: true
        )

        let working = HoverCardModel.session(
            node,
            panes: panes,
            statuses: ["a": .thinking, "b": .toolExecution, "c": .ready],
            ledger: ledger,
            now: t0 + 120_000
        )
        XCTAssertEqual(working.status, "2 terminals are working")
        XCTAssertEqual(working.accent, ShellPalette.blue)
        XCTAssertEqual(working.totals, "3 panes · 2 working · 1 ready")
        // The *longest* run, not the newest: 2m, not 1m.
        XCTAssertEqual(working.timing, "working 2m 0s")

        let waiting = HoverCardModel.session(
            node,
            panes: panes,
            statuses: ["a": .thinking, "b": .awaitingApproval, "c": .ready],
            ledger: ledger,
            now: t0 + 120_000
        )
        XCTAssertEqual(waiting.status, "1 terminal is waiting")
        XCTAssertEqual(waiting.accent, ShellPalette.amber, "something asking outranks something working")
    }

    // MARK: - The typing

    /// The whole point of the effect: a line that changes keeps whatever it
    /// shares with the new one and retypes only the difference.
    func testTypingKeepsTheCommonPrefixAndRetypesTheRest() {
        let field = TypingTextField(font: ShellFont.mono(11.5), color: .white)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 16)

        field.animates = false
        field.setLine("Editing SessionConnect…")
        XCTAssertEqual(field.typedText, "Editing SessionConnect…")

        field.animates = true
        field.setLine("Editing SessionOutline…")
        XCTAssertEqual(field.typedText, "Editing Session", "only the divergent tail is erased")
        XCTAssertTrue(field.isTyping)

        // And it gets there: 600 chars/s finishes a 23-character line well
        // inside a fifth of a second.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(field.typedText, "Editing SessionOutline…")
        XCTAssertFalse(field.isTyping)
    }

    func testAnUnchangedLineIsNotRetyped() {
        let field = TypingTextField(font: ShellFont.mono(11.5), color: .white)
        field.animates = false
        field.setLine("Running tests")
        field.animates = true
        field.setLine("Running tests")
        XCTAssertFalse(field.isTyping)
        XCTAssertEqual(field.typedText, "Running tests")
    }

    /// Switching rows is a different sentence — continuing the type would
    /// splice two panes' output into one.
    func testResetDropsWhatWasOnScreen() {
        let field = TypingTextField(font: ShellFont.mono(11.5), color: .white)
        field.animates = false
        field.setLine("Editing a.swift")
        field.reset()
        XCTAssertEqual(field.typedText, "")
        field.animates = true
        field.setLine("Editing b.swift")
        XCTAssertEqual(field.typedText, "", "a fresh row types from nothing, not from the last one")
    }

    // MARK: - The panel

    /// Top-aligned with its row, off the sidebar's edge, and never outside the
    /// window — a card hanging off the bottom of the screen is a bug you only
    /// see on the last row.
    func testThePanelSitsBesideItsRowAndStaysInsideTheWindow() {
        let window = NSRect(x: 100, y: 100, width: 1_200, height: 800)
        let size = SessionHoverCardController.panelSize(card: NSSize(width: 280, height: 140))
        XCTAssertEqual(size.width, 280 + HoverCardShellView.lane, "the drop gets a lane of its own")

        let row = NSRect(x: 110, y: 500, width: 238, height: 26)
        let middle = SessionHoverCardController.frame(size: size, row: row, container: window)
        // The *card* sits `gap` past the row; the lane it points across is to
        // the left of that.
        XCTAssertEqual(middle.minX + HoverCardShellView.lane, 348 + SessionHoverCardController.gap)
        // And the tip is level with the row's centre — where its icon is, both
        // being centred on it. This is the alignment the card is placed from.
        XCTAssertEqual(middle.maxY - HoverCardShellView.tipInset, row.midY, accuracy: 0.01)
        XCTAssertEqual(
            middle.minY + HoverCardShellView(frame: NSRect(origin: .zero, size: middle.size))
                .dropFrame(centerY: row.midY - middle.minY).midY,
            row.midY,
            accuracy: 0.01,
            "and the head is not clamped away from it"
        )

        // A row at the very bottom pushes the card up rather than off.
        let low = SessionHoverCardController.frame(
            size: size,
            row: NSRect(x: 110, y: 104, width: 238, height: 26),
            container: window
        )
        XCTAssertEqual(low.minY, window.minY + 8)
        XCTAssertTrue(window.contains(low))

        // And a window too narrow to hold the card beside the row still keeps
        // it on screen.
        let tight = SessionHoverCardController.frame(
            size: size,
            row: NSRect(x: 110, y: 500, width: 238, height: 26),
            container: NSRect(x: 100, y: 100, width: 420, height: 800)
        )
        XCTAssertEqual(tight.maxX, 520 - 8)
    }

    /// The drop is what says which row the card belongs to, so it has to track
    /// the row's centre — and stay off the card's own corners, where the merge
    /// would leave from a curve instead of a straight edge.
    func testTheDropPointsAtTheRowAndKeepsOffTheCorners() {
        let shell = HoverCardShellView(frame: NSRect(x: 0, y: 0, width: 300, height: 140))
        shell.layoutSubtreeIfNeeded()

        let middle = shell.dropFrame(centerY: 70)
        XCTAssertEqual(middle.midY, 70)
        XCTAssertEqual(
            middle.maxX + HoverCardShellView.neck,
            HoverCardShellView.lane,
            accuracy: 0.01,
            "the head sits a neck's width from the card"
        )
        XCTAssertGreaterThan(middle.minX, 0, "and inside the panel, or the bridge is clipped")

        // A row level with the very top of the card pulls the head down to
        // where the card's edge is straight.
        let high = shell.dropFrame(centerY: 139)
        XCTAssertLessThan(high.midY, 139)
        XCTAssertGreaterThanOrEqual(high.midY, 140 - HoverCardShellView.tipInset - 0.01)

        // Animation off under Reduce Motion is the caller's business; pointing
        // is not.
        shell.pointDrop(at: 40, animated: false)
        XCTAssertEqual(shell.dropCenterY, 40)
    }

    /// Glance-only: the card can never swallow a click meant for the pane
    /// underneath it, and never takes key away from the terminal.
    func testTheCardNeverTakesTheMouse() throws {
        let controller = SessionHoverCardController()
        let panel = try XCTUnwrap(Mirror(reflecting: controller).children
            .first { $0.label == "panel" }?.value as? NSPanel)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(controller.isOpen)
        XCTAssertNil(controller.target)
    }

    /// Repo convention: verify AppKit layout by offscreen render. A working
    /// terminal's card is the tallest shape — every row on, tail included.
    func testOffscreenRender() throws {
        let body = HoverCardBodyView()
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        body.tailField.animates = false
        body.apply(
            HoverCardModel.pane(
                terminal(),
                status: .thinking,
                activity: ledger.activity(for: "a"),
                tail: "Editing SessionConnection.swift",
                now: t0 + 252_000
            )
        )
        let size = body.cardSize
        body.frame = NSRect(origin: .zero, size: size)
        body.layoutSubtreeIfNeeded()

        XCTAssertEqual(size.width, HoverCardBodyView.width)
        XCTAssertGreaterThan(size.height, 90, "five rows and a rule do not fit in less")

        let rep = try XCTUnwrap(body.bitmapImageRepForCachingDisplay(in: body.bounds))
        body.cacheDisplay(in: body.bounds, to: rep)
        XCTAssertTrue([280, 560].contains(rep.pixelsWide), "unexpected pixel width \(rep.pixelsWide)")
        XCTAssertGreaterThan(rep.pixelsHigh, 0)

        // A ready terminal has no timing and no totals — and in a stack view a
        // hidden row is genuinely gone, so the card is visibly shorter. The
        // mark row stays: that is the green mark, standing alone.
        body.apply(HoverCardModel.pane(terminal(), status: .ready, activity: nil, now: t0))
        XCTAssertLessThan(body.cardSize.height, size.height)
    }

    // MARK: - The output line

    /// What the card types: the bottom-most line with something readable on
    /// it, without the box the TUI draws around it.
    func testTheLastOutputLineSkipsTheFrameAndTheNulls() throws {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 60, rows: 8)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        terminal.feed(text: "\u{1b}[2;1HBuilding\u{1b}[2;11Hthe\u{1b}[2;15Hworkspace")
        terminal.feed(text: "\u{1b}[4;1H│\u{1b}[4;3HEditing\u{1b}[4;11HSessionConnection.swift\u{1b}[4;58H│")
        terminal.feed(text: "\u{1b}[5;1H╰────────────────────────────────────────────────────────╯")

        let line = try XCTUnwrap(TerminalSurfaceView.lastOutputLine(of: terminal))
        XCTAssertEqual(line, "Editing SessionConnection.swift")
        XCTAssertFalse(line.contains("\0"), "a NUL is a cell SwiftTerm never filled")
    }

    /// The bug this rule exists for: Claude's screen ends with its own
    /// furniture — an empty input box, a working directory, a context meter and
    /// `auto mode on` — none of which changes when the agent does anything. The
    /// card showed that. It has to show the last thing the agent actually did.
    /// The line the agent's own blinking bullet is on — including when the blink
    /// has it off screen this frame, which is half the time.
    func testTheOutputLineIsTheBulletsLineEvenWhileTheBulletIsBlinkedOff() throws {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 80, rows: 10)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        let screen = [
            "⏺ Now registering the new file with the Xcode project:",
            "",
            "  Building modal rename component; registering with Xcode · 1m 36s",
            "  └ $ cd macos && python3 - <<'PY'",
            "      p = \"OmniAgentTests/PaneWorkspaceViewTests.swift\"",
            "",
            "      still the tool's own output, not the agent's line",
            "",
            "› ",
        ]
        for (index, line) in screen.enumerated() {
            terminal.feed(text: "\u{1b}[\(index + 1);1H" + line)
        }

        XCTAssertEqual(
            TerminalSurfaceView.lastOutputLine(of: terminal),
            "Building modal rename component; registering with Xcode · 1m 36s",
            "the blinked-off bullet's line, not the tool output indented under it"
        )
    }

    /// A visible bullet with nothing under it is its own answer.
    func testTheBulletsOwnLineWinsWhenTheBlinkHasItOn() throws {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 60, rows: 6)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        terminal.feed(text: "\u{1b}[1;1H⏺ Reading EditorPaneView.swift")
        terminal.feed(text: "\u{1b}[2;1H⏺ Editing SessionHoverCard.swift")
        terminal.feed(text: "\u{1b}[4;1H› ")

        XCTAssertEqual(
            TerminalSurfaceView.lastOutputLine(of: terminal),
            "Editing SessionHoverCard.swift"
        )
    }

    func testTheOutputLineIsTheLastRealActionNotTheStatusBar() throws {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 90, rows: 20)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        let screen = [
            "● Now registering the new file with the Xcode project:",
            "",
            "  Building modal rename component; registering with Xcode · 1m 36s",
            "  └ $ cd macos && python3 - <<'PY'",
            "      p = \"OmniAgentTests/PaneWorkspaceViewTests.swift\"",
            "      s = open(p).read()",
            "      'PaneAsk… (1m 34s · 2 lines)",
            "      (ctrl+b to run in background)",
            "",
            "✳ Crystallizing… (5m 17s · ↓ 14.8k tokens)",
            "",
            "› ",
            "──────────────────────────────────────────────",
            "~/Documents/Bruno.Digital/OmniAgent-ADE                                    /rc",
            "Context   25%  Opus 5 (1M context)",
            "Session   11%  2h 0m left",
            "Week      65%  37h 20m left",
            "▶▶ auto mode on (shift+tab to cycle) · ← for agents",
        ]
        for (index, line) in screen.enumerated() {
            terminal.feed(text: "\u{1b}[\(index + 1);1H" + line)
        }

        XCTAssertEqual(
            TerminalSurfaceView.lastOutputLine(of: terminal),
            "Building modal rename component; registering with Xcode · 1m 36s"
        )
    }

    /// A plain shell has none of that furniture, and must not be second-guessed
    /// by rules written for one that does.
    func testAShellStillGetsItsLastLine() throws {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 60, rows: 6)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        terminal.feed(text: "\u{1b}[1;1Hcargo test --workspace")
        terminal.feed(text: "\u{1b}[2;1Htest result: ok. 812 passed; 0 failed")

        XCTAssertEqual(
            TerminalSurfaceView.lastOutputLine(of: terminal),
            "test result: ok. 812 passed; 0 failed"
        )
    }

    /// The agent's own bullet is a margin mark, not a word — the card shows the
    /// sentence.
    func testTheBulletIsNotPartOfTheSentence() throws {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 60, rows: 4)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        terminal.feed(text: "\u{1b}[1;1H● Reading SessionConnection.swift")
        terminal.feed(text: "\u{1b}[3;1H› ")

        XCTAssertEqual(
            TerminalSurfaceView.lastOutputLine(of: terminal),
            "Reading SessionConnection.swift"
        )
    }

    func testAnEmptyTerminalHasNoOutputLine() {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 40, rows: 6)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        XCTAssertNil(TerminalSurfaceView.lastOutputLine(of: terminal))
    }

    // MARK: - Helpers

    private final class SilentTerminalDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func terminal() -> PaneDescriptor {
        PaneDescriptor(
            sessionID: "a",
            group: "s",
            title: "auth-refactor",
            engine: .claude,
            cwd: NSHomeDirectory() + "/Code/thing"
        )
    }
}

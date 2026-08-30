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
        let long = String(repeating: "x", count: HoverCardModel.tailLimit + 40)
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
            tail: String(repeating: "Editing SessionConnection.swift. ", count: 8),
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

    /// Ready is the green mark and the word: the last line an idle pane printed
    /// is not news, and a mark pulsing beside it would be a lie about what the
    /// pane is doing.
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
        XCTAssertNil(model.tail, "settled: no output line, whatever the terminal still shows")
        XCTAssertTrue(model.mark, "but the mark is there, green, beside the word")
    }

    /// And the body follows it: the row stays, and says the state instead.
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
        XCTAssertEqual(body.tailField.typedText, "Ready", "the state in a word when there is no work")
        XCTAssertEqual(body.tailField.textColor, ShellPalette.green, "in the mark's own colour")
        XCTAssertEqual(body.workingMark.contentTintColor, ShellPalette.green)
        XCTAssertNil(body.workingMark.layer?.animation(forKey: "om-pulse") ?? nil, "and it is still")

        // Amber follows the same rule, so the card never has a state it can
        // show only as a colour.
        body.apply(HoverCardModel.pane(terminal(), status: .awaitingApproval, activity: nil, now: t0))
        XCTAssertEqual(body.tailField.typedText, "Waiting for you")
        XCTAssertEqual(body.tailField.textColor, ShellPalette.amber)
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
        let node = sessionNode(paneIDs: ["a", "b", "c"])

        let working = HoverCardModel.session(
            node,
            panes: panes,
            statuses: ["a": .thinking, "b": .toolExecution, "c": .ready],
            ledger: ledger,
            now: t0 + 120_000
        )
        XCTAssertEqual(working.status, "2 terminals are working")
        XCTAssertEqual(working.accent, ShellPalette.blue)
        let dashboard = try? XCTUnwrap(working.dashboard)
        XCTAssertEqual(dashboard?.working, 2)
        XCTAssertEqual(dashboard?.mix, "1 ready")
        // Worst first: the two blues, then the green. Read left to right, the
        // bar is in order of how much it wants from you.
        XCTAssertEqual(
            dashboard?.pills,
            [ShellPalette.blue, ShellPalette.blue, ShellPalette.green]
        )
        XCTAssertEqual(dashboard?.capacity, PaneGrid.maxPanes)
        // The *oldest* pane, not the newest: 2m, not 1m.
        XCTAssertEqual(dashboard?.age, "2m")

        let waiting = HoverCardModel.session(
            node,
            panes: panes,
            statuses: ["a": .thinking, "b": .awaitingApproval, "c": .ready],
            ledger: ledger,
            now: t0 + 120_000
        )
        XCTAssertEqual(waiting.status, "1 terminal is waiting")
        XCTAssertEqual(waiting.accent, ShellPalette.amber, "something asking outranks something working")
        XCTAssertEqual(waiting.dashboard?.pills.first, ShellPalette.amber)
    }

    /// The table is the point of the card: what is doing something, worst
    /// first, most recent first, and never anything that is just sitting there.
    func testTheWorkingTableSkipsReadyPanesAndPutsTheUrgentOneFirst() throws {
        var panes: [String: PaneDescriptor] = [:]
        for (id, engine) in [("a", Engine.claude), ("b", .codex), ("c", .shell), ("d", .claude)] {
            panes[id] = PaneDescriptor(
                sessionID: id,
                group: "s",
                title: "pane \(id)",
                engine: engine,
                cwd: "/Users/x/Code",
                label: "pane \(id)"
            )
        }
        let model = HoverCardModel.session(
            sessionNode(paneIDs: ["a", "b", "c", "d"]),
            panes: panes,
            statuses: ["a": .thinking, "b": .awaitingApproval, "c": .ready, "d": .thinking],
            ledger: PaneActivityLedger(),
            eventTimes: ["a": t0, "d": t0 + 5_000],
            tails: { $0 == "b" ? "Blocked — wants to write 3 files outside src/" : "line \($0)" },
            now: t0 + 10_000
        )
        let rows = try XCTUnwrap(model.dashboard?.rows)
        XCTAssertEqual(rows.map(\.paneID), ["b", "d", "a"], "waiting first, then the newest worker")
        XCTAssertEqual(rows[0].accent, ShellPalette.amber)
        // The engine, and only the engine: the colour and the caret say the
        // rest, and "Codex · Working" beside a blinking blue line said it twice.
        XCTAssertEqual(rows[0].detail, "Codex")
        // Always ellipsised — the pane is mid-sentence.
        XCTAssertEqual(rows[0].line, "Blocked — wants to write 3 files outside src/…")
        XCTAssertFalse(rows.contains { $0.paneID == "c" }, "a ready pane is not news")
    }

    /// Four rows, and the fifth is simply not shown — the card sits beside a
    /// sidebar row and cannot grow forever.
    func testTheTableStopsAtFourRows() throws {
        let ids = (0..<7).map { "p\($0)" }
        var panes: [String: PaneDescriptor] = [:]
        var statuses: [String: RemoteSessionStatus] = [:]
        for id in ids {
            panes[id] = PaneDescriptor(sessionID: id, group: "s", engine: .claude)
            statuses[id] = .thinking
        }
        let model = HoverCardModel.session(
            sessionNode(paneIDs: ids),
            panes: panes,
            statuses: statuses,
            ledger: PaneActivityLedger(),
            now: t0
        )
        XCTAssertEqual(model.dashboard?.rows.count, SessionDashboard.maxRows)
        XCTAssertEqual(model.dashboard?.pills.count, 7, "the bar still counts them all")
    }

    /// A clean tree has no git tile at all, rather than a tile full of zeroes.
    func testACleanTreeHasNoGitTile() {
        let panes = ["a": PaneDescriptor(sessionID: "a", group: "s", engine: .claude)]
        let clean = HoverCardModel.session(
            sessionNode(paneIDs: ["a"]),
            panes: panes,
            statuses: ["a": .ready],
            ledger: PaneActivityLedger(),
            git: GitDiffStat(),
            now: t0
        )
        XCTAssertNil(clean.dashboard?.git)

        let dirty = HoverCardModel.session(
            sessionNode(paneIDs: ["a"]),
            panes: panes,
            statuses: ["a": .ready],
            ledger: PaneActivityLedger(),
            git: GitDiffStat(files: 14, added: 1284, removed: 312, branch: "main"),
            branch: "main",
            now: t0
        )
        XCTAssertEqual(dirty.dashboard?.git?.files, 14)
        XCTAssertEqual(dirty.dashboard?.branch, "main")
    }

    /// One unit, the biggest that fits — the card answers "how old", not "to
    /// the second".
    func testAgeReadsAsOneUnit() {
        XCTAssertEqual(HoverCardModel.age(12_000), "12s")
        XCTAssertEqual(HoverCardModel.age(4 * 60_000 + 12_000), "4m")
        XCTAssertEqual(HoverCardModel.age(3 * 3_600_000), "3h")
        XCTAssertEqual(HoverCardModel.age(2 * 86_400_000), "2d")
        XCTAssertEqual(HoverCardModel.age(16 * 86_400_000), "2w")
        XCTAssertEqual(HoverCardModel.age(150 * 86_400_000), "5mo")
        XCTAssertEqual(HoverCardModel.age(800 * 86_400_000), "2y")
    }

    /// `git diff --shortstat` prints only the clauses that are non-zero, and
    /// nothing at all for a clean tree.
    func testTheShortstatParsesEveryShapeGitPrints() {
        let full = GitDiffStat.parse(
            shortstat: " 14 files changed, 1284 insertions(+), 312 deletions(-)\n"
        )
        XCTAssertEqual(full, GitDiffStat(files: 14, added: 1284, removed: 312))
        XCTAssertEqual(
            GitDiffStat.parse(shortstat: " 1 file changed, 2 insertions(+)\n"),
            GitDiffStat(files: 1, added: 2, removed: 0)
        )
        XCTAssertEqual(
            GitDiffStat.parse(shortstat: " 3 files changed, 9 deletions(-)\n"),
            GitDiffStat(files: 3, added: 0, removed: 9)
        )
        XCTAssertTrue(GitDiffStat.parse(shortstat: "").isEmpty)
    }

    /// The commit list is unit-separated because a subject may contain
    /// anything — spaces, tabs, its own colons.
    func testTheLogParsesIntoCommits() {
        let log = "a41f7c2\u{1f}fix: coalesce token rotation\u{1f}1760000000\n"
            + "7de0b19\u{1f}db: add users.last_seen_at + index\u{1f}1759998800\n"
        XCTAssertEqual(
            GitDiffStat.parse(log: log),
            [
                GitCommit(hash: "a41f7c2", subject: "fix: coalesce token rotation", at: 1_760_000_000),
                GitCommit(hash: "7de0b19", subject: "db: add users.last_seen_at + index", at: 1_759_998_800),
            ]
        )
        XCTAssertTrue(GitDiffStat.parse(log: "").isEmpty)
        XCTAssertTrue(GitDiffStat.parse(log: "malformed line\n").isEmpty)
    }

    /// `--left-right` prints the upstream's side first. No upstream is empty
    /// output, and an honest zero-zero rather than a guess.
    func testTheTrackingCountsReadBehindThenAhead() {
        XCTAssertEqual(GitDiffStat.parse(tracking: "0\t2\n").behind, 0)
        XCTAssertEqual(GitDiffStat.parse(tracking: "0\t2\n").ahead, 2)
        XCTAssertEqual(GitDiffStat.parse(tracking: "3\t1\n").behind, 3)
        XCTAssertEqual(GitDiffStat.parse(tracking: "").ahead, 0)
    }

    /// The commits reach the view already aged, so the model changes when the
    /// card's text does rather than ten times a second.
    func testTheCommitsArriveAgedAndTrimmed() {
        let long = String(repeating: "x", count: HoverCommitRow.subjectLimit + 20)
        var git = GitDiffStat(files: 2, added: 3, removed: 1, branch: "main")
        git.recent = [
            GitCommit(hash: "a41f7c2", subject: "fix: coalesce token rotation", at: t0 / 1000 - 360),
            GitCommit(hash: "7de0b19", subject: long, at: t0 / 1000 - 7_200),
        ]
        let model = HoverCardModel.session(
            sessionNode(paneIDs: ["a"]),
            panes: ["a": PaneDescriptor(sessionID: "a", group: "s", engine: .claude)],
            statuses: ["a": .ready],
            ledger: PaneActivityLedger(),
            git: git,
            now: t0
        )
        let commits = model.dashboard?.commits
        XCTAssertEqual(commits?.count, 2)
        XCTAssertEqual(commits?.first?.hash, "a41f7c2")
        XCTAssertEqual(commits?.first?.age, "6m")
        XCTAssertEqual(commits?.last?.age, "2h")
        XCTAssertEqual(commits?.last?.subject.count, HoverCommitRow.subjectLimit + 1, "trimmed, plus its ellipsis")
    }

    /// The two tiles are tabs: terminals to begin with, git while the pointer
    /// is on the git tile, and back to terminals the moment the tree is clean
    /// and that tile is gone.
    func testTheTilesAreTabs() {
        let view = HoverDashboardView()
        var dirty = SessionDashboard(
            pills: [ShellPalette.blue],
            capacity: 12,
            working: 1,
            mix: "",
            age: "2h",
            branch: "main",
            git: GitDiffStat(files: 14, added: 1284, removed: 312, branch: "main"),
            rows: [
                HoverWorkRow(
                    paneID: "a",
                    title: "token rotation",
                    detail: "Claude",
                    line: "working…",
                    accent: ShellPalette.blue,
                    pulses: true,
                    engine: .claude
                )
            ],
            commits: [HoverCommitRow(hash: "a41f7c2", subject: "fix: it", age: "6m")]
        )
        view.apply(dirty, animated: false)
        XCTAssertEqual(view.tab, .terminals)
        XCTAssertNil(view.visibleGitPanel, "the table is what a session row is about")
        XCTAssertEqual(view.visibleRowCount, 1)

        view.select(.git)
        XCTAssertEqual(view.tab, .git)
        XCTAssertEqual(view.visibleGitPanel?.visibleCommitCount, 1)

        dirty.git = nil
        view.apply(dirty, animated: false)
        XCTAssertEqual(view.tab, .terminals, "no tile, no tab")
        XCTAssertNil(view.visibleGitPanel)
    }

    /// The bar gives up empty slots before it lets a filled pill become a
    /// hairline — and never drops a pane that exists.
    func testThePillBarKeepsEveryPaneAndDropsSpareSlots() {
        let bar = HoverPillBarView()
        bar.apply(pills: Array(repeating: ShellPalette.blue, count: 3), capacity: 12)
        XCTAssertEqual(bar.slotCount(width: 160), 12, "twelve fit in the tile")
        XCTAssertEqual(bar.slotCount(width: 30), 4, "no room: empty slots go first")
        XCTAssertEqual(bar.slotCount(width: 4), 3, "the panes themselves never go")
    }

    /// Neither side of the diff bar vanishes while it still has lines in it.
    func testTheDiffBarNeverRoundsARealNumberToNothing() {
        let bar = HoverDiffBarView()
        bar.apply(added: 1284, removed: 1)
        let green = bar.greenWidth(total: 120)
        XCTAssertLessThanOrEqual(green, 120 - HoverDiffBarView.minSlice)
        XCTAssertGreaterThan(green, 100, "1284 against 1 is still mostly green")

        bar.apply(added: 0, removed: 40)
        XCTAssertEqual(bar.greenWidth(total: 120), 0, "nothing added, no green at all")
        bar.apply(added: 40, removed: 0)
        XCTAssertEqual(bar.greenWidth(total: 120), 120)
    }

    /// The card that is a dashboard is wider than the card that is a label,
    /// and it grows and shrinks with the table.
    func testTheSessionCardIsWiderAndGrowsWithItsTable() throws {
        let body = HoverCardBodyView()
        body.tailField.animates = false
        var panes: [String: PaneDescriptor] = [:]
        for id in ["a", "b", "c"] {
            panes[id] = PaneDescriptor(sessionID: id, group: "s", engine: .claude, label: "pane \(id)")
        }
        func apply(_ statuses: [String: RemoteSessionStatus]) -> NSSize {
            body.apply(HoverCardModel.session(
                sessionNode(paneIDs: ["a", "b", "c"]),
                panes: panes,
                statuses: statuses,
                ledger: PaneActivityLedger(),
                tails: { "working on \($0)" },
                git: GitDiffStat(files: 14, added: 1284, removed: 312, branch: "main"),
                branch: "main",
                now: t0
            ))
            let size = body.cardSize
            body.frame = NSRect(origin: .zero, size: size)
            body.layoutSubtreeIfNeeded()
            return size
        }

        let three = apply(["a": .thinking, "b": .thinking, "c": .awaitingApproval])
        XCTAssertEqual(three.width, HoverCardBodyView.sessionWidth)
        XCTAssertEqual(body.dashboardView.visibleRowCount, 3)

        let one = apply(["a": .thinking, "b": .ready, "c": .ready])
        XCTAssertEqual(body.dashboardView.visibleRowCount, 1)
        XCTAssertLessThan(one.height, three.height, "two rows fewer is a shorter card")

        // Renders, and back to the narrow card when the model is a pane again.
        let rep = try XCTUnwrap(body.bitmapImageRepForCachingDisplay(in: body.bounds))
        body.cacheDisplay(in: body.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsHigh, 0)

        body.apply(HoverCardModel.pane(terminal(), status: .ready, activity: nil, now: t0))
        XCTAssertEqual(body.cardSize.width, HoverCardBodyView.width)
    }

    /// Scratch: renders the session card to a PNG so its layout can be looked
    /// at. Runs only when `TEST_RUNNER_HOVER_SNAPSHOT_DIR` is set.
    func testRenderSessionCardSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["HOVER_SNAPSHOT_DIR"] else {
            throw XCTSkip("no snapshot dir")
        }
        let now: Double = 1_760_000_000_000
        var panes: [String: PaneDescriptor] = [:]
        let spec: [(String, Engine, String)] = [
            ("a", .claude, "token rotation"),
            ("b", .codex, "webhook retries"),
            ("c", .antigravity, "users.last_seen_at"),
            ("d", .claude, "brain ingest audit"),
            ("e", .shell, "build"),
        ]
        for (id, engine, label) in spec {
            panes[id] = PaneDescriptor(
                sessionID: id,
                group: "s",
                engine: engine,
                cwd: "/Users/x/Code/OmniAgent-ADE",
                label: label
            )
        }
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: now - 7_400_000)
        let tails = [
            "a": "Coalescing refresh-token rotation behind one in-flight promise",
            "b": "Blocked — wants to write 3 files outside src/stripe/",
            "c": "Migration 0043_curly_stingray.sql ready to apply",
            "d": "Re-walking 1,842 files · 68% parsed, 41,208 nodes linked",
        ]
        var git = GitDiffStat(files: 14, added: 1284, removed: 312, branch: "main")
        git.staged = 3
        git.committedToday = 27
        git.ahead = 2
        git.recent = [
            GitCommit(hash: "a41f7c2", subject: "fix: coalesce token rotation", at: now / 1000 - 360),
            GitCommit(hash: "7de0b19", subject: "db: add users.last_seen_at + index", at: now / 1000 - 1_320),
            GitCommit(hash: "1c98ee4", subject: "test: stripe webhook idempotency", at: now / 1000 - 3_600),
        ]
        let model = HoverCardModel.session(
            SessionGroupNode(
                id: "s",
                project: "p",
                name: "session restore",
                label: "session restore",
                cwd: "/Users/x/Code/OmniAgent-ADE",
                paneIDs: ["a", "b", "c", "d", "e"],
                isCurrent: true
            ),
            panes: panes,
            statuses: [
                "a": .thinking, "b": .awaitingApproval, "c": .toolExecution,
                "d": .thinking, "e": .ready,
            ],
            ledger: ledger,
            eventTimes: ["a": now - 4_000, "c": now - 9_000, "d": now - 1_000],
            tails: { tails[$0] },
            git: git,
            branch: "main",
            now: now
        )

        let body = HoverCardBodyView()
        body.tailField.animates = false
        body.apply(model)

        // Both tabs, since either is one hover away from the other.
        try shoot(body, into: dir, named: "session-card.png")
        body.dashboardView.onReview = {}
        body.dashboardView.select(.git)
        try shoot(body, into: dir, named: "session-card-git.png")
    }

    private func shoot(_ body: HoverCardBodyView, into dir: String, named name: String) throws {
        let size = body.cardSize
        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(
            srgbRed: 0.07,
            green: 0.075,
            blue: 0.11,
            alpha: 1
        ).cgColor
        body.frame = backdrop.bounds
        backdrop.addSubview(body)
        backdrop.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    private func sessionNode(paneIDs: [String]) -> SessionGroupNode {
        SessionGroupNode(
            id: "s",
            project: "p",
            name: "Refactor",
            label: "Refactor",
            cwd: "/Users/x/Code",
            paneIDs: paneIDs,
            isCurrent: true
        )
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

        // And it gets there. Waited for, not slept for: at 600 chars/s the
        // line is done in a couple of 60Hz ticks, and `isTyping` drops on the
        // tick after the last character lands — but the timer that types it
        // is a main-run-loop timer, and a busy machine (the full suite next
        // to a Release build) can hold a tick back for longer than any fixed
        // sleep short enough to still be a unit test.
        let deadline = Date().addingTimeInterval(2)
        while field.isTyping, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(field.typedText, "Editing SessionOutline…")
        XCTAssertFalse(field.isTyping, "typed out and stopped, well inside two seconds")
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
        assertNoNaNGeometry(shell)

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

    /// The card takes the mouse — its tiles are tabs and the pointer has to be
    /// able to reach them — but never key: a non-activating panel, so the
    /// terminal underneath keeps the keyboard.
    func testTheCardTakesTheMouseButNeverKey() throws {
        let controller = SessionHoverCardController()
        let panel = try XCTUnwrap(Mirror(reflecting: controller).children
            .first { $0.label == "panel" }?.value as? NSPanel)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
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

    /// A screen captured off the live daemon, rebuilt row for row: real glyphs,
    /// real columns, real wrapping. It is here because every rule in
    /// `lastOutputLine` was wrong against it in some way — the answer it used
    /// to give was `──────── Special Tooltip ──`, the separator the terminal
    /// hangs its tab name on, which is flush with the margin, has words in it,
    /// sits below everything else, and never changes.
    func testARealClaudeScreenAnswersWithItsLowestBullet() throws {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 114, rows: 45)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        // (row, column, text) exactly as the capture had them: bullets flush at
        // column 1 with their text at column 3, tool echoes at 3, tool output
        // further in, and the chrome at the bottom.
        let screen: [(Int, Int, String)] = [
            (2, 1, "❯ Your forgot the word Ready in green as well."),
            (4, 1, "⏺ Misread that one — logo and the word, both green:"),
            (6, 3, "Ran 3 shell commands"),
            (10, 1, "⏺ Committing the Ready line, then going after the real screen instead of guessing:"),
            (14, 1, "⏺ Write(crates/omniagent-pty-daemon/examples/peek.rs)"),
            (15, 3, "⎿  Wrote 94 lines to crates/omniagent-pty-daemon/examples/peek.rs"),
            (16, 7, "1 //! Throwaway probe: dumps a live session's replay snapshot to a file"),
            (25, 6, "… +84 lines"),
            (27, 1, "❯ Check it at [Image #2] the last blinking dot row"),
            (30, 1, "⏺ Now I can test against the real thing instead of guessing at glyphs."),
            // The running line: its bullet is blinked off in this frame, so all
            // that marks it is the column its text starts in.
            (32, 3, "Running 5 shell commands · 2s…"),
            (33, 3, "⎿  $ SCRATCH=/private/tmp/claude-501/-Users-bonando-Documents"),
            (34, 6, "6-1da3acb072b5/scratchpad; (./target/debug/examples/peek 2>&1 & PID=$!;"),
            (37, 1, "⏺ Background command \"SCRATCH=/private/tmp/claude-501\""),
            // Its own wrapped remainder — flush with the margin, and not a line
            // of its own.
            (38, 1, "b-cffd-5dae-acd6-1da3acb072b5/scratchpad && ./target/debug/examples/peek"),
            (39, 1, "with exit code 144"),
            (41, 1, "✶ Caramelizing… (5m 40s · ↓ 11.1k tokens)"),
            (42, 76, "✔ Update installed · Restart to update"),
            (43, 1, String(repeating: "─", count: 95) + " Special Tooltip ──"),
            (44, 1, "❯ "),
            (45, 1, "──⏵⏵ auto mode on (shift+tab to cycle) · ← for agents ──────"),
        ]
        for (row, column, text) in screen {
            terminal.feed(text: "\u{1b}[\(row);\(column)H" + text)
        }

        XCTAssertEqual(
            TerminalSurfaceView.lastOutputLine(of: terminal),
            "Background command \"SCRATCH=/private/tmp/claude-501\"",
            "the lowest bullet, not the tab-name separator under everything"
        )
    }

    /// And when the lowest thing on the screen is a *blinked-off* bullet, that
    /// is the one — the running line, which is the whole point.
    func testTheRunningLineWinsWhileItsBulletIsBlinkedOff() throws {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 90, rows: 12)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        let screen: [(Int, Int, String)] = [
            (1, 1, "⏺ Now I can test against the real thing instead of guessing:"),
            (3, 3, "Running 1 shell command…"),
            (4, 3, "⎿  $ cargo build -p omniagent-pty-daemon --example peek"),
            (5, 7, "Compiling omniagent-pty-daemon v0.1.0"),
            (7, 1, "✶ Caramelizing… (5m 40s · ↓ 11.1k tokens)"),
            (8, 1, String(repeating: "─", count: 70) + " Special Tooltip ──"),
            (9, 1, "❯ "),
        ]
        for (row, column, text) in screen {
            terminal.feed(text: "\u{1b}[\(row);\(column)H" + text)
        }

        XCTAssertEqual(TerminalSurfaceView.lastOutputLine(of: terminal), "Running 1 shell command…")
    }

    /// The screen a compacted transcript leaves behind, captured off the live
    /// daemon: every bullet gone, the agent's own `⎿` echoes still there, and
    /// underneath them the separator its tab name hangs on. The shell rules
    /// used to answer with that separator here, because a screen with no bullet
    /// on it was taken for a shell's.
    func testACompactedTranscriptHasNothingToReport() throws {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 54, rows: 42)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        let screen: [(Int, Int, String)] = [
            // What is left of the last answer: its bullet went with the
            // transcript, so only its wrapped body is on the screen.
            (2, 3, "Two of these I could have caught before shipping and"),
            (13, 3, "may still want tuning now that the chips aren't"),
            (14, 3, "distorting it."),
            (16, 1, "✻ Sautéed for 24m 20s"),
            (18, 1, "❯ /compact"),
            (19, 3, "⎿  Compacted (ctrl+o to see full summary)"),
            (20, 3, "⎿  Read macos/OmniAgent/PaneChipView.swift (274"),
            (21, 6, "lines)"),
            (32, 3, "⎿  Skills restored (frontend-design:frontend-design)"),
            (33, 14, "✔ Update installed · Restart to update"),
            (34, 1, String(repeating: "─", count: 24) + " Desk view spatial zoom work ─"),
            (35, 1, "❯ "),
            (36, 1, String(repeating: "─", count: 54)),
            (41, 3, "⏵⏵ auto mode on (shift+tab to cycle) · ← for agen…"),
        ]
        for (row, column, text) in screen {
            terminal.feed(text: "\u{1b}[\(row);\(column)H" + text)
        }

        XCTAssertNil(
            TerminalSurfaceView.lastOutputLine(of: terminal),
            "no bullet left to read, so nothing — not the tab-name separator"
        )
    }

    /// And the same screen without the agent's echoes on it *is* a shell, which
    /// still gets an answer out of the rules that stand in for bullets.
    func testAShellStillReportsItsLowestLine() throws {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 54, rows: 8)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        let screen: [(Int, Int, String)] = [
            (1, 1, "$ cargo build -p omniagent-pty-daemon"),
            (2, 3, "Compiling omniagent-pty-daemon v0.1.0"),
            (4, 1, "Finished dev profile in 3.41s"),
            (6, 1, "❯ "),
        ]
        for (row, column, text) in screen {
            terminal.feed(text: "\u{1b}[\(row);\(column)H" + text)
        }

        XCTAssertEqual(
            TerminalSurfaceView.lastOutputLine(of: terminal),
            "Finished dev profile in 3.41s"
        )
    }

    // MARK: - The line, held

    /// A read that comes back empty is a frame the agent had cleared and not
    /// finished redrawing, not news that it stopped working. At ten reads a
    /// second, answering `nil` there is what the flicker between the line and
    /// `Working` actually was.
    func testABlankReadKeepsTheLineItAlreadyHad() {
        var hold = TerminalSurfaceView.OutputLineHold()

        XCTAssertNil(hold.update(nil), "nothing read yet is still nothing")
        XCTAssertEqual(hold.update("Running 1 shell command…"), "Running 1 shell command…")
        XCTAssertEqual(
            hold.update(nil), "Running 1 shell command…",
            "a torn frame does not wipe the line"
        )
        XCTAssertEqual(
            hold.update("Editing SessionHoverCard.swift"), "Editing SessionHoverCard.swift",
            "only another line replaces a line"
        )
    }

    // MARK: - Three lines

    /// The line runs to three rows now, and the card is as tall as the line
    /// needs — but no taller, so a short one does not sit in a hole.
    func testTheCardGrowsWithTheLineUpToThreeRows() {
        let body = HoverCardBodyView()
        body.tailField.animates = false

        let heights = [
            "Editing.",
            String(repeating: "Editing SessionHoverCard.swift. ", count: 2),
            String(repeating: "Editing SessionHoverCard.swift. ", count: 6),
            String(repeating: "Editing SessionHoverCard.swift. ", count: 30),
        ].map { tail -> CGFloat in
            body.apply(model(tail: tail))
            return body.cardSize.height
        }

        XCTAssertLessThan(heights[0], heights[1], "two rows is taller than one")
        XCTAssertLessThan(heights[1], heights[2], "three rows is taller than two")
        XCTAssertEqual(heights[2], heights[3], "and three is where it stops")
    }

    /// Height is reserved for the finished line, not the prefix on screen:
    /// otherwise the card gains a row under the reader twice on the way
    /// through every message.
    func testTheCardDoesNotGrowRowByRowWhileItTypes() {
        let body = HoverCardBodyView()
        body.tailField.animates = true
        let tail = String(repeating: "Editing SessionHoverCard.swift. ", count: 6)

        body.apply(model(tail: tail))
        let whileTyping = body.cardSize.height
        XCTAssertTrue(body.tailField.isTyping, "the fixture has to still be mid-type")
        XCTAssertLessThan(
            body.tailField.typedText.count, tail.count,
            "and only part of it on screen"
        )

        body.tailField.animates = false
        body.tailField.setLine(tail + " ")
        body.tailField.setLine(tail)
        XCTAssertEqual(body.cardSize.height, whileTyping, "the same height throughout")
    }

    // MARK: - Helpers

    private final class SilentTerminalDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// A working pane's card with a given line on it.
    private func model(tail: String) -> HoverCardModel {
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        return HoverCardModel.pane(
            terminal(),
            status: .thinking,
            activity: ledger.activity(for: "a"),
            tail: tail,
            now: t0 + 12_000
        )
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

    // MARK: - NaN geometry regression (crash: "Invalid view geometry: y is NaN")

    /// Walks the real, laid-out tree the way the crash reporter's own
    /// `_NSViewValidateGeometry` does, and fails loudly the instant a frame
    /// component is NaN — instead of trapping the whole process the way the
    /// real thing does.
    func assertNoNaNGeometry(_ view: NSView, _ path: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let f = view.frame
        if f.origin.x.isNaN || f.origin.y.isNaN || f.size.width.isNaN || f.size.height.isNaN {
            XCTFail("\(path)/\(type(of: view)) has NaN geometry: \(f)", file: file, line: line)
        }
        for (i, sub) in view.subviews.enumerated() {
            assertNoNaNGeometry(sub, "\(path)/\(i):\(type(of: sub))", file: file, line: line)
        }
    }

    /// A grab-bag of dashboard states that used to leave `HoverCardBodyView`
    /// pinned to a `.required` height it had already outgrown — a stale
    /// `translatesAutoresizingMaskIntoConstraints` mirror fighting the real
    /// content the moment it needed more room. AppKit resolved that by
    /// breaking a stack spacing constraint, or, at the wrong moment, by
    /// producing NaN geometry and crashing (`HoverCardBodyView.cardSize`).
    func testNoStateProducesNaNGeometry() throws {
        let body = HoverCardBodyView()
        body.tailField.animates = false
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        backdrop.addSubview(body)

        func lay(_ model: HoverCardModel) {
            body.apply(model)
            let size = body.cardSize
            body.frame = NSRect(origin: .zero, size: size)
            backdrop.layoutSubtreeIfNeeded()
            assertNoNaNGeometry(body)
        }

        // A session with panes, dirty tree, commits — the ordinary path.
        var panes: [String: PaneDescriptor] = [:]
        for id in ["a", "b", "c"] {
            panes[id] = PaneDescriptor(sessionID: id, group: "s", engine: .claude, label: "pane \(id)")
        }
        var git = GitDiffStat(files: 14, added: 1284, removed: 312, branch: "main")
        git.recent = [GitCommit(hash: "a41f7c2", subject: "fix: it", at: t0 / 1000 - 60)]
        lay(HoverCardModel.session(
            sessionNode(paneIDs: ["a", "b", "c"]),
            panes: panes,
            statuses: ["a": .thinking, "b": .thinking, "c": .awaitingApproval],
            ledger: PaneActivityLedger(),
            tails: { "working on \($0)" },
            git: git,
            branch: "main",
            now: t0
        ))
        body.dashboardView.onReview = {}
        body.dashboardView.select(.git)
        backdrop.layoutSubtreeIfNeeded()
        assertNoNaNGeometry(body)

        // Dirty tree, zero commits ever (a brand new repo) — the git tab's
        // commit list collapses to nothing while its stats row stays up.
        var noCommits = GitDiffStat(files: 2, added: 5, removed: 0, branch: "main")
        noCommits.recent = []
        lay(HoverCardModel.session(
            sessionNode(paneIDs: ["a", "b", "c"]),
            panes: panes,
            statuses: ["a": .ready, "b": .ready, "c": .ready],
            ledger: PaneActivityLedger(),
            git: noCommits,
            branch: "main",
            now: t0
        ))
        body.dashboardView.select(.git)
        backdrop.layoutSubtreeIfNeeded()
        assertNoNaNGeometry(body)

        // An empty session: no panes at all, no git. The narrowest, emptiest
        // dashboard the card can carry.
        lay(HoverCardModel.session(
            sessionNode(paneIDs: []),
            panes: [:],
            statuses: [:],
            ledger: PaneActivityLedger(),
            now: t0
        ))

        // Clean tree after a dirty one, while sitting on the git tab — the
        // tab has to fall back before the tile it belongs to disappears.
        lay(HoverCardModel.session(
            sessionNode(paneIDs: ["a", "b", "c"]),
            panes: panes,
            statuses: ["a": .thinking, "b": .thinking, "c": .thinking],
            ledger: PaneActivityLedger(),
            git: git,
            branch: "main",
            now: t0
        ))
        body.dashboardView.select(.git)
        backdrop.layoutSubtreeIfNeeded()
        var clean = git
        clean.files = 0
        clean.added = 0
        clean.removed = 0
        lay(HoverCardModel.session(
            sessionNode(paneIDs: ["a", "b", "c"]),
            panes: panes,
            statuses: ["a": .thinking, "b": .thinking, "c": .thinking],
            ledger: PaneActivityLedger(),
            git: clean,
            branch: "main",
            now: t0
        ))

        // Back down to a plain pane card, narrow again, from a wide one.
        lay(HoverCardModel.pane(terminal(), status: .ready, activity: nil, now: t0))

        // A pane card that has never been sized at all before its first
        // layout, from zero.
        let fresh = HoverCardBodyView()
        fresh.tailField.animates = false
        let freshBackdrop = NSView(frame: .zero)
        freshBackdrop.addSubview(fresh)
        fresh.apply(HoverCardModel.pane(terminal(), status: .thinking, activity: nil, tail: "hello", now: t0))
        freshBackdrop.layoutSubtreeIfNeeded()
        assertNoNaNGeometry(fresh)
    }

    /// The field crash this whole file's NaN fixes chase: not `cardSize`
    /// itself (a single synchronous measurement, already covered above) but
    /// the animated resize that follows it — `panel.animator().setFrame`
    /// drives `HoverCardShellView` through every intermediate size between
    /// the old card and the new one, not just the two endpoints, and a tick
    /// smaller than the new dashboard's real content used to be the same
    /// contradiction `cardSize` fixes for one synchronous call. Simulates
    /// the animation by hand — `NSAnimationContext` runs off a display link,
    /// which a synchronous test cannot step through — narrowing and
    /// shortening the shell one tick at a time and asserting every tick is
    /// clean, not just the first and last.
    func testNoStateProducesNaNGeometryDuringAnAnimatedResize() {
        let shell = HoverCardShellView(frame: NSRect(x: 0, y: 0, width: 280, height: 90))
        shell.body.tailField.animates = false
        shell.layoutSubtreeIfNeeded()
        assertNoNaNGeometry(shell)

        var panes: [String: PaneDescriptor] = [:]
        for id in ["a", "b", "c"] {
            panes[id] = PaneDescriptor(sessionID: id, group: "s", engine: .claude, label: "pane \(id)")
        }
        var git = GitDiffStat(files: 14, added: 1284, removed: 312, branch: "main")
        git.recent = [GitCommit(hash: "a41f7c2", subject: "fix: it", at: t0 / 1000 - 60)]
        shell.body.apply(HoverCardModel.session(
            sessionNode(paneIDs: ["a", "b", "c"]),
            panes: panes,
            statuses: ["a": .thinking, "b": .thinking, "c": .awaitingApproval],
            ledger: PaneActivityLedger(),
            tails: { "working on \($0)" },
            git: git,
            branch: "main",
            now: t0
        ))
        let target = shell.cardSize
        XCTAssertGreaterThan(target.height, 90, "the dashboard needs more than the pane card's shape")

        // The window frame does not jump from the old size to the new one;
        // it eases through every value in between, once per animation tick.
        let start = NSSize(width: 280, height: 90)
        for step in 0...20 {
            let t = CGFloat(step) / 20
            shell.frame = NSRect(
                origin: .zero,
                size: NSSize(
                    width: start.width + (target.width - start.width) * t,
                    height: start.height + (target.height - start.height) * t
                )
            )
            shell.layoutSubtreeIfNeeded()
            assertNoNaNGeometry(shell, "tick \(step)")
        }

        // And the reverse — shrinking back down, which passes through the
        // same intermediate sizes from the other direction.
        for step in 0...20 {
            let t = CGFloat(step) / 20
            shell.frame = NSRect(
                origin: .zero,
                size: NSSize(
                    width: target.width + (start.width - target.width) * t,
                    height: target.height + (start.height - target.height) * t
                )
            )
            shell.layoutSubtreeIfNeeded()
            assertNoNaNGeometry(shell, "shrink tick \(step)")
        }
    }

    /// What the live app's view tree showed on 2026-08-30 behind an empty
    /// card: the panel and the blur host at full height, `body` at
    /// `(0,0,404,0)`. Without the glass pin, `cardSize`'s trip to 10 000
    /// points and back reached the autoresizing body as a delta and left it
    /// at zero — and the tick re-measures with the shell already at its
    /// final size, so the frame that follows changed nothing.
    func testTheBodyFillsTheCardAfterAMeasurementAtFinalSize() {
        let shell = HoverCardShellView(frame: NSRect(x: 0, y: 0, width: 280, height: 90))
        shell.body.tailField.animates = false
        var panes: [String: PaneDescriptor] = [:]
        for id in ["a", "b"] {
            panes[id] = PaneDescriptor(sessionID: id, group: "s", engine: .claude, label: "pane \(id)")
        }
        shell.body.apply(HoverCardModel.session(
            sessionNode(paneIDs: ["a", "b"]),
            panes: panes,
            statuses: ["a": .thinking, "b": .ready],
            ledger: PaneActivityLedger(),
            tails: { "working on \($0)" },
            now: t0
        ))
        let target = shell.cardSize
        shell.frame = NSRect(origin: .zero, size: SessionHoverCardController.panelSize(card: target))
        shell.layoutSubtreeIfNeeded()
        XCTAssertEqual(shell.body.frame.height, target.height, accuracy: 0.5, "after the open")

        // The tick: measured again, nothing else changes.
        _ = shell.cardSize
        shell.layoutSubtreeIfNeeded()
        XCTAssertEqual(shell.body.frame.height, target.height, accuracy: 0.5, "after a tick")
        XCTAssertEqual(shell.body.frame.width, target.width, accuracy: 0.5)
    }

    // MARK: - End to end

    /// The whole road from a row's hover to a panel on screen: the open delay
    /// elapses, the provider and row frame answer, and the panel is ordered
    /// in at a finite frame beside the row. Regression guard for "hovering a
    /// session shows nothing at all".
    func testHoveringASessionRowOpensTheCard() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        let panes = ["a", "b"].reduce(into: [String: PaneDescriptor]()) { out, id in
            out[id] = PaneDescriptor(sessionID: id, group: "s", engine: .claude, cwd: "/Users/x/Code")
        }
        let node = sessionNode(paneIDs: ["a", "b"])
        let model = HoverCardModel.session(
            node,
            panes: panes,
            statuses: ["a": .thinking, "b": .ready],
            ledger: ledger,
            tails: { _ in "Editing SessionOutline.swift" },
            now: t0 + 60_000
        )

        let controller = SessionHoverCardController()
        controller.provider = { _ in model }
        controller.rowFrame = { _ in NSRect(x: 120, y: 600, width: 220, height: 30) }
        controller.hover(.session("s"), in: window)
        defer { controller.dismiss(fade: 0) }

        let deadline = Date().addingTimeInterval(2)
        while !controller.isOpen, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(controller.isOpen, "the card opens once the open delay has elapsed")
        XCTAssertEqual(controller.shownModel, model)

        let panel = try XCTUnwrap(Mirror(reflecting: controller).children
            .first { $0.label == "panel" }?.value as? NSPanel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.frame.origin.x.isFinite && panel.frame.origin.y.isFinite, "\(panel.frame)")
        XCTAssertGreaterThan(panel.frame.width, 300, "\(panel.frame)")
        XCTAssertGreaterThan(panel.frame.height, 60, "\(panel.frame)")
        XCTAssertTrue(window.frame.contains(panel.frame), "\(panel.frame) inside \(window.frame)")
        // The drop lane and the slide-in both start left of the row's edge.
        XCTAssertGreaterThan(
            panel.frame.minX,
            340 - HoverCardShellView.lane - SessionHoverCardController.slide - 1,
            "beside the row, not over it: \(panel.frame)"
        )
    }

    /// The real wiring: a sidebar row's hover reaches the window, whose
    /// provider finds the session behind the row and whose sidebar answers
    /// the row's frame — and the card opens.
    func testHoveringASidebarSessionRowRaisesTheCard() throws {
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.collapsedDefaultsKey)
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-hover-test.sock")
            ),
            panes: []
        )
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1", groupLabel: "Build"),
                ])
            )
        )

        let target = SessionHoverCardController.Target.session("g1")
        XCTAssertNotNil(controller.hoverCardModel(for: target), "the window finds the session behind the row")
        // The rows have no width until the window has laid out once.
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotNil(controller.shellSidebar.rowFrameOnScreen(for: target), "the sidebar knows where the row is")

        let row = try XCTUnwrap(controller.shellSidebar.workspacesTree.rowView(for: target) as? SessionRowView)
        try XCTUnwrap(row.onHover)(true)
        defer { controller.hoverCard.dismiss(fade: 0) }
        let deadline = Date().addingTimeInterval(2)
        while !controller.hoverCard.isOpen, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(controller.hoverCard.isOpen, "the card opens from the row's own hover")
    }

    // MARK: - Rows rebuilt under the pointer

    /// A controller wired to a row the pointer is not on (the rect is far off
    /// any screen), so only a phantom leave — one followed by a re-entry —
    /// may open it.
    private func makeWiredController(window: NSWindow) -> SessionHoverCardController {
        var ledger = PaneActivityLedger()
        ledger.record(paneID: "a", status: .thinking, at: t0)
        let panes = ["a"].reduce(into: [String: PaneDescriptor]()) { out, id in
            out[id] = PaneDescriptor(sessionID: id, group: "s", engine: .claude, cwd: "/Users/x/Code")
        }
        let model = HoverCardModel.session(
            sessionNode(paneIDs: ["a"]),
            panes: panes,
            statuses: ["a": .thinking],
            ledger: ledger,
            now: t0 + 60_000
        )
        let controller = SessionHoverCardController()
        controller.provider = { _ in model }
        controller.rowFrame = { _ in NSRect(x: -20_000, y: -20_000, width: 220, height: 30) }
        return controller
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The sidebar rebuilds every row on every status event, and the rebuilt
    /// row under a still pointer reports an enter of its own. With working
    /// terminals those come more often than the open delay, and a delay
    /// restarted on each one never elapsed: hovering a busy session showed
    /// nothing at all.
    func testARowRebuiltUnderThePointerDoesNotRestartThePendingOpen() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let controller = makeWiredController(window: window)
        defer { controller.dismiss(fade: 0) }

        controller.hover(.session("s"), in: window)
        // Re-enters every 40ms for half a second — four times the delay.
        let end = Date().addingTimeInterval(0.5)
        while Date() < end, !controller.isOpen {
            pump(0.04)
            controller.hover(.session("s"), in: window)
        }
        XCTAssertTrue(controller.isOpen, "the delay elapsed once, not never")
    }

    /// The rebuilt row may report the leave too — the old row's, before the
    /// new one's enter. Same pointer, same row, same answer.
    func testAPhantomLeaveAndReEntryKeepThePendingOpen() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let controller = makeWiredController(window: window)
        defer { controller.dismiss(fade: 0) }

        controller.hover(.session("s"), in: window)
        let end = Date().addingTimeInterval(0.5)
        while Date() < end, !controller.isOpen {
            pump(0.04)
            controller.hover(nil, in: window)
            controller.hover(.session("s"), in: window)
        }
        XCTAssertTrue(controller.isOpen)
    }

    /// A real leave — no re-entry, and the pointer is nowhere near the row —
    /// still opens nothing: the pending open is not cancelled, but it asks
    /// where the pointer is before it shows anything.
    func testARealLeaveBeforeTheDelayShowsNothing() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let controller = makeWiredController(window: window)
        defer { controller.dismiss(fade: 0) }

        controller.hover(.session("s"), in: window)
        controller.hover(nil, in: window)
        pump(0.4)
        XCTAssertFalse(controller.isOpen)
        XCTAssertNil(controller.target)
    }
}

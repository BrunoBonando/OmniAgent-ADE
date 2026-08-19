import XCTest
@testable import OmniAgent

/// Ported from `ui/src/state/sessionGroups.test.ts` — the grouping, the
/// ordering, and the "lowest free number" naming rule.
final class SessionOutlineTests: XCTestCase {
    func testPanesGroupByProjectThenSessionInFirstSeenOrder() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "alpha", group: "g1"),
                pane("b", project: "beta", group: "g9"),
                pane("c", project: "alpha", group: "g2"),
                pane("d", project: "alpha", group: "g1"),
            ],
            focusedPaneID: nil
        )

        XCTAssertEqual(tree.map(\.project), ["alpha", "beta"], "projects keep first-seen order")
        XCTAssertEqual(tree[0].sessions.map(\.id), ["g1", "g2"], "so do sessions")
        XCTAssertEqual(tree[0].sessions[0].paneIDs, ["a", "d"], "a later pane joins its known session")
        XCTAssertEqual(tree[1].sessions.map(\.paneIDs), [["b"]])
    }

    func testExactlyOneSessionIsCurrentAndItIsTheOneHoldingTheFocusedPane() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "alpha", group: "g1"),
                pane("b", project: "alpha", group: "g2"),
                pane("c", project: "beta", group: "g3"),
            ],
            focusedPaneID: "b"
        )

        XCTAssertEqual(tree.flatMap(\.sessions).filter(\.isCurrent).map(\.id), ["g2"])
    }

    func testNothingIsCurrentWhenNoPaneHasFocus() {
        let tree = SessionOutline.group([pane("a", project: "alpha", group: "g1")], focusedPaneID: nil)
        XCTAssertFalse(tree[0].sessions[0].isCurrent)
    }

    // MARK: - currentSessionGroupID — the strict "who has focus" answer
    // Ported from `describe("currentSessionGroupId")`.

    func testTheCurrentSessionIsTheOneHoldingTheFocusedPane() {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
        ]
        XCTAssertEqual(SessionOutline.currentSessionGroupID(panes, focusedPaneID: "b"), "g2")
    }

    func testTheCurrentSessionIsTheImplicitOneForAFocusedPreGroupingPane() {
        let panes = [pane("a", project: "p1", group: WorkspaceRestoration.ungroupedSessionID)]
        XCTAssertEqual(
            SessionOutline.currentSessionGroupID(panes, focusedPaneID: "a"),
            WorkspaceRestoration.ungroupedSessionID,
            "a pane with no stored group already carries the sentinel — resolved once at the restore boundary"
        )
    }

    func testThereIsNoCurrentSessionWithNothingFocusedOrAStaleFocusID() {
        let panes = [pane("a", project: "p1", group: "g1")]
        XCTAssertNil(SessionOutline.currentSessionGroupID(panes, focusedPaneID: nil))
        XCTAssertNil(
            SessionOutline.currentSessionGroupID(panes, focusedPaneID: "ghost"),
            "a focus id naming no live pane is not a session — that is what visibleSessionGroupID falls back for"
        )
    }

    // MARK: - visibleSessionGroupID — which session this project puts on screen
    // Ported from `describe("visibleSessionGroupId")`.

    func testTheVisibleSessionIsTheFocusedPanesWhenTheFocusedPaneIsInThisProject() {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
        ]
        XCTAssertEqual(SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: "b"), "g2")
    }

    /// Selecting a workspace in the sidebar does not move focus, so the
    /// focused pane routinely belongs to a different project than the one
    /// being rendered. The topmost session is the one the eye lands on.
    func testTheVisibleSessionFallsBackToTheProjectsFirstWhenFocusIsInAnotherProject() {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
            pane("c", project: "p2", group: "g3"),
        ]
        XCTAssertEqual(SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: "c"), "g1")
        XCTAssertEqual(
            SessionOutline.currentSessionGroupID(panes, focusedPaneID: "c"),
            "g3",
            "the strict answer here is g3 — the two questions really do differ, and that is the whole point"
        )
    }

    func testTheVisibleSessionFallsBackToTheProjectsFirstWhenNothingIsFocused() {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
        ]
        XCTAssertEqual(SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: nil), "g1")
    }

    func testThereIsNoVisibleSessionForAProjectWithNoPanes() {
        let panes = [pane("a", project: "p1", group: "g1")]
        XCTAssertNil(SessionOutline.visibleSessionGroupID(panes, project: "p2", focusedPaneID: "a"))
    }

    /// It is also the JOIN target for a new pane: `nil` means "this project
    /// has no panes at all", which is what makes the caller's
    /// `existingGroup ?? SessionOutline.newSessionGroupID()` correct.
    func testTheVisibleSessionIsNilOnAnEmptyProjectSoTheCallerMintsAFreshGroup() {
        XCTAssertNil(SessionOutline.visibleSessionGroupID([pane("z", project: "p2", group: "g9")], project: "p1", focusedPaneID: "z"))
        XCTAssertNil(SessionOutline.visibleSessionGroupID([], project: "p1", focusedPaneID: nil))
    }

    func testTheVisibleSessionIsTheImplicitOneForPreGroupingPanes() {
        let panes = [
            pane("a", project: "p1", group: WorkspaceRestoration.ungroupedSessionID),
            pane("b", project: "p1", group: WorkspaceRestoration.ungroupedSessionID),
        ]
        XCTAssertEqual(
            SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: "b"),
            WorkspaceRestoration.ungroupedSessionID
        )
        XCTAssertEqual(
            SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: nil),
            WorkspaceRestoration.ungroupedSessionID
        )
    }

    func testTheVisibleSessionSurvivesAStaleFocusIDRatherThanBlankingTheGrid() {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
        ]
        XCTAssertEqual(SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: "gone"), "g1")
    }

    /// The grid and the sidebar's accent rail must never point at different
    /// sessions, so the focused case has to agree with `group`'s `isCurrent`
    /// by construction.
    func testTheVisibleSessionAgreesWithTheSessionTheOutlineMarksCurrent() throws {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
        ]
        let visible = SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: "b")
        let marked = try XCTUnwrap(
            SessionOutline.group(panes, focusedPaneID: "b")
                .first { $0.project == "p1" }?
                .sessions.first(where: \.isCurrent)?.id
        )
        XCTAssertEqual(visible, marked)
    }

    // MARK: - adjacentSessionTab — stepping sideways between sessions
    // Ported from `describe("adjacentSessionTab")`. The oracle is one line
    // whose end behaviour is entirely JS out-of-range indexing:
    //   sessions[(currentIndex === -1 ? 0 : currentIndex) + offset]?.tabs[0] ?? null
    // Index -1 and index >= count are both `undefined` there and both trap
    // in Swift, so the port guards explicitly and never wraps.

    private var steppingFixture: [PaneDescriptor] {
        [
            pane("first", project: "p1", group: "g1"),
            pane("second", project: "p1", group: "g2"),
            pane("second-pane", project: "p1", group: "g2"),
            pane("third", project: "p1", group: "g3"),
        ]
    }

    func testSteppingForwardLandsOnTheFirstPaneOfTheNextSession() {
        XCTAssertEqual(
            SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "second-pane", offset: 1)?.sessionID,
            "third",
            "the next session's FIRST pane, not its focused one"
        )
    }

    func testSteppingBackLandsOnTheFirstPaneOfThePreviousSession() {
        XCTAssertEqual(
            SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "second", offset: -1)?.sessionID,
            "first"
        )
    }

    func testSteppingStopsAtBothOuterSessionBoundariesWithoutWrapping() {
        XCTAssertNil(
            SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "first", offset: -1),
            "index -1 is nil, not the last session"
        )
        XCTAssertNil(
            SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "third", offset: 1),
            "index == count is nil, not the first session"
        )
    }

    /// The guard is the behaviour, not a defensive extra: a clamp into
    /// `0..<count` would make both of these return a session instead of nil.
    func testSteppingByALargeOffsetIsNilRatherThanAClampOrATrap() {
        XCTAssertNil(SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "second", offset: -5))
        XCTAssertNil(SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "second", offset: 5))
        XCTAssertNil(
            SessionOutline.adjacentSessionTab([], project: "p1", focusedPaneID: nil, offset: 1),
            "and an empty project steps nowhere"
        )
    }

    /// No session in this project is current, so the walk starts from index
    /// 0 — offset +1 is therefore the project's SECOND session, and offset
    /// -1 computes index -1 and is nil.
    func testSteppingStartsFromTheFirstSessionWhenFocusIsOutsideTheProject() {
        let panes = steppingFixture + [pane("other", project: "p2", group: "g4")]
        XCTAssertEqual(
            SessionOutline.adjacentSessionTab(panes, project: "p1", focusedPaneID: "other", offset: 1)?.sessionID,
            "second"
        )
        XCTAssertNil(SessionOutline.adjacentSessionTab(panes, project: "p1", focusedPaneID: "other", offset: -1))
    }

    // MARK: - sessionEngineBreakdown — which engines are running in a session
    // Ported from `describe("sessionEngineBreakdown")`. The oracle takes a
    // `SessionGroup` and reads `session.tabs`; `SessionGroupNode` carries
    // only `paneIDs`, so the Swift signature takes the descriptors and the
    // group id instead.

    func testTheEngineBreakdownCountsEachEngineOnceInFirstSeenOrderWithItsOwnTally() {
        let panes = [
            pane("a", project: "p1", group: "g1", engine: .claude),
            pane("b", project: "p1", group: "g1", engine: .shell),
            pane("c", project: "p1", group: "g1", engine: .claude),
        ]
        let breakdown = SessionOutline.sessionEngineBreakdown(panes, group: "g1")
        // Tuples are not Equatable, so the two projections are compared
        // rather than the array itself.
        XCTAssertEqual(breakdown.map(\.engine), [.claude, .shell], "first-seen order, each engine once")
        XCTAssertEqual(breakdown.map(\.count), [2, 1])
    }

    func testTheEngineBreakdownCountsOnlyTheSessionItWasAskedAbout() {
        let panes = [
            pane("a", project: "p1", group: "g1", engine: .claude),
            pane("b", project: "p1", group: "g2", engine: .codex),
        ]
        XCTAssertEqual(SessionOutline.sessionEngineBreakdown(panes, group: "g2").map(\.engine), [.codex])
        XCTAssertTrue(
            SessionOutline.sessionEngineBreakdown(panes, group: "g-nothing").isEmpty,
            "a session with no panes has no engines"
        )
    }

    /// A browser or editor pane carries `.shell` as a placeholder, not as an
    /// identity — the same reason `nextPaneNumber` gives them their own
    /// ladder. Counting them would make a card claim a shell that is not
    /// running.
    func testTheEngineBreakdownIgnoresBrowserAndEditorPanesWhoseEngineIsAPlaceholder() {
        let panes = [
            pane("a", project: "p1", group: "g1", engine: .claude),
            pane("w", project: "p1", group: "g1", engine: .shell, kind: .browser),
            pane("e", project: "p1", group: "g1", engine: .shell, kind: .editor),
        ]
        let breakdown = SessionOutline.sessionEngineBreakdown(panes, group: "g1")
        XCTAssertEqual(breakdown.map(\.engine), [.claude])
        XCTAssertEqual(breakdown.map(\.count), [1])
    }

    func testAStoredNameIsShownAndAnUnnamedSessionGetsTheLowestFreeNumber() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "alpha", group: "g1", groupLabel: "Session 2"),
                pane("b", project: "alpha", group: "g2"),
                pane("c", project: "alpha", group: "g3"),
            ],
            focusedPaneID: nil
        )

        XCTAssertEqual(
            tree[0].sessions.map(\.label),
            ["Session 2", "Session 1", "Session 3"],
            "a derived default never collides with a name someone actually typed"
        )
        XCTAssertEqual(tree[0].sessions.map(\.name), ["Session 2", nil, nil])
    }

    func testABlankGroupLabelCountsAsUnnamedRatherThanAsAnEmptyName() {
        let tree = SessionOutline.group(
            [pane("a", project: "alpha", group: "g1", groupLabel: "   ")],
            focusedPaneID: nil
        )
        XCTAssertNil(tree[0].sessions[0].name)
        XCTAssertEqual(tree[0].sessions[0].label, "Session 1")
    }

    func testAHalfRenamedSessionReadsFromWhicheverPaneCarriesTheName() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "alpha", group: "g1"),
                pane("b", project: "alpha", group: "g1", groupLabel: "Build"),
            ],
            focusedPaneID: nil
        )
        XCTAssertEqual(tree[0].sessions[0].label, "Build")
    }

    func testASessionsRootIsItsFirstPanesDirectory() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "alpha", group: "g1", cwd: "/alpha"),
                pane("b", project: "alpha", group: "g1", cwd: "/alpha/sub"),
            ],
            focusedPaneID: nil
        )
        XCTAssertEqual(tree[0].sessions[0].cwd, "/alpha")
    }

    func testTheNextSessionNameFillsTheLowestGapAndNeverClimbsForever() {
        let panes = [
            pane("a", project: "alpha", group: "g1", groupLabel: "Session 1"),
            pane("b", project: "alpha", group: "g3", groupLabel: "Session 3"),
        ]
        XCTAssertEqual(SessionOutline.nextSessionName(panes, project: "alpha"), "Session 2")
        XCTAssertEqual(
            SessionOutline.nextSessionName(panes, project: "beta"),
            "Session 1",
            "another project's numbering is its own"
        )
        XCTAssertEqual(SessionOutline.nextSessionName([], project: "alpha"), "Session 1")
    }

    func testAPaneRowPrefersItsOwnNameThenItsLiveTitleThenAPlaceholder() {
        XCTAssertEqual(
            SessionOutline.paneLabel(pane("a", project: "p", group: "g", label: "migrate")),
            "migrate"
        )
        var titled = pane("a", project: "p", group: "g")
        titled.title = "~/src"
        XCTAssertEqual(SessionOutline.paneLabel(titled), "~/src")
        // Was the engine's raw name, `shell`, which every unnamed terminal of
        // that engine shared. The numbered placeholder is per session, so two
        // of them never read the same while they are still starting up.
        XCTAssertEqual(SessionOutline.paneLabel(pane("a", project: "p", group: "g")), "Shell 1")
    }

    /// A terminal wears the task, not the spinner in front of it. Claude
    /// cycles `· ✢ ✳ ✶ ✻ ✽` and prefixes `◐` while a tool runs, all of it in
    /// the title it reports, which made every pane header read `✳ …` and
    /// flicker through the frames while the agent worked.
    func testAReportedTitleLosesTheEnginesSpinnerButKeepsTheTask() {
        for frame in ["·", "✢", "✳", "✶", "✻", "✽", "◐", "◓", "⠋", "*"] {
            XCTAssertEqual(
                SessionOutline.sanitizedPaneTitle("\(frame) Fixing the parser"),
                "Fixing the parser",
                "\(frame) is decoration"
            )
        }
        XCTAssertEqual(
            SessionOutline.sanitizedPaneTitle("✳ ◐ Fixing the parser"),
            "Fixing the parser",
            "however many of them arrive together"
        )
        XCTAssertEqual(SessionOutline.sanitizedPaneTitle("✳"), "", "nothing but decoration")
        XCTAssertEqual(
            SessionOutline.sanitizedPaneTitle("~/src"),
            "~/src",
            "a shell's own title is punctuation too and keeps every character"
        )
        XCTAssertEqual(
            SessionOutline.sanitizedPaneTitle("Fixing ✳ the parser"),
            "Fixing ✳ the parser",
            "only the front is decoration"
        )
    }

    /// Captured from a live `claude` 2.1.234 PTY: one burst of OSC title
    /// writes carries `◑ Claude Code`, `◑ Say the word banana`, `✳ Claude
    /// Code`, `✳ Say the word banana` — the brand and the summary interleaved,
    /// either one landing last. Storing the brand is what made a named pane
    /// revert to "Claude Code".
    func testTheEnginesOwnBrandIsNotATitleAPaneWears() {
        for frame in ["", "✳ ", "◐ "] {
            XCTAssertTrue(
                SessionOutline.isEngineBrandTitle(
                    SessionOutline.sanitizedPaneTitle("\(frame)Claude Code")
                ),
                "\(frame)Claude Code says nothing about the conversation"
            )
        }
        XCTAssertTrue(SessionOutline.isEngineBrandTitle("Claude"), "the short form too")
        XCTAssertTrue(SessionOutline.isEngineBrandTitle("Codex"))
        XCTAssertFalse(
            SessionOutline.isEngineBrandTitle("Say the word banana"),
            "a summary is the whole point of reading the title"
        )
        XCTAssertFalse(
            SessionOutline.isEngineBrandTitle("Fixing Claude Code"),
            "the brand inside a real summary is still a real summary"
        )
    }

    func testAPaneWithNoProjectIsNamedRatherThanShownAsABlankRow() {
        XCTAssertEqual(SessionOutline.projectLabel(""), "No project")
        XCTAssertEqual(SessionOutline.projectLabel("alpha"), "alpha")
    }

    /// A terminal wears what the agent says it is doing. The number is only a
    /// placeholder for the gap before the agent has said anything — Claude
    /// publishes a summary of the task in flight as the terminal title, and
    /// that is the name worth showing.
    func testATerminalShowsWhatTheAgentIsWorkingOn() {
        var descriptor = pane("a", project: "alpha", group: "g1")
        descriptor.engine = .claude
        descriptor.autoNumber = 2

        XCTAssertEqual(SessionOutline.paneLabel(descriptor), "Claude 2", "nothing reported yet")

        descriptor.title = "Fixing the sidebar order"
        XCTAssertEqual(SessionOutline.paneLabel(descriptor), "Fixing the sidebar order")

        // And a name the user typed outranks both, permanently.
        descriptor.label = "Release prep"
        XCTAssertEqual(SessionOutline.paneLabel(descriptor), "Release prep")
        descriptor.title = "Something else entirely"
        XCTAssertEqual(SessionOutline.paneLabel(descriptor), "Release prep")
    }

    /// Regression: terminals were briefly *stored* under their generated name,
    /// which made every one of them look hand-named and outrank the agent's
    /// summary forever. Layouts carrying those names heal on the way in.
    func testAGeneratedNameIsRecognisedSoItCanBeDroppedOnRestore() {
        XCTAssertTrue(SessionOutline.isGeneratedPaneName("Claude 1"))
        XCTAssertTrue(SessionOutline.isGeneratedPaneName("Shell 12"))
        XCTAssertTrue(SessionOutline.isGeneratedPaneName("AntiGravity 3"))
        XCTAssertFalse(SessionOutline.isGeneratedPaneName("Release prep"))
        XCTAssertFalse(SessionOutline.isGeneratedPaneName("Claude"))
        XCTAssertFalse(SessionOutline.isGeneratedPaneName("Claude 1 backup"))
        XCTAssertFalse(SessionOutline.isGeneratedPaneName("Fixing Claude 1"))
    }

    func testPlaceholderNumbersArePerSessionPerEngineAndReuseTheLowestFree() {
        var first = pane("a", project: "alpha", group: "g1")
        first.engine = .claude
        first.autoNumber = 1
        var third = pane("c", project: "alpha", group: "g1")
        third.engine = .claude
        third.autoNumber = 3
        var other = pane("b", project: "alpha", group: "g2")
        other.engine = .claude
        other.autoNumber = 1
        let panes = [first, third, other]

        XCTAssertEqual(
            SessionOutline.nextPaneNumber(panes, group: "g1", engine: .claude),
            2,
            "the gap a closed terminal left is filled before the count climbs"
        )
        XCTAssertEqual(
            SessionOutline.nextPaneNumber(panes, group: "g2", engine: .claude),
            2,
            "each session numbers its own"
        )
        XCTAssertEqual(
            SessionOutline.nextPaneNumber(panes, group: "g1", engine: .shell),
            1,
            "and a shell does not push Claude along"
        )
    }

    // MARK: - Browser panes

    /// A browser pane's ladder mirrors the terminal's, with the URL where the
    /// cwd-flavoured fallbacks would be: user label → page title → last URL →
    /// a numbered `Browser N` placeholder.
    func testABrowserPaneIsNamedByItsOwnLadder() {
        var browser = pane("w", project: "alpha", group: "g1")
        browser.kind = .browser
        XCTAssertEqual(SessionOutline.defaultPaneName(browser), "Browser 1")
        XCTAssertEqual(SessionOutline.paneLabel(browser), "Browser 1", "nothing loaded yet")

        browser.browserURL = "https://example.com"
        XCTAssertEqual(SessionOutline.paneLabel(browser), "https://example.com", "the URL beats the placeholder")

        browser.title = "Example Domain"
        XCTAssertEqual(SessionOutline.paneLabel(browser), "Example Domain", "the page title beats the URL")

        browser.label = "Docs"
        XCTAssertEqual(SessionOutline.paneLabel(browser), "Docs", "and the user's own name beats everything")

        var terminal = pane("t", project: "alpha", group: "g1")
        terminal.autoNumber = 2
        XCTAssertEqual(SessionOutline.defaultPaneName(terminal), "Shell 2", "terminals keep the engine ladder")
    }

    func testBrowserNumbersAreIndependentOfTerminalsInTheSameSession() {
        var shellPane = pane("a", project: "alpha", group: "g1")
        shellPane.autoNumber = 1
        var browser = pane("w", project: "alpha", group: "g1")
        browser.kind = .browser
        browser.autoNumber = 1

        XCTAssertEqual(
            SessionOutline.nextPaneNumber([shellPane, browser], group: "g1", engine: .shell),
            2,
            "the shell ladder counts only terminals"
        )
        XCTAssertEqual(
            SessionOutline.nextPaneNumber([browser], group: "g1", engine: .shell),
            1,
            "a browser does not push shells along"
        )
        XCTAssertEqual(
            SessionOutline.nextPaneNumber([shellPane, browser], group: "g1", engine: .shell, kind: .browser),
            2,
            "browsers number their own, whatever engine the descriptor happens to carry"
        )
    }

    func testAGeneratedBrowserNameIsRecognisedSoItCanBeDroppedOnRestore() {
        XCTAssertTrue(SessionOutline.isGeneratedPaneName("Browser 2"))
        XCTAssertFalse(SessionOutline.isGeneratedPaneName("Browser"))
        XCTAssertFalse(SessionOutline.isGeneratedPaneName("Browser tab 2"))
    }

    // MARK: - newSessionGroupID
    // Ported from `describe("newSessionGroupId")`. `SessionOutline`'s
    // `groupCounter` is a bare `private static var` that is never reset
    // between tests, so distinctness is the only thing that may be asserted
    // — never an absolute value.

    func testFiftySuccessiveSessionGroupIDsAreAllDistinct() {
        let ids = Set((0..<50).map { _ in SessionOutline.newSessionGroupID() })
        XCTAssertEqual(ids.count, 50)
    }

    /// A group id `SessionIdentifier.isValid` rejects is silently dropped by
    /// `PersistedLayoutCodec.serialize`, which would un-group every pane on
    /// the next launch.
    func testAMintedSessionGroupIDIsOneTheLayoutPersisterWillKeep() {
        XCTAssertTrue(SessionIdentifier.isValid(SessionOutline.newSessionGroupID()))
    }

    // MARK: - group — the oracle cases the existing port did not cover

    func testUnnamedSessionsAreNumberedPerProjectAndStoreNoName() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "p1", group: "g1"),
                pane("b", project: "p1", group: "g2"),
                pane("c", project: "p2", group: "g9"),
            ],
            focusedPaneID: nil
        )
        XCTAssertEqual(tree[0].sessions.map(\.label), ["Session 1", "Session 2"])
        XCTAssertEqual(tree[1].sessions.map(\.label), ["Session 1"], "numbering restarts per project")
        XCTAssertEqual(
            tree[0].sessions.map(\.name),
            [nil, nil],
            "and nothing was stored — these are derived defaults"
        )
    }

    func testTwoSessionsEachCarryTheirOwnRoot() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "p1", group: "g1", cwd: "/repo"),
                pane("b", project: "p1", group: "g1", cwd: "/repo/packages/api"),
                pane("c", project: "p1", group: "g2", cwd: "/repo/packages/web"),
            ],
            focusedPaneID: nil
        )
        XCTAssertEqual(tree[0].sessions.map(\.cwd), ["/repo", "/repo/packages/web"])
    }

    func testPreGroupingPanesCollectIntoOneImplicitSessionPerProject() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "p1", group: WorkspaceRestoration.ungroupedSessionID),
                pane("b", project: "p1", group: WorkspaceRestoration.ungroupedSessionID),
                pane("c", project: "p2", group: WorkspaceRestoration.ungroupedSessionID),
            ],
            focusedPaneID: nil
        )
        XCTAssertEqual(tree[0].sessions.count, 1)
        XCTAssertEqual(tree[0].sessions[0].id, WorkspaceRestoration.ungroupedSessionID)
        XCTAssertEqual(tree[0].sessions[0].paneIDs, ["a", "b"])
        XCTAssertEqual(tree[1].sessions[0].id, WorkspaceRestoration.ungroupedSessionID)
    }

    func testNoPanesMakeAnEmptyTree() {
        XCTAssertTrue(SessionOutline.group([], focusedPaneID: nil).isEmpty)
    }

    /// The regression stored names exist to kill: labelling was positional
    /// at first — "the 2nd session in this project is Session 2" — which
    /// quietly renamed every session below one that closed.
    func testAStoredNameStaysStableWhenAnEarlierSessionCloses() {
        let all = [
            pane("a", project: "p1", group: "g1", groupLabel: "Session 1"),
            pane("b", project: "p1", group: "g2", groupLabel: "Session 2"),
        ]
        let afterClosingTheFirst = SessionOutline.group(Array(all.dropFirst()), focusedPaneID: nil)
        XCTAssertEqual(afterClosingTheFirst[0].sessions[0].label, "Session 2")
    }

    // MARK: - nextSessionName — the oracle cases the existing port did not cover

    func testTheNextSessionNameSkipsANumberTheUserTypedOntoASession() {
        let live = [
            pane("a", project: "p1", group: "g1", groupLabel: "Session 1"),
            pane("b", project: "p1", group: "g2", groupLabel: "Session 2"),
        ]
        XCTAssertEqual(SessionOutline.nextSessionName(live, project: "p1"), "Session 3")
    }

    /// "Taken" means the name a session *shows*, stored or derived, because
    /// the collision that matters is two rows reading the same.
    func testTheNextSessionNameSkipsDerivedNamesToo() {
        XCTAssertEqual(
            SessionOutline.nextSessionName([pane("a", project: "p1", group: "g1")], project: "p1"),
            "Session 2"
        )
    }

    func testANonNumericSessionNameOccupiesNoNumber() {
        XCTAssertEqual(
            SessionOutline.nextSessionName(
                [pane("a", project: "p1", group: "g1", groupLabel: "auth refactor")],
                project: "p1"
            ),
            "Session 1"
        )
    }

    private func pane(
        _ id: String,
        project: String,
        group: String,
        groupLabel: String? = nil,
        cwd: String = "/",
        label: String? = nil,
        engine: Engine = .shell,
        kind: PaneKind = .terminal
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: groupLabel,
            project: project,
            engine: engine,
            cwd: cwd,
            label: label,
            kind: kind
        )
    }
}

/// An `NSView` that accepts first-responder status and then refuses to give
/// it up — the only reliable way to make `NSWindow.makeFirstResponder` return
/// `false` in a test, which is the case `beginRename`'s latch has to survive.
private final class StubbornResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool { false }
}

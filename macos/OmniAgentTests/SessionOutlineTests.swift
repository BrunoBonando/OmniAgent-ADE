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

    private func pane(
        _ id: String,
        project: String,
        group: String,
        groupLabel: String? = nil,
        cwd: String = "/",
        label: String? = nil
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: groupLabel,
            project: project,
            engine: .shell,
            cwd: cwd,
            label: label
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

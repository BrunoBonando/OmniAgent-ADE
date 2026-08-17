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

    func testAPaneRowPrefersItsOwnNameThenItsLiveTitleThenItsEngine() {
        XCTAssertEqual(
            SessionOutline.paneLabel(pane("a", project: "p", group: "g", label: "migrate")),
            "migrate"
        )
        var titled = pane("a", project: "p", group: "g")
        titled.title = "~/src"
        XCTAssertEqual(SessionOutline.paneLabel(titled), "~/src")
        XCTAssertEqual(SessionOutline.paneLabel(pane("a", project: "p", group: "g")), "shell")
    }

    func testAPaneWithNoProjectIsNamedRatherThanShownAsABlankRow() {
        XCTAssertEqual(SessionOutline.projectLabel(""), "No project")
        XCTAssertEqual(SessionOutline.projectLabel("alpha"), "alpha")
    }

    /// Terminals in a session are told apart by name. Without this every
    /// Claude pane fell back to the engine's own name and a session full of
    /// them read `claude`, `claude`, `claude`.
    func testTerminalsInASessionAreNamedApart() {
        var panes: [PaneDescriptor] = []
        XCTAssertEqual(SessionOutline.nextPaneName(panes, group: "g1", engine: .claude), "Claude 1")

        panes.append(pane("a", project: "alpha", group: "g1", label: "Claude 1"))
        XCTAssertEqual(SessionOutline.nextPaneName(panes, group: "g1", engine: .claude), "Claude 2")

        // Engines are numbered independently — a shell does not push Claude on.
        XCTAssertEqual(SessionOutline.nextPaneName(panes, group: "g1", engine: .shell), "Shell 1")
    }

    func testPaneNumberingIsPerSessionAndReusesTheLowestFreeNumber() {
        let panes = [
            pane("a", project: "alpha", group: "g1", label: "Claude 1"),
            pane("c", project: "alpha", group: "g1", label: "Claude 3"),
            pane("b", project: "alpha", group: "g2", label: "Claude 1"),
        ]

        XCTAssertEqual(
            SessionOutline.nextPaneName(panes, group: "g1", engine: .claude),
            "Claude 2",
            "the gap left by a closed terminal is filled before the count climbs"
        )
        XCTAssertEqual(
            SessionOutline.nextPaneName(panes, group: "g2", engine: .claude),
            "Claude 2",
            "and each session numbers its own, so g1's three do not push g2 along"
        )
    }

    /// The name has to beat the OSC title, or agents — which set the same
    /// title in every pane, and none at all until their first prompt — put the
    /// collision straight back.
    func testAStoredNameWinsOverTheTitleTheTerminalReports() {
        var descriptor = pane("a", project: "alpha", group: "g1", label: "Claude 2")
        descriptor.title = "claude"
        XCTAssertEqual(SessionOutline.paneLabel(descriptor), "Claude 2")
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

import XCTest
@testable import OmniAgent

/// The launch-time `layout` -> panes translation, and its inverse. The
/// per-field repair one level down (a bad `themeId`, a duplicate id) is
/// `PersistedLayoutTests`' job; these cover only what becoming a *pane* adds.
final class WorkspaceRestorationTests: XCTestCase {
    // MARK: - plan

    func testRestoresEveryTabInOrderKeepingItsOwnSessionID() {
        let raw = PersistedLayoutCodec.serialize([
            PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: "sess-a", group: "grp-1", groupLabel: "Session 1"),
            PersistedTab(project: "beta", engine: .codex, cwd: "/b", id: "sess-b", group: "grp-2"),
        ])

        let panes = WorkspaceRestoration.plan(fromLayout: raw)

        XCTAssertEqual(panes.map(\.sessionID), ["sess-a", "sess-b"])
        XCTAssertTrue(panes.allSatisfy(\.reattaches), "a stored id means the daemon may still own that session")
        XCTAssertEqual(panes.map(\.project), ["alpha", "beta"])
        XCTAssertEqual(panes.map(\.engine), [.claude, .codex])
        XCTAssertEqual(panes.map(\.cwd), ["/a", "/b"])
        XCTAssertEqual(panes.map(\.group), ["grp-1", "grp-2"])
        XCTAssertEqual(panes.first?.groupLabel, "Session 1")
    }

    func testATabWithNoIDStillRestoresAsAFreshSession() {
        let raw = #"{"tabs":[{"project":"alpha","engine":"shell","cwd":"/a"}]}"#

        let panes = WorkspaceRestoration.plan(fromLayout: raw) { "minted-1" }

        XCTAssertEqual(panes.map(\.sessionID), ["minted-1"])
        XCTAssertEqual(panes.map(\.reattaches), [false], "there is nothing to reattach to")
        XCTAssertEqual(panes.first?.project, "alpha")
    }

    func testAMintedIDNeverCollidesWithARestoredOneOrFailsTheBackendsIDGate() {
        let raw = #"""
        {"tabs":[
          {"project":"a","engine":"shell","cwd":"/a","id":"taken"},
          {"project":"b","engine":"shell","cwd":"/b"},
          {"project":"c","engine":"shell","cwd":"/c"}
        ]}
        """#

        // A generator that always returns an id already in use, and one that
        // returns an id the backend would reject outright.
        let collided = WorkspaceRestoration.plan(fromLayout: raw) { "taken" }
        XCTAssertEqual(collided.count, 3)
        XCTAssertEqual(Set(collided.map(\.sessionID)).count, 3, "every pane keeps its own id")
        XCTAssertTrue(collided.allSatisfy { SessionIdentifier.isValid($0.sessionID) })

        let rejected = WorkspaceRestoration.plan(fromLayout: raw) { "not a valid id!" }
        XCTAssertTrue(rejected.allSatisfy { SessionIdentifier.isValid($0.sessionID) })
    }

    func testMoreTabsThanPanesRestoresTheFirstEightRatherThanNothing() {
        let tabs = (0..<12).map {
            PersistedTab(project: "p", engine: .shell, cwd: "/p", id: "sess-\($0)")
        }

        let panes = WorkspaceRestoration.plan(fromLayout: PersistedLayoutCodec.serialize(tabs))

        XCTAssertEqual(panes.count, PaneGrid.maxPanes)
        XCTAssertEqual(panes.map(\.sessionID), (0..<PaneGrid.maxPanes).map { "sess-\($0)" })
    }

    func testAMissingCorruptOrEmptyLayoutPlansNothingRatherThanThrowing() {
        XCTAssertTrue(WorkspaceRestoration.plan(fromLayout: nil).isEmpty)
        XCTAssertTrue(WorkspaceRestoration.plan(fromLayout: "").isEmpty)
        XCTAssertTrue(WorkspaceRestoration.plan(fromLayout: "}{ not json").isEmpty)
        XCTAssertTrue(WorkspaceRestoration.plan(fromLayout: #"{"tabs":[]}"#).isEmpty)
    }

    func testATabWithNoGroupRestoresIntoTheUngroupedSentinel() {
        let raw = #"{"tabs":[{"project":"a","engine":"shell","cwd":"/a","id":"sess-a"}]}"#

        let panes = WorkspaceRestoration.plan(fromLayout: raw)

        XCTAssertEqual(panes.first?.group, WorkspaceRestoration.ungroupedSessionID)
        XCTAssertTrue(
            SessionIdentifier.isValid(WorkspaceRestoration.ungroupedSessionID),
            "the sentinel travels through the same field a real group id does"
        )
    }

    // MARK: - persistedTabs

    func testLivePanesRoundTripBackThroughTheLayoutRow() {
        let raw = PersistedLayoutCodec.serialize([
            PersistedTab(
                project: "alpha",
                engine: .claude,
                cwd: "/a",
                id: "sess-a",
                label: "build",
                themeId: .matrix,
                group: "grp-1",
                groupLabel: "Session 1"
            ),
        ])
        let panes = WorkspaceRestoration.plan(fromLayout: raw).map(PaneDescriptor.init)

        let round = WorkspaceRestoration.plan(
            fromLayout: PersistedLayoutCodec.serialize(WorkspaceRestoration.persistedTabs(from: panes))
        )

        XCTAssertEqual(round, WorkspaceRestoration.plan(fromLayout: raw))
    }

    func testAPaneWithNoProjectIsNotWrittenToTheSharedLayoutRow() {
        let panes = [
            PaneDescriptor(WorkspaceRestoration.bootstrapPane(sessionID: "native-1")),
            PaneDescriptor(
                sessionID: "sess-a",
                group: "grp-1",
                project: "alpha",
                engine: .codex,
                cwd: "/a"
            ),
        ]

        let tabs = WorkspaceRestoration.persistedTabs(from: panes)

        XCTAssertEqual(tabs.map(\.project), ["alpha"], "an ad-hoc native pane names no project, so it stores none")
        XCTAssertEqual(tabs.map(\.id), ["sess-a"])
    }

    func testTheUngroupedSentinelIsStoredAsAnAbsentGroupNotAsALiteral() {
        let panes = [
            PaneDescriptor(
                sessionID: "sess-a",
                group: WorkspaceRestoration.ungroupedSessionID,
                project: "alpha",
                engine: .shell,
                cwd: "/a"
            ),
        ]

        let json = PersistedLayoutCodec.serialize(WorkspaceRestoration.persistedTabs(from: panes))

        XCTAssertNil(WorkspaceRestoration.persistedTabs(from: panes).first?.group)
        XCTAssertFalse(json.contains(WorkspaceRestoration.ungroupedSessionID))
        XCTAssertEqual(
            WorkspaceRestoration.plan(fromLayout: json).first?.group,
            WorkspaceRestoration.ungroupedSessionID,
            "and reads back as ungrouped, exactly like a web-written tab"
        )
    }

    func testClosingEveryRestoredPaneWritesAnEmptyLayoutRatherThanLeavingStaleTabs() {
        XCTAssertEqual(PersistedLayoutCodec.serialize(WorkspaceRestoration.persistedTabs(from: [])), #"{"tabs":[]}"#)
    }

    // MARK: - bootstrap

    func testTheBootstrapPaneIsOneUngroupedShellInTheHomeDirectory() {
        let pane = WorkspaceRestoration.bootstrapPane(sessionID: "native-terminal")

        XCTAssertEqual(pane.sessionID, "native-terminal")
        XCTAssertFalse(pane.reattaches)
        XCTAssertEqual(pane.engine, .shell)
        XCTAssertEqual(pane.cwd, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(pane.group, WorkspaceRestoration.ungroupedSessionID)
        XCTAssertTrue(pane.project.isEmpty)
    }
}

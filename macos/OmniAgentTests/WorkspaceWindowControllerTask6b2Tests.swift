import XCTest
@testable import OmniAgent

/// Task 6b-2's wiring into `WorkspaceWindowController`: the settings/
/// inspector menu entry points, and the usage-analytics recording that
/// happens at pane-creation time without needing a live daemon connection
/// (the daemon-dependent paths — `refreshProjectLabels`, brain search,
/// onboarding presentation — are covered at the view-model layer in
/// `UsageAnalyticsRecorderTests`/`AuthGateCoordinatorTests`/
/// `FirstRunViewModelTests`/`InspectorViewModelTests`, the same split every
/// other daemon-backed feature in this app already uses).
final class WorkspaceWindowControllerTask6b2Tests: XCTestCase {
    func testSettingsAndInspectorAreOnTheMenuAndTravelTheResponderChain() throws {
        ApplicationMenus.install()
        let app = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "OmniAgent")?.submenu)
        let settings = try XCTUnwrap(app.item(withTitle: "Settings…"))
        XCTAssertNil(settings.target, "travels the responder chain like every other command")
        XCTAssertEqual(settings.action, #selector(WorkspaceWindowController.showSettings(_:)))
        XCTAssertEqual(settings.keyEquivalent, ",")

        let window = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Window")?.submenu)
        let inspector = try XCTUnwrap(window.item(withTitle: "Show Inspector"))
        XCTAssertNil(inspector.target)
        XCTAssertEqual(inspector.action, #selector(WorkspaceWindowController.showInspectorPanel(_:)))
        XCTAssertEqual(inspector.keyEquivalent, "i")
    }

    func testAddingAPaneRecordsBothATerminalAndASessionInUsageAnalytics() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1"),
                ])
            )
        )

        let project = try XCTUnwrap(controller.usageRecorder.store.projects["alpha"])
        XCTAssertEqual(project.totals.terminalsOpened, 1)
        XCTAssertEqual(project.totals.sessionsOpened, 1)
        let global = try XCTUnwrap(controller.usageRecorder.store.projects[UsageAnalytics.globalProject])
        XCTAssertEqual(global.totals.terminalsOpened, 1, "fans out into __all__ too")
    }

    func testASecondPaneInTheSameGroupCountsOnlyAsANewTerminal() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1"),
                ])
            )
        )

        controller.newTerminalPane(nil)

        let project = try XCTUnwrap(controller.usageRecorder.store.projects["alpha"])
        XCTAssertEqual(project.totals.terminalsOpened, 2)
        XCTAssertEqual(project.totals.sessionsOpened, 1, "still one session — the new pane joined it")
    }

    func testShowingSettingsInspectorAndRunningASearchRowNeverCrashWithoutALiveConnection() throws {
        // These daemon-backed operations can't succeed against the dead
        // socket `makeController` points at, but they must fail quietly —
        // this locks that contract rather than a crash regression.
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1"),
                ])
            )
        )

        controller.showSettings(nil)
        controller.showInspectorPanel(nil)
        controller.run(.searchBrain(query: "anything"))
        controller.run(.revealProjectContext(project: "alpha"))
        controller.run(.noop)
        controller.refreshProjectLabels()

        XCTAssertTrue(controller.projectLabels.isEmpty, "the disconnected read never completed")
        controller.inspector.close()
    }

    private func makeEmptyController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-controller-6b2-test.sock")
            ),
            panes: []
        )
    }
}

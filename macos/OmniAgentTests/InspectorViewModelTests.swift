import XCTest
@testable import OmniAgent

final class InspectorViewModelTests: XCTestCase {
    func testLoadPopulatesContextStalenessAndPausedFromTheClient() {
        let client = FakeBrainAdminClient()
        client.getContextResults["alpha"] = .success(
            BrainContext(
                summary: "A project",
                recentDecisions: [BrainNodeView(id: "d1", kind: "decision", project: "alpha", label: "Use X", path: nil, summary: nil)],
                relatedProjects: [],
                memoryNotes: []
            )
        )
        client.stalenessResult = .success([ProjectStaleness(project: "alpha", lastIngested: 100, stale: true)])
        client.pausedProjectsResult = .success(["alpha"])
        let model = InspectorViewModel(project: "alpha", label: "Alpha", client: client)

        model.load()

        XCTAssertEqual(model.context?.summary, "A project")
        XCTAssertEqual(model.context?.recentDecisions.first?.label, "Use X")
        XCTAssertEqual(model.staleness?.stale, true)
        XCTAssertTrue(model.isPaused)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testLoadOfAnEmptyProjectIsANoOp() {
        let client = FakeBrainAdminClient()
        let model = InspectorViewModel(project: "", label: "", client: client)

        model.load()

        XCTAssertNil(model.context)
        XCTAssertFalse(model.isLoading)
    }

    func testTogglePauseIsOptimisticAndRevertsOnFailure() {
        let client = FakeBrainAdminClient()
        let model = InspectorViewModel(project: "alpha", label: "Alpha", client: client)
        XCTAssertFalse(model.isPaused)

        model.togglePause()
        XCTAssertTrue(model.isPaused, "flips immediately")
        XCTAssertEqual(client.setPausedCalls.last?.paused, true)

        // A second toggle that fails must revert.
        client.setPausedResult = .failure(SessionConnectionError.disconnected)
        model.togglePause()
        XCTAssertTrue(model.isPaused, "reverted back to true after the failed flip to false")
    }

    func testReingestClearsBusyAndReloadsOnSuccess() {
        let client = FakeBrainAdminClient()
        client.getContextResults["alpha"] = .success(BrainContext(summary: "fresh", recentDecisions: [], relatedProjects: [], memoryNotes: []))
        let model = InspectorViewModel(project: "alpha", label: "Alpha", client: client)

        model.reingest()

        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(client.reingestCalls, ["alpha"])
        XCTAssertEqual(model.context?.summary, "fresh", "a successful re-check reloads the context")
    }

    func testRenameIgnoresBlankOrUnchangedNamesAndCallsBackOnSuccess() {
        let client = FakeBrainAdminClient()
        let model = InspectorViewModel(project: "alpha", label: "Alpha", client: client)
        var renamed: (String, String)?
        model.onRenamed = { renamed = ($0, $1) }

        model.rename(to: "   ")
        model.rename(to: "Alpha")
        XCTAssertTrue(client.renameCalls.isEmpty, "blank and unchanged names never call the client")

        model.rename(to: "  Renamed  ")
        XCTAssertEqual(client.renameCalls.map(\.newLabel), ["Renamed"], "trimmed before sending")
        XCTAssertEqual(model.projectLabel, "Renamed")
        XCTAssertEqual(renamed?.0, "alpha")
        XCTAssertEqual(renamed?.1, "Renamed")
    }
}

import XCTest
@testable import OmniAgent

/// An in-memory `IngestionClient` — no daemon, so `FirstRunViewModel`'s
/// pick -> ingest -> poll -> done sequence is testable without a socket.
final class FakeIngestionClient: IngestionClient {
    var startIngestResult: Result<Void, Error> = .success(())
    var statusResults: [Result<IngestionStatus, Error>] = []
    var biggestProjectResult: Result<BrainProjectSummary?, Error> = .success(nil)
    var rootsListResult: Result<[String], Error> = .success([])
    private(set) var startedPaths: [String] = []
    private(set) var statusPollCount = 0
    private(set) var biggestProjectCallCount = 0

    func startIngest(path: String, completion: ((Result<Void, Error>) -> Void)?) {
        startedPaths.append(path)
        completion?(startIngestResult)
    }

    func ingestionStatus(completion: @escaping (Result<IngestionStatus, Error>) -> Void) {
        let index = min(statusPollCount, statusResults.count - 1)
        statusPollCount += 1
        guard index >= 0 else { return }
        completion(statusResults[index])
    }

    func biggestProject(completion: @escaping (Result<BrainProjectSummary?, Error>) -> Void) {
        biggestProjectCallCount += 1
        completion(biggestProjectResult)
    }

    func rootsList(completion: @escaping (Result<[String], Error>) -> Void) {
        completion(rootsListResult)
    }
}

final class FirstRunViewModelTests: XCTestCase {
    private func status(running: Bool, total: Int = 0, done: Int = 0, nodes: Int = 0) -> IngestionStatus {
        IngestionStatus(running: running, projectsTotal: total, projectsDone: done, currentProject: nil, totalNodes: nodes, error: nil)
    }

    func testStartIngestingMovesToTheIngestingPhaseAndPollsOnce() {
        let ingestion = FakeIngestionClient()
        ingestion.statusResults = [.success(status(running: true, total: 2, done: 1))]
        let model = FirstRunViewModel(ingestion: ingestion)

        model.startIngesting(at: "/projects")

        XCTAssertEqual(ingestion.startedPaths, ["/projects"])
        XCTAssertEqual(model.state.phase, .ingesting)
        XCTAssertFalse(model.isPicking)
        XCTAssertEqual(ingestion.statusPollCount, 1, "startPolling polls immediately, not just on the timer")
    }

    func testAFailedStartIngestSurfacesTheErrorAndStaysOnPick() {
        let ingestion = FakeIngestionClient()
        ingestion.startIngestResult = .failure(SessionConnectionError.disconnected)
        let model = FirstRunViewModel(ingestion: ingestion)

        model.startIngesting(at: "/projects")

        XCTAssertEqual(model.state.phase, .pick)
        XCTAssertNotNil(model.pickError)
        XCTAssertFalse(model.isPicking)
    }

    func testPollingUntilFinishedMovesToDoneAndFetchesTheBiggestProject() {
        let ingestion = FakeIngestionClient()
        ingestion.statusResults = [
            .success(status(running: true, total: 2, done: 1)),
            .success(status(running: false, total: 2, done: 2, nodes: 50)),
        ]
        ingestion.biggestProjectResult = .success(BrainProjectSummary(id: "alpha", label: "Alpha", path: "/a"))
        let model = FirstRunViewModel(ingestion: ingestion)

        model.startIngesting(at: "/projects")
        model.poll()

        XCTAssertEqual(model.state.phase, .done)
        XCTAssertEqual(ingestion.biggestProjectCallCount, 1)
        XCTAssertEqual(model.biggestProject?.id, "alpha")
    }

    func testFinishingWithNoProjectsFoundNeverAsksForTheBiggestProject() {
        let ingestion = FakeIngestionClient()
        ingestion.statusResults = [
            .success(status(running: true, total: 0, done: 0)),
            .success(status(running: false, total: 0, done: 0)),
        ]
        let model = FirstRunViewModel(ingestion: ingestion)

        model.startIngesting(at: "/empty")
        model.poll()

        XCTAssertEqual(model.state.phase, .done)
        XCTAssertEqual(ingestion.biggestProjectCallCount, 0, "projects_total == 0 means nothing to look up")
        XCTAssertNil(model.biggestProject)
    }

    func testRetryReturnsToPickAndClearsTheBiggestProjectAndError() {
        let ingestion = FakeIngestionClient()
        ingestion.statusResults = [.success(status(running: true)), .success(status(running: false))]
        let model = FirstRunViewModel(ingestion: ingestion)
        model.startIngesting(at: "/projects")
        model.poll()
        XCTAssertEqual(model.state.phase, .done)

        model.retry()

        XCTAssertEqual(model.state, OnboardingReducer.initial)
        XCTAssertNil(model.biggestProject)
        XCTAssertNil(model.pickError)
    }

    func testPickFolderDoesNothingWithoutAChooserAndUsesTheInjectedOneWhenPresent() {
        let ingestion = FakeIngestionClient()
        ingestion.statusResults = [.success(status(running: true))]
        let model = FirstRunViewModel(ingestion: ingestion)

        model.pickFolder()
        XCTAssertTrue(ingestion.startedPaths.isEmpty, "no chooser installed yet")

        model.folderChooser = { completion in completion("/chosen") }
        model.pickFolder()
        XCTAssertEqual(ingestion.startedPaths, ["/chosen"])

        // Cancelling (nil path) starts nothing.
        model.folderChooser = { completion in completion(nil) }
        model.pickFolder()
        XCTAssertEqual(ingestion.startedPaths, ["/chosen"], "cancel adds nothing")
    }
}

final class FirstRunWindowControllerTests: XCTestCase {
    func testNeedsPresentingIsTrueOnlyWhenRootsListIsEmpty() {
        let empty = FakeIngestionClient()
        empty.rootsListResult = .success([])
        let emptyExpectation = expectation(description: "empty")
        FirstRunWindowController.needsPresenting(ingestion: empty) { needed in
            XCTAssertTrue(needed)
            emptyExpectation.fulfill()
        }
        wait(for: [emptyExpectation], timeout: 1)

        let populated = FakeIngestionClient()
        populated.rootsListResult = .success(["/one"])
        let populatedExpectation = expectation(description: "populated")
        FirstRunWindowController.needsPresenting(ingestion: populated) { needed in
            XCTAssertFalse(needed)
            populatedExpectation.fulfill()
        }
        wait(for: [populatedExpectation], timeout: 1)
    }

    func testNeedsPresentingFailsOpenOnAReadError() {
        let failing = FakeIngestionClient()
        failing.rootsListResult = .failure(SessionConnectionError.disconnected)
        let expectation = expectation(description: "fail open")
        FirstRunWindowController.needsPresenting(ingestion: failing) { needed in
            XCTAssertFalse(needed, "never trap the user behind a broken check")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}

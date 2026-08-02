import XCTest
@testable import OmniAgent

final class OnboardingStateTests: XCTestCase {
    private func status(
        running: Bool,
        total: Int = 0,
        done: Int = 0,
        current: String? = nil,
        nodes: Int = 0,
        error: String? = nil
    ) -> IngestionStatus {
        IngestionStatus(running: running, projectsTotal: total, projectsDone: done, currentProject: current, totalNodes: nodes, error: error)
    }

    func testRootPickedMovesToIngestingAndResetsEverRunning() {
        let state = OnboardingReducer.reduce(OnboardingReducer.initial, .rootPicked)
        XCTAssertEqual(state, OnboardingState(phase: .ingesting, everRunning: false, status: nil))
    }

    func testAPollBeforeAnyRootIsPickedIsIgnored() {
        let state = OnboardingReducer.reduce(OnboardingReducer.initial, .statusPolled(status: status(running: true)))
        XCTAssertEqual(state, OnboardingReducer.initial, "still phase .pick — nothing to poll yet")
    }

    func testPollingWhileRunningStaysInIngestingAndTracksEverRunning() {
        var state = OnboardingReducer.reduce(OnboardingReducer.initial, .rootPicked)
        state = OnboardingReducer.reduce(state, .statusPolled(status: status(running: true, total: 3, done: 1)))
        XCTAssertEqual(state.phase, .ingesting)
        XCTAssertTrue(state.everRunning)
        XCTAssertEqual(state.status?.projectsDone, 1)
    }

    func testTransitioningFromRunningToNotRunningFinishesAsDone() {
        var state = OnboardingReducer.reduce(OnboardingReducer.initial, .rootPicked)
        state = OnboardingReducer.reduce(state, .statusPolled(status: status(running: true, total: 3, done: 1)))
        state = OnboardingReducer.reduce(state, .statusPolled(status: status(running: false, total: 3, done: 3, nodes: 42)))
        XCTAssertEqual(state.phase, .done)
        XCTAssertTrue(state.everRunning)
        XCTAssertEqual(state.status?.totalNodes, 42)
    }

    func testAStillFalseStatusRightAfterPickingNeverFinishesEarly() {
        // The daemon's background thread hasn't run its first update yet —
        // `running: false, projects_total: 0` right after `.rootPicked` must
        // not be read as "already done".
        var state = OnboardingReducer.reduce(OnboardingReducer.initial, .rootPicked)
        state = OnboardingReducer.reduce(state, .statusPolled(status: status(running: false)))
        XCTAssertEqual(state.phase, .ingesting, "never having run yet is not the same as having finished")
        XCTAssertFalse(state.everRunning)
    }

    func testRetryResetsToTheInitialState() {
        var state = OnboardingReducer.reduce(OnboardingReducer.initial, .rootPicked)
        state = OnboardingReducer.reduce(state, .statusPolled(status: status(running: true)))
        state = OnboardingReducer.reduce(state, .statusPolled(status: status(running: false)))
        XCTAssertEqual(state.phase, .done)

        state = OnboardingReducer.reduce(state, .retry)
        XCTAssertEqual(state, OnboardingReducer.initial)
    }

    func testAPollOnceDoneIsIgnored() {
        var state = OnboardingReducer.reduce(OnboardingReducer.initial, .rootPicked)
        state = OnboardingReducer.reduce(state, .statusPolled(status: status(running: true)))
        state = OnboardingReducer.reduce(state, .statusPolled(status: status(running: false, nodes: 10)))
        XCTAssertEqual(state.phase, .done)

        let after = OnboardingReducer.reduce(state, .statusPolled(status: status(running: true, nodes: 999)))
        XCTAssertEqual(after, state, "a stray late poll after done must not resurrect the HUD")
    }
}

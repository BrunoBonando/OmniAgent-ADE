import XCTest
@testable import OmniAgent

/// The connect ceremony (2026-09-01 remote environment sharing spec §6,
/// Task 24): the state machine (`RemoteConnectCeremony`), never driven by a
/// timer, and the glass it is shown through (`RemoteConnectCeremonyOverlayView`),
/// verified by offscreen render — never by eye, `testWindow()`'s own
/// reasoning (`RemoteSessionPickerTests.testWindow()`'s pattern).
@MainActor
final class RemoteConnectCeremonyTests: XCTestCase {
    // MARK: - The state machine

    func testEachStepAdvancesOnItsRealMilestone() {
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        XCTAssertEqual(ceremony.step, .dialling)
        ceremony.webSocketOpened(); XCTAssertEqual(ceremony.step, .securing)
        ceremony.dataChannelOpened(); XCTAssertEqual(ceremony.step, .confirming)
        ceremony.helloAcknowledged(); XCTAssertEqual(ceremony.step, .loading)
        ceremony.environmentLoaded(); XCTAssertEqual(ceremony.step, .done)
    }

    func testAFailureShowsThatStepsOwnMessage() {
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        ceremony.webSocketOpened()
        ceremony.dataChannelOpened()
        ceremony.failed(.init(message: "in use by MacBook Pro"))
        XCTAssertEqual(ceremony.failure?.step, .confirming)
        XCTAssertEqual(ceremony.failure?.message, "in use by MacBook Pro")
    }

    /// A step advancing clears whatever the *previous* attempt failed with —
    /// the ceremony's own reset, not merely the view's: a stale red row must
    /// not survive into a step that has genuinely moved past it.
    func testAdvancingPastAFailureClearsIt() {
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        ceremony.webSocketOpened()
        ceremony.failed(.init(message: "a transient error"))
        XCTAssertNotNil(ceremony.failure)
        ceremony.dataChannelOpened()
        XCTAssertNil(ceremony.failure, "the next real milestone clears the last failure")
    }

    /// `retry()` — Try again, and the automatic reconnect-retry path — puts
    /// the ceremony back at square one, real milestones and all: nothing
    /// here should ever look "half-retried".
    func testRetryResetsToDiallingAndClearsFailure() {
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        ceremony.webSocketOpened()
        ceremony.dataChannelOpened()
        ceremony.failed(.init(message: "in use by MacBook Pro", code: "lease_held"))
        ceremony.retry()
        XCTAssertEqual(ceremony.step, .dialling)
        XCTAssertNil(ceremony.failure)
    }

    /// `onDone` fires exactly once, and only from `environmentLoaded()` —
    /// never from any of the other three milestones, which is the whole
    /// point of it being a separate hook from `onChange`.
    func testOnDoneFiresOnlyOnceFromEnvironmentLoaded() {
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        var doneCount = 0
        ceremony.onDone = { doneCount += 1 }
        ceremony.webSocketOpened()
        ceremony.dataChannelOpened()
        ceremony.helloAcknowledged()
        XCTAssertEqual(doneCount, 0, "not done until the environment actually loads")
        ceremony.environmentLoaded()
        XCTAssertEqual(doneCount, 1)
    }

    /// `onChange` fires for every state-changing call — the driving code in
    /// `WorkspaceWindowController` depends on this to know when to repaint,
    /// and a missed notification would leave the overlay showing a step that
    /// has already moved on.
    func testOnChangeFiresOnEveryTransition() {
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        var changes = 0
        ceremony.onChange = { changes += 1 }
        ceremony.webSocketOpened()
        ceremony.dataChannelOpened()
        ceremony.helloAcknowledged()
        ceremony.failed(.init(message: "x"))
        ceremony.retry()
        XCTAssertEqual(changes, 5)
    }

    /// `Failure.isTerminal` reads straight through `SessionConnection
    /// .isTerminalRefusal` rather than reimplementing the classification —
    /// this is the test that the two can never quietly drift, pinned against
    /// the exact two examples spec §6 gives.
    func testFailureIsTerminalMatchesSessionConnectionsOwnClassification() {
        let leaseHeld = RemoteConnectCeremony.Failure(message: "in use by MacBook Pro", code: "lease_held")
        XCTAssertFalse(leaseHeld.isTerminal, "the transport keeps redialling on its own")

        let versionSkew = RemoteConnectCeremony.Failure(message: "update OmniAgent on Mac mini", code: "version_skew")
        XCTAssertTrue(versionSkew.isTerminal, "a human has to act before this can ever succeed")

        let noCode = RemoteConnectCeremony.Failure(message: "The PTY daemon connection closed.")
        XCTAssertFalse(noCode.isTerminal, "a plain socket error is not a refusal at all")
    }

    // MARK: - The overlay, verified by offscreen render

    func testTheOverlayCoversTheWholeWindowAndShowsTheMachineName() throws {
        let window = testWindow()
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        let view = mount(ceremony, in: window)

        XCTAssertEqual(view.frame, window.contentView?.bounds, "the glass covers the whole window")
        XCTAssertEqual(view.rowTextForTesting(.dialling), "Connecting to Mac Studio…")
        XCTAssertEqual(view.rowStateForTesting(.dialling), .active)
        XCTAssertEqual(view.rowStateForTesting(.securing), .pending)
    }

    /// Completed steps get a check, the current one is active, and nothing
    /// past it has started — the row states are read straight off
    /// `ceremony.step`, so a step that has not happened shows exactly that.
    func testCompletedStepsAreCheckedAndFutureStepsArePending() throws {
        let window = testWindow()
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        let view = mount(ceremony, in: window)

        ceremony.webSocketOpened()
        ceremony.dataChannelOpened()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.rowStateForTesting(.dialling), .done)
        XCTAssertEqual(view.rowStateForTesting(.securing), .done)
        XCTAssertEqual(view.rowStateForTesting(.confirming), .active)
        XCTAssertEqual(view.rowStateForTesting(.loading), .pending)
    }

    /// On `.done` every displayed row reads as checked — the "a green
    /// check" half of spec §6's "a green check, then fade out".
    func testEveryRowIsCheckedOnceDone() throws {
        let window = testWindow()
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        let view = mount(ceremony, in: window)

        ceremony.webSocketOpened()
        ceremony.dataChannelOpened()
        ceremony.helloAcknowledged()
        ceremony.environmentLoaded()
        view.layoutSubtreeIfNeeded()

        for step in ConnectStep.displayed {
            XCTAssertEqual(view.rowStateForTesting(step), .done, "\(step) should read done")
        }
    }

    /// A failure turns its own row red and shows the daemon's own message —
    /// never a generic one — with Try again and Cancel offered.
    func testAFailureTurnsItsRowFailedAndShowsTheDaemonsMessage() throws {
        let window = testWindow()
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        let view = mount(ceremony, in: window)

        ceremony.webSocketOpened()
        ceremony.dataChannelOpened()
        ceremony.failed(.init(message: "‹Mac Studio› is in use by MacBook Pro", code: "lease_held"))
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.rowStateForTesting(.confirming), .failed)
        XCTAssertEqual(view.failureMessageForTesting, "‹Mac Studio› is in use by MacBook Pro")
        XCTAssertTrue(view.areFailureButtonsShowingForTesting)
        XCTAssertTrue(
            view.isShowingRetryingCaptionForTesting,
            "a non-terminal refusal says what it is doing rather than presenting a dead end"
        )
    }

    /// The terminal case — version skew — shows no "Retrying…" caption,
    /// because nothing here is going to resolve on its own.
    func testATerminalFailureDoesNotClaimItIsRetrying() throws {
        let window = testWindow()
        let ceremony = RemoteConnectCeremony(machineName: "Mac mini")
        let view = mount(ceremony, in: window)

        ceremony.webSocketOpened()
        ceremony.dataChannelOpened()
        ceremony.failed(.init(message: "update OmniAgent on Mac mini", code: "version_skew"))
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.isShowingRetryingCaptionForTesting)
        XCTAssertTrue(view.areFailureButtonsShowingForTesting, "still offered — a human can update and try again")
    }

    /// Try again calls `onRetry`; it never fires with no failure showing —
    /// a card that has not failed has nothing to retry.
    func testTryAgainFiresOnlyAfterAFailure() throws {
        let window = testWindow()
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        let view = mount(ceremony, in: window)
        var retries = 0
        view.onRetry = { retries += 1 }

        view.pressTryAgainForTesting()
        XCTAssertEqual(retries, 0, "nothing has failed yet")

        ceremony.failed(.init(message: "x"))
        view.pressTryAgainForTesting()
        XCTAssertEqual(retries, 1)
    }

    /// Cancel fires exactly once — a second press (or Esc after a click)
    /// must not call the handler twice.
    func testCancelFiresExactlyOnce() throws {
        let window = testWindow()
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        let view = mount(ceremony, in: window)
        var cancels = 0
        view.onCancel = { cancels += 1 }

        view.pressCancelForTesting()
        view.pressCancelForTesting()
        XCTAssertEqual(cancels, 1)
    }

    /// `.done` takes the overlay down. With no window to animate a fade
    /// into (Reduce Motion's own code path, `RemoteConnectCeremonyOverlayView
    /// .animateOutOnDone`), the removal is synchronous — the deterministic
    /// half of "a green check, then fade out" to assert without a real
    /// screen or a wait for an animation.
    func testReachingDoneTakesTheOverlayDownWithNoWindowToAnimateIn() {
        let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
        let view = RemoteConnectCeremonyOverlayView(ceremony: ceremony)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        host.addSubview(view)
        XCTAssertNotNil(view.superview)

        ceremony.webSocketOpened()
        ceremony.dataChannelOpened()
        ceremony.helloAcknowledged()
        ceremony.environmentLoaded()

        XCTAssertNil(view.superview, "done takes itself down even with no window to fade through")
    }

    // MARK: - Helpers

    private func mount(_ ceremony: RemoteConnectCeremony, in window: NSWindow) -> RemoteConnectCeremonyOverlayView {
        let view = RemoteConnectCeremonyOverlayView(ceremony: ceremony)
        view.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Never ordered front — `RemoteSessionPickerTests.testWindow()`'s own
    /// reasoning: these are structural assertions, not a screenshot.
    private func testWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        return window
    }
}

import AppKit
import XCTest

@testable import OmniAgent

/// The "+ → Resume remote session…" picker — the remote-session-control
/// phase 2 spec's §4 ("The + menu picker",
/// docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md),
/// collapsed to a machine list by the 2026-09-01 remote environment sharing
/// spec §1 (Task 29): there is nothing below the machine to pick any more.
///
/// The rows are the whole contract and they are a pure function of the
/// relay's machine list, so they are asserted here rather than through the
/// sheet; the sheet's own tests are the two facts a list has to get right —
/// what Return opens, and that an offline row is not a thing you can open.
final class RemoteSessionPickerTests: XCTestCase {
    // MARK: - Rows

    /// One row per online machine, Connect-shaped.
    func testOneRowPerOnlineMachine() {
        let rows = RemoteSessionPickerModel.rows(
            machines: [
                RemoteMachine(deviceID: "d1", name: "Studio"),
                RemoteMachine(deviceID: "d2", name: "Air"),
            ],
            signedIn: true
        )
        XCTAssertEqual(
            rows,
            [.machine(deviceID: "d1", name: "Studio"), .machine(deviceID: "d2", name: "Air")]
        )
    }

    /// An empty picker says what is wrong, not "no results".
    func testEmptyStatesSayWhatIsWrong() {
        XCTAssertEqual(
            RemoteSessionPickerModel.rows(machines: [], signedIn: false),
            [.empty(message: "Signing in…")]
        )
        XCTAssertEqual(
            RemoteSessionPickerModel.rows(machines: [], signedIn: true),
            [.empty(message: "No other Macs are sharing")]
        )
    }

    /// A machine the relay knows about but does not currently report online
    /// is a plain "‹name› is offline" line — not connectable, and not the
    /// same as nothing being shared at all.
    func testAKnownOfflineMachineSaysSoInsteadOfDisappearing() {
        XCTAssertEqual(
            RemoteSessionPickerModel.rows(
                machines: [],
                offlineMachineNames: ["Mac Studio"],
                signedIn: true
            ),
            [.empty(message: "Mac Studio is offline")]
        )
    }

    /// Online machines are listed as connectable rows, offline ones after
    /// them as plain lines — never merged into one list a user cannot tell
    /// apart at a glance.
    func testOnlineMachinesComeBeforeOfflineOnes() {
        let rows = RemoteSessionPickerModel.rows(
            machines: [RemoteMachine(deviceID: "d1", name: "Studio")],
            offlineMachineNames: ["Air"],
            signedIn: true
        )
        XCTAssertEqual(
            rows,
            [.machine(deviceID: "d1", name: "Studio"), .empty(message: "Air is offline")]
        )
    }

    // MARK: - The sheet

    /// Return connects to the selected machine — the device id the row
    /// carries.
    func testReturnConnectsToTheSelectedMachine() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        var opened: [String] = []
        XCTAssertTrue(
            controller.present(
                over: window,
                rows: [
                    .machine(deviceID: "d1", name: "Studio"),
                    .machine(deviceID: "d2", name: "Air"),
                ]
            ) { deviceID in opened.append(deviceID) }
        )
        let view = try XCTUnwrap(controller.view)

        // The first openable row is selected on the way up, so Return alone
        // opens something: a picker that needs an arrow key first is a picker
        // that needs two keystrokes to do its one job.
        view.activateSelection()
        XCTAssertEqual(opened, ["d1"])
        XCTAssertNil(controller.view, "opening dismisses the sheet")

        controller.present(
            over: window,
            rows: [
                .machine(deviceID: "d1", name: "Studio"),
                .machine(deviceID: "d2", name: "Air"),
            ]
        ) { deviceID in opened.append(deviceID) }
        let second = try XCTUnwrap(controller.view)
        second.selectOpenableRow(at: 1)
        second.activateSelection()
        XCTAssertEqual(opened.last, "d2")
    }

    /// Escape dismisses and opens nothing.
    func testEscapeDismissesWithoutOpeningAnything() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        var opened = 0
        controller.present(
            over: window,
            rows: [.machine(deviceID: "d1", name: "Studio")]
        ) { _ in opened += 1 }
        let view = try XCTUnwrap(controller.view)

        view.cancel()
        XCTAssertEqual(opened, 0)
        XCTAssertNil(controller.view)
        XCTAssertNil(view.superview, "the sheet comes off the window, not just out of the controller")
    }

    /// An offline row is not selectable: arrow keys and clicks pass over it,
    /// so nothing can be "opened" that is not an online machine.
    func testOfflineRowsAreNotSelectable() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        controller.present(
            over: window,
            rows: [
                .machine(deviceID: "d1", name: "Studio"),
                .empty(message: "Air is offline"),
            ]
        ) { _ in }
        let view = try XCTUnwrap(controller.view)

        XCTAssertEqual(view.openableRowIndexes, [0])
        XCTAssertFalse(view.canSelectRow(1), "an offline row is not a thing you can open")
    }

    /// Nothing to open: the sheet still goes up, says why in plain words, and
    /// Return closes it rather than beeping at a list with no answer in it.
    func testTheEmptySheetStillPresentsAndReturnJustCloses() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        var opened = 0
        controller.present(
            over: window,
            rows: RemoteSessionPickerModel.rows(machines: [], signedIn: true)
        ) { _ in opened += 1 }
        let view = try XCTUnwrap(controller.view)

        XCTAssertTrue(view.openableRowIndexes.isEmpty)
        view.activateSelection()
        XCTAssertEqual(opened, 0)
        XCTAssertNil(controller.view, "Return on a picker with nothing in it closes it")
    }

    /// Return with a list that has machines in it but nothing selected — the
    /// click that landed under the last row — beeps and stays up, rather
    /// than closing the picker the user is still choosing from.
    func testReturnWithNothingSelectedKeepsTheSheetUp() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        var opened = 0
        controller.present(
            over: window,
            rows: [.machine(deviceID: "d1", name: "Studio")]
        ) { _ in opened += 1 }
        let view = try XCTUnwrap(controller.view)

        view.clearSelectionForTesting()
        view.activateSelection()
        XCTAssertEqual(opened, 0)
        XCTAssertNotNil(controller.view, "still choosing is not the same as nothing to choose")
    }

    /// One sheet at a time — a second request while one is up is dropped
    /// rather than stacking two sets of glass over the window.
    func testASecondPresentWhileOneIsUpIsDropped() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        XCTAssertTrue(controller.present(over: window, rows: [.empty(message: "Signing in…")]) { _ in })
        let first = try XCTUnwrap(controller.view)
        XCTAssertFalse(controller.present(over: window, rows: [.empty(message: "Signing in…")]) { _ in })
        XCTAssertTrue(controller.view === first)
    }

    /// No window, no sheet — and the caller is told, so a menu item can fall
    /// back rather than silently doing nothing.
    func testPresentWithoutAWindowReportsFailure() {
        let controller = RemoteSessionPickerController()
        XCTAssertFalse(controller.present(over: nil, rows: [.empty(message: "Signing in…")]) { _ in })
        XCTAssertNil(controller.view)
    }

    /// The card actually lays out: a sheet that failed to would paint one
    /// flat colour, and every one of its parts would be at the origin.
    /// Cheaper and steadier than a snapshot, and it catches the failure mode
    /// that matters — a modal that goes up as an invisible or zero-sized
    /// card, which no assertion about rows would notice.
    func testTheCardLaysItselfOutOverTheWindow() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        controller.present(
            over: window,
            rows: [.machine(deviceID: "d1", name: "Studio")]
        ) { _ in }
        let view = try XCTUnwrap(controller.view)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.frame, window.contentView?.bounds, "the glass covers the window")
        let card = view.cardFrameForTesting
        // The card is shorter than the old machine/workspace/session tree
        // ever was — there is only a title, a message and a one-row list —
        // so the height floor is lower than the width's.
        XCTAssertGreaterThan(card.width, 250)
        XCTAssertGreaterThan(card.height, 200)
        XCTAssertTrue(view.bounds.contains(card), "the card fits inside the window it is mounted over")
        XCTAssertEqual(card.midX, view.bounds.midX, accuracy: 1, "centred")
        XCTAssertEqual(card.midY, view.bounds.midY, accuracy: 1)
    }

    // MARK: - Fixtures

    /// A window to mount the sheet in. Never ordered front: these are
    /// structural assertions, and a test that steals the screen is a test
    /// nobody runs twice.
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

import AppKit
import XCTest

@testable import OmniAgent

/// The "+ → Resume remote session…" picker — the remote-session-control
/// phase 2 spec's §4 ("The + menu picker",
/// docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md).
///
/// The rows are the whole contract and they are a pure function of the
/// relay's machine list, so they are asserted here rather than through the
/// sheet; the sheet's own tests are the two facts a list has to get right —
/// what Return opens, and that a heading is not a thing you can open.
final class RemoteSessionPickerTests: XCTestCase {
    // MARK: - Rows

    /// One section per machine, then its workspaces, then the terminal panes
    /// inside each session — the host's tree, in the host's order.
    func testRowsMirrorTheHostTreeUnderEachMachine() {
        let rows = RemoteSessionPickerModel.rows(machines: [studioWithTwoSessions()], signedIn: true)
        XCTAssertEqual(rows.first, .machine(deviceID: "d1", name: "Studio"))
        XCTAssertEqual(rows.compactMap { if case let .session(_, paneID, label, _) = $0 { return "\(paneID):\(label)" } else { return nil } },
                       ["s1:Session 1", "s3:Session 2"])
    }

    /// An empty picker says what is wrong, not "no results".
    func testEmptyStatesSayWhatIsWrong() {
        XCTAssertEqual(RemoteSessionPickerModel.rows(machines: [], signedIn: false),
                       [.empty(message: "Signing in…")])
        XCTAssertEqual(RemoteSessionPickerModel.rows(machines: [], signedIn: true),
                       [.empty(message: "No other Macs are sharing sessions")])
    }

    /// The workspace headings come from the projection too, and the whole
    /// list is the projection's `order` — never re-sorted here, which is the
    /// drift schema v2 exists to prevent.
    func testWorkspaceHeadingsAndTheHostsOrderSurvive() {
        let machine = RemoteMachine(
            deviceID: "d1",
            name: "Studio",
            projection: RemoteControlProjection.Payload(workspaces: [
                workspace(
                    id: "/b",
                    name: "Beta",
                    order: 1,
                    sessions: [session(id: "g9", label: "Later", order: 0, panes: [pane(id: "p9", title: "Shell")])]
                ),
                workspace(
                    id: "/a",
                    name: "Alpha",
                    order: 0,
                    sessions: [
                        session(id: "g2", label: "Second", order: 1, panes: [pane(id: "p2", title: "Two")]),
                        session(id: "g1", label: "First", order: 0, panes: [pane(id: "p1", title: "One")]),
                    ]
                ),
            ])
        )

        XCTAssertEqual(
            RemoteSessionPickerModel.rows(machines: [machine], signedIn: true).map(describe),
            [
                "machine:Studio",
                "workspace:Alpha",
                "session:p1",
                "session:p2",
                "workspace:Beta",
                "session:p9",
            ],
            "the projection's order is the answer; the picker never sorts it again"
        )
    }

    /// Only a terminal pane can be attached to (spec §2), so only a terminal
    /// pane is offered — the others are the host's tree, not this Mac's.
    func testOnlyTerminalPanesAreOffered() {
        let machine = RemoteMachine(
            deviceID: "d1",
            name: "Studio",
            projection: RemoteControlProjection.Payload(workspaces: [
                workspace(
                    id: "/a",
                    name: "Alpha",
                    order: 0,
                    sessions: [
                        session(
                            id: "g1",
                            label: "Session 1",
                            order: 0,
                            panes: [
                                pane(id: "p1", title: "Session 1"),
                                pane(id: "p2", title: "PaneAsk.swift", kind: "editor", order: 1),
                                pane(id: "p3", title: "localhost", kind: "browser", order: 2),
                            ]
                        )
                    ]
                )
            ])
        )

        XCTAssertEqual(
            RemoteSessionPickerModel.rows(machines: [machine], signedIn: true).map(describe),
            ["machine:Studio", "workspace:Alpha", "session:p1"]
        )
    }

    /// The detail line says where the pane lives when its own name does not:
    /// the session it belongs to, then the engine. A one-pane session whose
    /// pane is named after it does not say it twice.
    func testDetailNamesTheSessionOnlyWhenThePaneDoesNot() {
        let machine = RemoteMachine(
            deviceID: "d1",
            name: "Studio",
            projection: RemoteControlProjection.Payload(workspaces: [
                workspace(
                    id: "/a",
                    name: "Alpha",
                    order: 0,
                    sessions: [
                        session(
                            id: "g1",
                            label: "Session 1",
                            order: 0,
                            panes: [
                                pane(id: "p1", title: "Session 1", engine: "claude"),
                                pane(id: "p2", title: "Tests", engine: "shell", order: 1),
                            ]
                        )
                    ]
                )
            ])
        )

        XCTAssertEqual(
            RemoteSessionPickerModel.rows(machines: [machine], signedIn: true).compactMap { row in
                guard case let .session(_, _, _, detail) = row else { return nil as String? }
                return detail
            },
            ["Claude", "Session 1 · Shell"]
        )
    }

    /// A machine whose projection lists no workspace at all has no tunnel —
    /// the daemon holds its control channel open only while ≥ 1 workspace is
    /// shared — so the row says so instead of leaving a blank section.
    func testAMachineSharingNothingSaysSoInsteadOfShowingABlankSection() {
        let machine = RemoteMachine(
            deviceID: "d1",
            name: "Studio",
            projection: RemoteControlProjection.Payload(workspaces: [])
        )

        XCTAssertEqual(
            RemoteSessionPickerModel.rows(machines: [machine], signedIn: true),
            [.machine(deviceID: "d1", name: "Studio"), .empty(message: "Studio is offline")]
        )
    }

    /// A shared workspace with nothing running is still listed — that is the
    /// host's tree — but it says why it has no rows under it.
    func testAWorkspaceWithNothingRunningSaysSo() {
        let machine = RemoteMachine(
            deviceID: "d1",
            name: "Studio",
            projection: RemoteControlProjection.Payload(workspaces: [
                workspace(id: "/a", name: "Alpha", order: 0, sessions: [])
            ])
        )

        XCTAssertEqual(
            RemoteSessionPickerModel.rows(machines: [machine], signedIn: true),
            [
                .machine(deviceID: "d1", name: "Studio"),
                .workspace(name: "Alpha"),
                .empty(message: "Nothing is running in Alpha"),
            ]
        )
    }

    /// Two machines, each with its own section — no interleaving, no merged
    /// workspaces.
    func testEveryMachineGetsItsOwnSection() {
        let rows = RemoteSessionPickerModel.rows(
            machines: [
                studioWithTwoSessions(),
                RemoteMachine(
                    deviceID: "d2",
                    name: "Air",
                    projection: RemoteControlProjection.Payload(workspaces: [
                        workspace(
                            id: "/a",
                            name: "Alpha",
                            order: 0,
                            sessions: [session(id: "g1", label: "Only", order: 0, panes: [pane(id: "a1", title: "Only")])]
                        )
                    ])
                ),
            ],
            signedIn: true
        )

        XCTAssertEqual(
            rows.compactMap { row -> String? in
                guard case let .machine(_, name) = row else { return nil }
                return name
            },
            ["Studio", "Air"]
        )
        XCTAssertEqual(
            rows.compactMap { row -> String? in
                guard case let .session(deviceID, paneID, _, _) = row else { return nil }
                return "\(deviceID)/\(paneID)"
            },
            ["d1/s1", "d1/s3", "d2/a1"]
        )
    }

    // MARK: - The sheet

    /// Return opens the selected session with the ids the row carries — the
    /// pane id, which is the only thing a viewer may attach to.
    func testReturnOpensTheSelectedSession() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        var opened: [String] = []
        XCTAssertTrue(
            controller.present(
                over: window,
                rows: RemoteSessionPickerModel.rows(machines: [studioWithTwoSessions()], signedIn: true)
            ) { deviceID, paneID, title in
                opened.append("\(deviceID)/\(paneID)/\(title)")
            }
        )
        let view = try XCTUnwrap(controller.view)

        // The first openable row is selected on the way up, so Return alone
        // opens something: a picker that needs an arrow key first is a picker
        // that needs two keystrokes to do its one job.
        view.activateSelection()
        XCTAssertEqual(opened, ["d1/s1/Session 1"])
        XCTAssertNil(controller.view, "opening dismisses the sheet")

        controller.present(over: window, rows: RemoteSessionPickerModel.rows(machines: [studioWithTwoSessions()], signedIn: true)) { deviceID, paneID, title in
            opened.append("\(deviceID)/\(paneID)/\(title)")
        }
        let second = try XCTUnwrap(controller.view)
        second.selectOpenableRow(at: 1)
        second.activateSelection()
        XCTAssertEqual(opened.last, "d1/s3/Session 2")
    }

    /// Escape dismisses and opens nothing.
    func testEscapeDismissesWithoutOpeningAnything() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        var opened = 0
        controller.present(
            over: window,
            rows: RemoteSessionPickerModel.rows(machines: [studioWithTwoSessions()], signedIn: true)
        ) { _, _, _ in opened += 1 }
        let view = try XCTUnwrap(controller.view)

        view.cancel()
        XCTAssertEqual(opened, 0)
        XCTAssertNil(controller.view)
        XCTAssertNil(view.superview, "the sheet comes off the window, not just out of the controller")
    }

    /// A heading is a heading: arrow keys and clicks pass over machine,
    /// workspace and empty rows, so nothing can be "opened" that is not a
    /// session.
    func testHeadingsAndEmptyRowsAreNotSelectable() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        controller.present(
            over: window,
            rows: RemoteSessionPickerModel.rows(machines: [studioWithTwoSessions()], signedIn: true)
        ) { _, _, _ in }
        let view = try XCTUnwrap(controller.view)

        // machine, workspace, then the two terminal panes — the editor pane
        // is not a row at all.
        XCTAssertEqual(view.openableRowIndexes, [2, 3])
        for index in 0..<view.numberOfRowsForTesting where !view.openableRowIndexes.contains(index) {
            XCTAssertFalse(view.canSelectRow(index), "row \(index) is a heading, not a session")
        }
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
        ) { _, _, _ in opened += 1 }
        let view = try XCTUnwrap(controller.view)

        XCTAssertTrue(view.openableRowIndexes.isEmpty)
        view.activateSelection()
        XCTAssertEqual(opened, 0)
        XCTAssertNil(controller.view, "Return on a picker with nothing in it closes it")
    }

    /// One sheet at a time — a second request while one is up is dropped
    /// rather than stacking two sets of glass over the window.
    func testASecondPresentWhileOneIsUpIsDropped() throws {
        let window = testWindow()
        let controller = RemoteSessionPickerController()
        XCTAssertTrue(controller.present(over: window, rows: [.empty(message: "Signing in…")]) { _, _, _ in })
        let first = try XCTUnwrap(controller.view)
        XCTAssertFalse(controller.present(over: window, rows: [.empty(message: "Signing in…")]) { _, _, _ in })
        XCTAssertTrue(controller.view === first)
    }

    /// No window, no sheet — and the caller is told, so a menu item can fall
    /// back rather than silently doing nothing.
    func testPresentWithoutAWindowReportsFailure() {
        let controller = RemoteSessionPickerController()
        XCTAssertFalse(controller.present(over: nil, rows: [.empty(message: "Signing in…")]) { _, _, _ in })
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
            rows: RemoteSessionPickerModel.rows(machines: [studioWithTwoSessions()], signedIn: true)
        ) { _, _, _ in }
        let view = try XCTUnwrap(controller.view)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.frame, window.contentView?.bounds, "the glass covers the window")
        let card = view.cardFrameForTesting
        XCTAssertGreaterThan(card.width, 300)
        XCTAssertGreaterThan(card.height, 300)
        XCTAssertTrue(view.bounds.contains(card), "the card fits inside the window it is mounted over")
        XCTAssertEqual(card.midX, view.bounds.midX, accuracy: 1, "centred")
        XCTAssertEqual(card.midY, view.bounds.midY, accuracy: 1)
    }

    // MARK: - Fixtures

    /// One machine, one workspace, two sessions — the second of which has an
    /// editor pane beside its terminal, so the "terminals only" rule is
    /// exercised by the same fixture the tree test uses.
    private func studioWithTwoSessions() -> RemoteMachine {
        RemoteMachine(
            deviceID: "d1",
            name: "Studio",
            projection: RemoteControlProjection.Payload(workspaces: [
                workspace(
                    id: "/Users/bruno/OmniAgent-ADE",
                    name: "OmniAgent-ADE",
                    order: 0,
                    sessions: [
                        session(
                            id: "g1",
                            label: "Session 1",
                            order: 0,
                            panes: [
                                pane(id: "s1", title: "Session 1", engine: "claude"),
                                pane(id: "s2", title: "PaneAsk.swift", kind: "editor", order: 1),
                            ]
                        ),
                        session(
                            id: "g2",
                            label: "Session 2",
                            order: 1,
                            panes: [pane(id: "s3", title: "Session 2", engine: "codex")]
                        ),
                    ]
                )
            ])
        )
    }

    private func workspace(
        id: String,
        name: String,
        order: Int,
        sessions: [RemoteControlProjection.Session]
    ) -> RemoteControlProjection.Workspace {
        RemoteControlProjection.Workspace(id: id, name: name, tint: nil, order: order, sessions: sessions)
    }

    private func session(
        id: String,
        label: String,
        order: Int,
        panes: [RemoteControlProjection.Pane]
    ) -> RemoteControlProjection.Session {
        RemoteControlProjection.Session(id: id, label: label, order: order, panes: panes)
    }

    private func pane(
        id: String,
        title: String,
        engine: String = "claude",
        kind: String = "terminal",
        order: Int = 0
    ) -> RemoteControlProjection.Pane {
        RemoteControlProjection.Pane(id: id, title: title, engine: engine, kind: kind, order: order)
    }

    private func describe(_ row: RemoteSessionPickerModel.Row) -> String {
        switch row {
        case let .machine(_, name): return "machine:\(name)"
        case let .workspace(name): return "workspace:\(name)"
        case let .session(_, paneID, _, _): return "session:\(paneID)"
        case let .empty(message): return "empty:\(message)"
        }
    }

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

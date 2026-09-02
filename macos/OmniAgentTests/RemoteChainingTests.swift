import XCTest
@testable import OmniAgent

/// No chaining in the UI (2026-09-01 remote environment sharing spec §3,
/// Task 25): **Connect to ‹machine›** is disabled in the picker, the plus
/// menu and the palette for the entire time this Mac is already driving one.
///
/// Belt-and-braces, not the guarantee itself — see `RemoteSessionPicker`'s
/// own doc comment: `remote_chaining.rs` is what actually makes a chained
/// connection impossible. These tests are about the UI never offering the
/// click in the first place.
@MainActor
final class RemoteChainingTests: XCTestCase {
    func testConnectIsDisabledEverywhereWhileASessionIsLive() throws {
        let model = RemoteSharingModel.fixture(
            activeRemoteSession: RemoteSessionInfo(machineName: "Mac Studio", since: .now)
        )

        XCTAssertFalse(RemoteSessionPicker.canConnect(model: model))
        XCTAssertEqual(
            RemoteSessionPicker.disabledReason(model: model),
            "End the session with Mac Studio first"
        )

        let rows = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil,
            remoteMachines: [PaletteRemoteMachine(deviceID: "d1", name: "Mac Studio", workspaces: [])],
            activeRemoteSession: model.activeRemoteSession
        )
        let connect = try XCTUnwrap(rows.first { $0.title.hasPrefix("Connect to") })
        XCTAssertEqual(connect.isEnabled, false)
        XCTAssertTrue(rows.map(\.title).contains("End remote session"))
    }

    /// The opposite of the test above: nothing is disabled and there is no
    /// End row while nobody is being driven — `canConnect`/`disabledReason`
    /// must not be permanently pessimistic.
    func testConnectIsEnabledAndThereIsNoEndRowWhileIdle() throws {
        let model = RemoteSharingModel.fixture()
        XCTAssertTrue(RemoteSessionPicker.canConnect(model: model))
        XCTAssertNil(RemoteSessionPicker.disabledReason(model: model))

        let rows = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil,
            remoteMachines: [PaletteRemoteMachine(deviceID: "d1", name: "Mac Studio", workspaces: [])]
        )
        let connect = try XCTUnwrap(rows.first { $0.title.hasPrefix("Connect to") })
        XCTAssertEqual(connect.isEnabled, true)
        XCTAssertFalse(rows.map(\.title).contains("End remote session"))
    }

    /// The disabled row's subtitle carries the reason — spec §3's own
    /// wording ("with the reason as the disabled subtitle").
    func testTheDisabledRowsSubtitleIsTheReason() throws {
        let rows = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil,
            remoteMachines: [PaletteRemoteMachine(deviceID: "d1", name: "Mac Studio", workspaces: [])],
            activeRemoteSession: RemoteSessionInfo(machineName: "Mac Studio", since: .now)
        )
        let connect = try XCTUnwrap(rows.first { $0.title.hasPrefix("Connect to") })
        XCTAssertEqual(connect.subtitle, "End the session with Mac Studio first")
    }

    /// "Connect to ‹machine›" exists once per online machine, whether or not
    /// a session is live — the row is findable either way, only the *click*
    /// is what a live session takes away.
    func testOneConnectRowPerOnlineMachine() {
        let rows = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil,
            remoteMachines: [
                PaletteRemoteMachine(deviceID: "d1", name: "Mac Studio", workspaces: []),
                PaletteRemoteMachine(deviceID: "d2", name: "MacBook Air", workspaces: []),
            ]
        )
        let titles = rows.filter { $0.title.hasPrefix("Connect to") }.map(\.title)
        XCTAssertEqual(Set(titles), ["Connect to Mac Studio", "Connect to MacBook Air"])
    }

    /// The plus menu's "Resume remote session…" — a different feature
    /// (opening one shared pane rather than driving the whole machine), but
    /// gated the same way: this Mac's own local connection is gone for the
    /// whole of a takeover, so there would be nothing for the picker to
    /// read even if the click reached it.
    func testThePlusMenusResumeItemCarriesTheSameGate() throws {
        let live = WorkspacesHeaderMenus.plus(
            workspaces: [],
            startSession: { _ in },
            addLocalFolder: {},
            resumeRemoteSession: nil,
            remoteSessionDisabledReason: "End the session with Mac Studio first"
        )
        let item = try XCTUnwrap(live.items.first { $0.title == "Resume remote session…" })
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.toolTip, "End the session with Mac Studio first")

        let idle = WorkspacesHeaderMenus.plus(
            workspaces: [],
            startSession: { _ in },
            addLocalFolder: {},
            resumeRemoteSession: {}
        )
        let idleItem = try XCTUnwrap(idle.items.first { $0.title == "Resume remote session…" })
        XCTAssertTrue(idleItem.isEnabled)
    }

    /// `NavigationSidebarView.makePlusMenu()` reads its own `canResumeRemoteSession`
    /// / `remoteSessionDisabledReason` rather than deciding on its own —
    /// `WorkspaceWindowController.applyActiveRemoteSession` is what sets
    /// them, off the same `RemoteSharingModel.activeRemoteSession` the other
    /// two surfaces read.
    func testTheSidebarsPlusMenuHonoursItsOwnGate() throws {
        let sidebar = NavigationSidebarView()
        sidebar.canResumeRemoteSession = false
        sidebar.remoteSessionDisabledReason = "End the session with Mac Studio first"
        let menu = sidebar.makePlusMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == "Resume remote session…" })
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.toolTip, "End the session with Mac Studio first")
    }
}

/// A `RemoteSharingModel` with no daemon behind it — the fixture the brief's
/// own test constructs. Reads and writes through it would just fail closed
/// (`FakeSettingsClient()`'s empty rows); nothing in `RemoteChainingTests`
/// exercises those, only `activeRemoteSession`.
extension RemoteSharingModel {
    static func fixture(activeRemoteSession: RemoteSessionInfo? = nil) -> RemoteSharingModel {
        let model = RemoteSharingModel(store: SettingsStore(client: FakeSettingsClient()))
        if let activeRemoteSession {
            model.beganDriving(activeRemoteSession.machineName, since: activeRemoteSession.since)
        }
        return model
    }
}

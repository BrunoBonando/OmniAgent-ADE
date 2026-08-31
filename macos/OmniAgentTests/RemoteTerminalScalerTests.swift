import AppKit
import XCTest
@testable import OmniAgent

/// The viewer's half of phase 2 §1: the grid belongs to the host, so a remote
/// pane never resizes it and draws all of it, scaled into the space it has.
final class RemoteTerminalScalerTests: XCTestCase {
    func testTheWholeHostScreenFitsAndIsCentred() {
        let fit = RemoteTerminalScaler.fit(hostCols: 200, hostRows: 50,
                                           cell: CGSize(width: 8, height: 18),
                                           pane: CGSize(width: 800, height: 900), zoom: 0)
        XCTAssertEqual(fit.terminalSize, CGSize(width: 1600, height: 900), "the grid keeps its true size")
        XCTAssertEqual(fit.scale, 0.5, accuracy: 0.001, "width is the binding constraint")
        XCTAssertEqual(fit.origin.y, 0, accuracy: 0.001, "…so it fills the height exactly")
        XCTAssertEqual(fit.origin.x, 0, accuracy: 0.001)
    }

    func testASmallerHostIsNotBlownUp() {
        let fit = RemoteTerminalScaler.fit(hostCols: 80, hostRows: 24,
                                           cell: CGSize(width: 8, height: 18),
                                           pane: CGSize(width: 1600, height: 900), zoom: 0)
        XCTAssertEqual(fit.scale, 1, "fit never magnifies; the host's screen is drawn 1:1 and centred")
        XCTAssertEqual(fit.origin.x, 480, accuracy: 0.001)
    }

    func testZoomOverridesFitAndIsClamped() {
        let cell = CGSize(width: 8, height: 18), pane = CGSize(width: 800, height: 900)
        XCTAssertEqual(RemoteTerminalScaler.fit(hostCols: 200, hostRows: 50, cell: cell, pane: pane, zoom: 1).scale, 1)
        XCTAssertEqual(RemoteTerminalScaler.fit(hostCols: 200, hostRows: 50, cell: cell, pane: pane, zoom: 9).scale, 2)
        XCTAssertEqual(RemoteTerminalScaler.fit(hostCols: 200, hostRows: 50, cell: cell, pane: pane, zoom: 0.01).scale, 0.25)
    }

    func testADegenerateGridIsSafe() {
        let fit = RemoteTerminalScaler.fit(hostCols: 0, hostRows: 0, cell: .zero,
                                           pane: CGSize(width: 800, height: 900), zoom: 0)
        XCTAssertEqual(fit.scale, 1)
        XCTAssertEqual(fit.terminalSize, CGSize(width: 800, height: 900), "never divide by zero")
    }

    /// ⌘+ from a fit steps off the scale on screen, not off `zoom`'s own 0:
    /// multiplying "fit" by 1.25 would leave it at 0 (fit) forever.
    func testZoomStepsOffWhateverIsOnScreen() {
        var scaler = RemoteTerminalScaler()
        scaler.stepZoom(by: 1.25, from: 0.5)
        XCTAssertEqual(scaler.zoom, 0.625, accuracy: 0.001, "the first ⌘+ leaves the fit behind")
        scaler.stepZoom(by: 1.25, from: 0.5)
        XCTAssertEqual(scaler.zoom, 0.78125, accuracy: 0.001, "the second compounds the first, not the fit")
        for _ in 0..<10 { scaler.stepZoom(by: 1.25, from: 0.5) }
        XCTAssertEqual(scaler.zoom, 2, "clamped at the ceiling")
        for _ in 0..<20 { scaler.stepZoom(by: 1 / 1.25, from: 0.5) }
        XCTAssertEqual(scaler.zoom, 0.25, "and at the floor")
    }

    // MARK: The view

    /// The whole point of the scaler, on a real `TerminalSurfaceView`: the
    /// terminal is pinned to the *host's* grid whatever size the pane is, and
    /// nothing is ever sent back to the host to say so.
    @MainActor
    func testARemotePanePinsItsTerminalToTheHostGrid() throws {
        let surface = TerminalSurfaceView(connection: Self.remoteConnection(), sessionID: "s1")
        surface.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        surface.remoteGrid = (cols: 180, rows: 46)

        XCTAssertEqual(surface.terminalView.terminal.cols, 180, "the host's columns, not the pane's")
        XCTAssertEqual(surface.terminalView.terminal.rows, 46)
        XCTAssertEqual(surface.resizeSendCount, 0, "a viewer never resizes the shared PTY")
        let scale = try XCTUnwrap(surface.remoteFit).scale
        XCTAssertLessThan(scale, 1, "a 180-column grid does not fit a 400-point pane at 1:1")
        XCTAssertEqual(surface.terminalView.metalScaleFactorOverride ?? 0, scale * 2, accuracy: 0.001,
                       "glyphs rasterize at the scale they are shown at")

        // The scale is AppKit's own, not a layer transform: it is in the
        // coordinate system, so this conversion — the same one every mouse
        // event goes through — sees it, and the whole grid lands inside the
        // pane, letterboxed in the middle of what the fit left over.
        let onScreen = surface.terminalView.convert(surface.terminalView.bounds, to: surface)
        XCTAssertEqual(onScreen.width, surface.terminalView.bounds.width * scale, accuracy: 0.5)
        XCTAssertLessThanOrEqual(onScreen.maxX, surface.bounds.maxX + 0.5, "inside the pane")
        XCTAssertLessThanOrEqual(onScreen.maxY, surface.bounds.maxY + 0.5)
        XCTAssertEqual(onScreen.midY, surface.bounds.midY, accuracy: 0.5, "centred vertically")
    }

    /// The invariant a reviewer checks hardest: none of this touches a local
    /// pane, which still fills its bounds with its own grid and still sends it.
    @MainActor
    func testALocalPaneIsUntouched() {
        let connection = SessionConnection(socketURL: URL(fileURLWithPath: "/tmp/omniagent-scaler-test.sock"))
        let surface = TerminalSurfaceView(connection: connection, sessionID: "s1")
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600)

        XCTAssertEqual(surface.terminalView.frame, surface.bounds, "the terminal still fills the pane")
        XCTAssertNil(surface.remoteFit, "no scaling for a local pane")
        XCTAssertNil(surface.terminalView.metalScaleFactorOverride)
        // Sizing the pane resized its grid, which SwiftTerm reported straight
        // back — the send the remote pane above deliberately does not make.
        XCTAssertGreaterThan(surface.resizeSendCount, 0)
        let sent = surface.resizeSendCount
        surface.syncSize()
        XCTAssertEqual(surface.resizeSendCount, sent + 1, "a local pane still tells its PTY what size it is")
        // A stray `SessionResized` for a local session changes nothing: the
        // local view drives the size (task 5 — the daemon pushes it to local
        // connections too).
        surface.remoteGrid = (cols: 42, rows: 12)
        XCTAssertEqual(surface.terminalView.frame, surface.bounds)
    }

    /// A `SessionResized` for another pane's session id is not this pane's grid.
    @MainActor
    func testTheHostGridArrivesThroughTheConnectionForItsOwnSessionOnly() {
        let connection = Self.remoteConnection()
        let mine = TerminalSurfaceView(connection: connection, sessionID: "s1")
        let other = TerminalSurfaceView(connection: connection, sessionID: "s2")
        for surface in [mine, other] { surface.frame = CGRect(x: 0, y: 0, width: 400, height: 300) }

        connection.onSessionSize?("s2", 100, 30)

        XCTAssertNil(mine.remoteGrid, "another session's size is not this pane's")
        XCTAssertEqual(other.terminalView.terminal.cols, 100, "…and its own is, on the same connection")
        XCTAssertEqual(other.terminalView.terminal.rows, 30)
    }

    /// Zoom is a remote-pane verb; on a local pane the menu items are dead.
    @MainActor
    func testZoomItemsAreDisabledOnALocalPane() {
        let local = TerminalSurfaceView(
            connection: SessionConnection(socketURL: URL(fileURLWithPath: "/tmp/omniagent-scaler-test.sock")),
            sessionID: "s1"
        )
        let remote = TerminalSurfaceView(connection: Self.remoteConnection(), sessionID: "s1")
        let item = NSMenuItem(
            title: "Zoom In",
            action: #selector(TerminalSurfaceView.zoomInRemoteTerminal(_:)),
            keyEquivalent: "+"
        )
        XCTAssertFalse(local.validateMenuItem(item))
        XCTAssertTrue(remote.validateMenuItem(item))
    }

    /// ⌘+ / ⌘− magnify past the fit and ⌘0 returns to it, without ever
    /// changing the grid the host owns.
    @MainActor
    func testZoomingARemotePaneNeverChangesTheGrid() throws {
        let surface = TerminalSurfaceView(connection: Self.remoteConnection(), sessionID: "s1")
        surface.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        surface.remoteGrid = (cols: 180, rows: 46)
        let fitted = try XCTUnwrap(surface.remoteFit).scale

        surface.zoomInRemoteTerminal(nil)
        let zoomed = try XCTUnwrap(surface.remoteFit).scale
        XCTAssertGreaterThan(zoomed, fitted)
        XCTAssertEqual(surface.terminalView.terminal.cols, 180, "zoom is not a resize")

        surface.resetRemoteTerminalZoom(nil)
        XCTAssertEqual(try XCTUnwrap(surface.remoteFit).scale, fitted, accuracy: 0.0001,
                       "⌘0 is back to the fit")
        XCTAssertEqual(surface.resizeSendCount, 0)
    }

    /// A `SessionConnection` over the relay transport, pointed at a port
    /// nothing listens on — `isRemote` is what this suite needs from it, and
    /// nothing here ever connects (`RemotePanesTests` does the same).
    private static func remoteConnection() -> SessionConnection {
        SessionConnection(
            transport: .webSocket(URL(string: "ws://127.0.0.1:1/v1/viewer/d1")!, bearer: { nil }),
            reconnectDelay: 600
        )
    }
}

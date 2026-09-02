import AppKit
import XCTest
@testable import OmniAgent

/// Whoever drives owns the grid (2026-09-01 remote environment sharing spec
/// §5, §1) — the exact inversion of the phase-2 rule this replaces. While a
/// remote connection is driving THIS machine, the host app must not send
/// `Resize`; the viewer sends it normally, so terminals reflow at the remote
/// computer's real resolution; and on disconnect the host reclaims the grid
/// by re-sending its size for every visible pane.
final class GridOwnershipTests: XCTestCase {
    func testTheViewerResizesAndTheSharedHostDoesNot() {
        let viewer = TerminalSurfaceView.fixture(isDrivingRemote: true, sharingIsLive: false)
        viewer.flushResize()
        XCTAssertNotNil(viewer.sentResize)

        let host = TerminalSurfaceView.fixture(isDrivingRemote: false, sharingIsLive: true)
        host.flushResize()
        XCTAssertNil(host.sentResize)
    }

    func testTheHostReclaimsTheGridWhenTheSessionEnds() {
        let host = TerminalSurfaceView.fixture(isDrivingRemote: false, sharingIsLive: true)
        host.flushResize()
        XCTAssertNil(host.sentResize)

        host.sharingWentIdle()
        XCTAssertNotNil(host.sentResize)
    }

    /// The other half of `sharingWentIdle()`'s contract: it also turns the
    /// gate back off, so a *second* resize (a window drag right after
    /// reconnecting, say) is not suppressed by a flag nobody reset.
    func testSharingWentIdleAlsoClearsTheGateItself() {
        let host = TerminalSurfaceView.fixture(isDrivingRemote: false, sharingIsLive: true)
        host.sharingWentIdle()
        XCTAssertFalse(host.sharingIsLive)
    }

    /// A pane built while a viewer is already driving must start suppressed
    /// — `WorkspaceWindowController`'s pane factory sets `sharingIsLive`
    /// itself rather than relying on a later `syncTakeoverPanel` pass, which
    /// only ever touches the panes that existed at the moment sharing began.
    /// Pinned here at the property's own default: a fresh surface always
    /// starts with the grid it would own if nobody set anything.
    func testASurfaceStartsAbleToResizeUntilToldOtherwise() {
        let surface = TerminalSurfaceView.fixture(isDrivingRemote: false, sharingIsLive: false)
        XCTAssertFalse(surface.sharingIsLive)
    }
}

extension TerminalSurfaceView {
    /// `isDrivingRemote` picks which kind of connection backs the surface —
    /// a viewer's own pane is genuinely remote-transported, a host's pane is
    /// genuinely local — so the fixture is representative of what
    /// `WorkspaceWindowController`'s pane factory actually builds in each
    /// role. `sharingIsLive` is the one flag `flushResize()` actually gates
    /// on; a fresh `SessionConnection` never dials anything (`connect()` is
    /// never called), so neither transport touches a real socket.
    static func fixture(isDrivingRemote: Bool, sharingIsLive: Bool) -> TerminalSurfaceView {
        let connection: SessionConnection = isDrivingRemote
            ? SessionConnection(
                transport: .webSocket(
                    URL(string: "wss://127.0.0.1:1/v1/viewer/device-grid-fixture")!,
                    bearer: { nil }
                ),
                reconnectDelay: 60
            )
            : SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-grid-ownership-\(UUID().uuidString).sock"),
                reconnectDelay: 60
            )
        let surface = TerminalSurfaceView(connection: connection, sessionID: "grid-fixture")
        surface.sharingIsLive = sharingIsLive
        // Reflowing the terminal's own geometry — `sizeChanged` calls
        // `scheduleResize()`, which either flushes immediately (no
        // coalescer, the case here) or leaves a `pendingResize` queued
        // behind the gate, exactly like a real pane's first layout pass.
        surface.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return surface
    }
}

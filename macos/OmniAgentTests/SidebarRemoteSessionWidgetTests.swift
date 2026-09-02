import XCTest
@testable import OmniAgent

/// The remote live-session widget (2026-09-01 remote environment sharing
/// spec §6, Task 25): host name, elapsed time counting up locally, a red
/// End session button — mounted above the self-update card
/// (`NavigationSidebarTests` pins the ordering).
@MainActor
final class SidebarRemoteSessionWidgetTests: XCTestCase {
    func testHiddenWithNoSessionShownWithOne() {
        let widget = SidebarRemoteSessionWidgetView()
        XCTAssertTrue(widget.isHidden)
        widget.apply(RemoteSessionInfo(machineName: "Mac Studio", since: Date()))
        XCTAssertFalse(widget.isHidden)
        widget.apply(nil)
        XCTAssertTrue(widget.isHidden, "and hidden again once the session ends")
    }

    func testTheTitleNamesTheHost() {
        let widget = SidebarRemoteSessionWidgetView()
        widget.apply(RemoteSessionInfo(machineName: "Mac Studio", since: Date()))
        XCTAssertEqual(widget.titleText, "Driving Mac Studio")
    }

    /// The elapsed caption is read off `session.since`, not off a stored
    /// duration — so ticking it forward is exactly re-reading the clock,
    /// never adding to a counter that could drift from the real elapsed
    /// time.
    func testTheCaptionCountsUpFromSince() {
        let widget = SidebarRemoteSessionWidgetView()
        let since = Date(timeIntervalSinceNow: -75) // 1:15 ago
        widget.apply(RemoteSessionInfo(machineName: "Mac Studio", since: since))
        widget.tick(now: since.addingTimeInterval(75))
        XCTAssertEqual(widget.captionText, "01:15")
    }

    func testFormatSwitchesToHoursPastTheFirstOne() {
        XCTAssertEqual(SidebarRemoteSessionWidgetView.format(elapsed: 65), "01:05")
        XCTAssertEqual(SidebarRemoteSessionWidgetView.format(elapsed: 3661), "1:01:01")
        XCTAssertEqual(SidebarRemoteSessionWidgetView.format(elapsed: 0), "00:00")
        XCTAssertEqual(SidebarRemoteSessionWidgetView.format(elapsed: -5), "00:00", "never a negative reading")
    }

    func testEndSessionButtonFiresOnEndSession() {
        let widget = SidebarRemoteSessionWidgetView()
        widget.apply(RemoteSessionInfo(machineName: "Mac Studio", since: Date()))
        var ended = 0
        widget.onEndSession = { ended += 1 }
        widget.endButtonForTesting.onClick?()
        XCTAssertEqual(ended, 1)
    }

    /// Offscreen render, never by eye (standing instruction): the card lays
    /// itself out inside whatever width the sidebar column gives it, with
    /// the button never overrunning the trailing edge.
    func testTheCardLaysOutInsideItsColumnWidth() {
        let widget = SidebarRemoteSessionWidgetView()
        widget.apply(RemoteSessionInfo(machineName: "Mac Studio", since: Date()))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: SidebarRemoteSessionWidgetView.height))
        widget.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(widget)
        NSLayoutConstraint.activate([
            widget.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            widget.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            widget.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(widget.frame.height, SidebarRemoteSessionWidgetView.height)
        XCTAssertLessThanOrEqual(widget.endButtonForTesting.frame.maxX, widget.bounds.width)
        XCTAssertGreaterThanOrEqual(widget.endButtonForTesting.frame.minX, 0)
    }
}

import AppKit
import XCTest

@testable import OmniAgent

/// The review panel's Browser tab — the 2026-08-20 redesign's §5: a WKWebView
/// under a URL field with back/forward/reload, plus one-click suggestions for
/// the dev-server ports found in the session's terminals. Normalization goes
/// through `BrowserPaneView.destination` — one rule for both browser surfaces
/// — and every navigation routes through the seam, so nothing here boots
/// WebKit.
final class ReviewPanelBrowserViewTests: XCTestCase {
    /// Stands in for the WKWebView, so navigations are assertable without a
    /// WebKit content process — `RendererSpy`'s pattern next door.
    private final class NavigatorSpy: ReviewPanelBrowserNavigator {
        var loadedURLs: [String] = []
        var backPresses = 0
        var forwardPresses = 0
        var reloadPresses = 0
        func load(_ url: URL) { loadedURLs.append(url.absoluteString) }
        func goBack() { backPresses += 1 }
        func goForward() { forwardPresses += 1 }
        func reload() { reloadPresses += 1 }
    }

    // MARK: - URL normalization

    /// The field speaks the browser pane's language: bare local hosts get
    /// http://, bare domains https://, real URLs pass through.
    func testDestinationNormalizesWhatTheUserTypes() {
        XCTAssertEqual(
            ReviewPanelBrowserView.destination(for: "localhost:5173")?.absoluteString,
            "http://localhost:5173"
        )
        XCTAssertEqual(
            ReviewPanelBrowserView.destination(for: "127.0.0.1:8080")?.absoluteString,
            "http://127.0.0.1:8080"
        )
        XCTAssertEqual(
            ReviewPanelBrowserView.destination(for: "example.com")?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            ReviewPanelBrowserView.destination(for: "https://example.com/docs")?.absoluteString,
            "https://example.com/docs"
        )
        XCTAssertNil(ReviewPanelBrowserView.destination(for: "   "))
    }

    // MARK: - Port extraction

    /// Sample scrollback: the ports a dev server prints are found, deduped,
    /// and ordered most-recent-first — the server still talking is the one
    /// the user wants.
    func testDetectPortsFindsDevServersInScrollback() {
        let lines = [
            "$ npm run dev",
            "  VITE v5.4.2  ready in 312 ms",
            "  ➜  Local:   http://localhost:5173/",
            "  ➜  Network: http://127.0.0.1:5173/",
            "$ python3 -m http.server 8000",
            "Serving HTTP on 127.0.0.1 port 8000 (http://127.0.0.1:8000/) ...",
        ]
        XCTAssertEqual(ReviewPanelBrowserView.detectPorts(in: lines), [8000, 5173])
    }

    /// Only the spec's two shapes count — localhost:PORT and 127.0.0.1:PORT
    /// — and only with a port a TCP socket could actually wear.
    func testDetectPortsIgnoresWhatIsNotADevServerPort() {
        let lines = [
            "listening on myhost:3000",
            "mylocalhost:4000 is not localhost",
            "localhost:99999 is out of range",
            "localhost:0 is not a port",
            "127.0.0.2:8080 is not loopback's name",
            "no ports here at all",
        ]
        XCTAssertEqual(ReviewPanelBrowserView.detectPorts(in: lines), [])
    }

    /// Case does not matter — `Localhost:3000` is still the local machine.
    func testDetectPortsIsCaseInsensitive() {
        XCTAssertEqual(
            ReviewPanelBrowserView.detectPorts(in: ["Server ready at Localhost:3000"]),
            [3000]
        )
    }

    // MARK: - The suggestions row

    /// Terminal lines in, chips out: one per distinct port, labelled as the
    /// address a click will load.
    func testTheSuggestionsRowOffersEachFoundPortOnce() {
        let browser = makeBrowser()

        browser.updatePortSuggestions(fromTerminalLines: [
            "  ➜  Local:   http://localhost:5173/",
            "  ➜  Local:   http://localhost:5173/",
            "Serving HTTP on 127.0.0.1 port 8000 (http://127.0.0.1:8000/) ...",
        ])

        XCTAssertEqual(browser.suggestedPorts, [8000, 5173])
        XCTAssertEqual(browser.suggestionChips.map(\.title), ["localhost:8000", "localhost:5173"])
    }

    /// A rescan that finds nothing clears the row rather than advertising a
    /// server that has exited.
    func testARescanWithNoPortsClearsTheSuggestions() {
        let browser = makeBrowser()
        browser.updatePortSuggestions(fromTerminalLines: ["localhost:5173"])
        XCTAssertEqual(browser.suggestedPorts, [5173])

        browser.updatePortSuggestions(fromTerminalLines: ["$ echo done"])

        XCTAssertEqual(browser.suggestedPorts, [])
        XCTAssertTrue(browser.suggestionChips.isEmpty)
    }

    /// One click on a chip loads the local server — through the same
    /// normalization the field uses.
    func testAChipClickNavigatesToTheLocalServer() throws {
        let browser = makeBrowser()
        let spy = NavigatorSpy()
        browser.navigatorForTesting = spy
        browser.updatePortSuggestions(fromTerminalLines: ["ready on localhost:5173"])

        try XCTUnwrap(browser.suggestionChips.first?.onPress)()

        XCTAssertEqual(spy.loadedURLs, ["http://localhost:5173"])
        XCTAssertEqual(browser.urlField.stringValue, "http://localhost:5173")
        XCTAssertNil(browser.webView, "the seam replaces the web view — none is paid for")
    }

    // MARK: - The navigation seam

    /// Committing the field normalizes what was typed and hands the URL to
    /// the navigator; the empty state stands down.
    func testCommittingTheFieldNavigatesThroughNormalization() {
        let browser = makeBrowser()
        let spy = NavigatorSpy()
        browser.navigatorForTesting = spy
        XCTAssertFalse(browser.emptyStateView.isHidden, "nothing loaded yet")

        browser.urlField.stringValue = "localhost:3000"
        _ = browser.urlField.sendAction(browser.urlField.action, to: browser.urlField.target)

        XCTAssertEqual(spy.loadedURLs, ["http://localhost:3000"])
        XCTAssertEqual(browser.urlField.stringValue, "http://localhost:3000")
        XCTAssertTrue(browser.emptyStateView.isHidden)
    }

    /// Whitespace that normalizes to nothing goes nowhere.
    func testABlankFieldCommitLoadsNothing() {
        let browser = makeBrowser()
        let spy = NavigatorSpy()
        browser.navigatorForTesting = spy

        browser.urlField.stringValue = "   "
        _ = browser.urlField.sendAction(browser.urlField.action, to: browser.urlField.target)

        XCTAssertEqual(spy.loadedURLs, [])
        XCTAssertFalse(browser.emptyStateView.isHidden)
    }

    /// The three nav buttons route to the navigator — and with no page ever
    /// loaded there is no navigator to route to, so they must not conjure a
    /// WKWebView just to have one.
    func testBackForwardReloadRouteToTheNavigator() throws {
        let browser = makeBrowser()
        try XCTUnwrap(browser.backButton.onPress)()
        XCTAssertNil(browser.webView, "a back press with no page builds nothing")

        let spy = NavigatorSpy()
        browser.navigatorForTesting = spy
        try XCTUnwrap(browser.backButton.onPress)()
        try XCTUnwrap(browser.forwardButton.onPress)()
        try XCTUnwrap(browser.reloadButton.onPress)()

        XCTAssertEqual(spy.backPresses, 1)
        XCTAssertEqual(spy.forwardPresses, 1)
        XCTAssertEqual(spy.reloadPresses, 1)
    }

    // MARK: - Scan on tab activation, through the controller

    /// Activating the Browser tab is what scans the showing session's
    /// terminals — the Changes tab's refresh-on-activation, for ports. The
    /// unlaid-out terminal here is only a few columns wide, so this also
    /// proves the scan reads *unwrapped* lines: the address arrives broken
    /// across many rows and must still be found whole.
    func testActivatingTheBrowserTabScansTheSessionTerminals() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: dir.path, id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        let surface = try XCTUnwrap(controller.workspaceView.terminalSurface(for: "s-1"))
        surface.feed(
            Data("$ npm run dev\r\n  Local:   http://localhost:5173/\r\n".utf8),
            isSnapshot: false
        )

        controller.applyRestoredReviewPanel(
            ReviewPanelStateCodec.serialize([
                "g-1": ReviewPanelSessionState(open: true, activeTab: "files"),
            ])
        )
        XCTAssertEqual(
            controller.reviewPanelBrowser.suggestedPorts, [],
            "an inactive tab scans nothing — activation is the trigger"
        )

        controller.reviewPanel.addTab(.browser)

        XCTAssertEqual(controller.reviewPanelBrowser.suggestedPorts, [5173])
        XCTAssertEqual(
            controller.reviewPanelBrowser.suggestionChips.map(\.title),
            ["localhost:5173"]
        )
    }

    // MARK: - Helpers

    private func makeBrowser() -> ReviewPanelBrowserView {
        let browser = ReviewPanelBrowserView()
        browser.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        browser.layoutSubtreeIfNeeded()
        return browser
    }

    private func makeController(panes: [PersistedTab]) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-review-browser-test.sock")
            ),
            panes: []
        )
        controller.sessionEnsurer = { _ in }
        controller.sessionKiller = { _ in }
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(fromLayout: PersistedLayoutCodec.serialize(panes))
        )
        // The review panel only syncs while the Desk is on screen; these tests
        // are about the panel, not the destination default, so restore that
        // precondition explicitly now that `.home` is the initial destination.
        controller.applyDestination(.terminals)
        return controller
    }
}

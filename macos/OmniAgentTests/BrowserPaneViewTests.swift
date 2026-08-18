import XCTest
@testable import OmniAgent

final class BrowserPaneViewTests: XCTestCase {
    func testDestinationNormalizesInput() {
        XCTAssertEqual(BrowserPaneView.destination(for: "https://example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserPaneView.destination(for: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserPaneView.destination(for: "localhost:5173")?.absoluteString, "http://localhost:5173")
        XCTAssertEqual(BrowserPaneView.destination(for: "127.0.0.1:8080")?.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(
            BrowserPaneView.destination(for: "swift wkwebview")?.absoluteString,
            "https://www.google.com/search?q=swift%20wkwebview"
        )
        XCTAssertNil(BrowserPaneView.destination(for: "   "))
    }

    /// A path is a file, not a search — what the File Viewer button hands over.
    func testDestinationTreatsPathsAsFiles() {
        XCTAssertEqual(BrowserPaneView.destination(for: "/etc/hosts"), URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertEqual(
            BrowserPaneView.destination(for: "~/notes.md"),
            URL(fileURLWithPath: NSString(string: "~/notes.md").expandingTildeInPath)
        )
        XCTAssertEqual(
            BrowserPaneView.destination(for: "file:///etc/hosts")?.isFileURL,
            true
        )
    }

    func testDownloadDestinationAvoidsOverwriting() {
        let dir = URL(fileURLWithPath: "/tmp/dl")
        var existing: Set<String> = [dir.appendingPathComponent("a.zip").path]
        let first = BrowserPaneView.downloadDestination(
            suggestedFilename: "a.zip", in: dir, fileExists: { existing.contains($0) }
        )
        XCTAssertEqual(first.lastPathComponent, "a-1.zip")
        existing.insert(first.path)
        XCTAssertEqual(
            BrowserPaneView.downloadDestination(
                suggestedFilename: "a.zip", in: dir, fileExists: { existing.contains($0) }
            ).lastPathComponent,
            "a-2.zip"
        )
    }

    func testConformsToPaneContentViewWithNoOpResizePipeline() {
        let view = BrowserPaneView(initialURL: "")
        XCTAssertTrue((view as Any) is any PaneContentView)
        XCTAssertIdentical(view.primaryResponderView, view.webView)
        view.scheduleResize()
        view.flushResize()
        view.suspendsDrawing = true
        view.isSelected = true // all no-ops; must not crash
    }

    func testTitlePublishingReachesTheHook() {
        let view = BrowserPaneView(initialURL: "")
        let published = expectation(description: "title")
        view.onTitleChange = { title in
            if title == "Hello Pane" { published.fulfill() }
        }
        view.webView.loadHTMLString("<title>Hello Pane</title><p>hi</p>", baseURL: nil)
        wait(for: [published], timeout: 10)
    }
}

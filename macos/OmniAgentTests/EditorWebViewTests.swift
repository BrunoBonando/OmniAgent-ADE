import WebKit
import XCTest
@testable import OmniAgent

final class EditorWebViewTests: XCTestCase {
    func testJSLiteralEscapes() {
        XCTAssertEqual(EditorWebView.jsLiteral("a"), "\"a\"")
        XCTAssertEqual(EditorWebView.jsLiteral("a\"b\n"), "\"a\\\"b\\n\"")
        // The exact escaping of "/" and of non-ASCII differs by Foundation
        // version, so for anything gnarlier than the two cases above assert the
        // round-trip through a JSON decode rather than a byte-for-byte form.
        let tricky = [
            "</script>",
            "path with 'quotes' \"and\" \\slashes\\ and\nnewlines",
            "tabs\tand\rcarriage\u{0B}returns",
            "unicode: café — 🍎",
        ]
        for value in tricky {
            let literal = EditorWebView.jsLiteral(value)
            let decoded = (try? JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8))) as? [String]
            XCTAssertEqual(decoded?.first, value, "round-trip failed for \(value.debugDescription)")
        }
    }

    /// The one bridge smoke test the spec demands: the bundled page loads and
    /// Monaco answers `ready`. Catches broken assets at test time, not first
    /// launch.
    func testBundledMonacoAnswersReady() {
        let view = EditorWebView()
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        // A window-less WKWebView still loads; attach to nothing.
        wait(for: [ready], timeout: 30)
        XCTAssertTrue(view.isReady)
    }

    func testOpenEditAndReadBack() {
        let view = EditorWebView()
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        view.openModel(path: "/tmp/x.swift", content: "let x = 1", readOnly: false)
        let roundTrip = expectation(description: "content")
        view.requestContent(path: "/tmp/x.swift") { content in
            XCTAssertEqual(content, "let x = 1")
            roundTrip.fulfill()
        }
        wait(for: [roundTrip], timeout: 10)

        let dirty = expectation(description: "dirty")
        view.onDirtyChanged = { path, isDirty in
            if path == "/tmp/x.swift", isDirty { dirty.fulfill() }
        }
        view.setContentForTesting(path: "/tmp/x.swift", content: "let x = 2")
        wait(for: [dirty], timeout: 10)
    }

    /// `setContent` is the save-the-file-behind-you path: it replaces the text
    /// AND rebases the saved version, so the tab lands clean, not dirty.
    func testSetContentRebasesTheSavedVersion() {
        let view = EditorWebView()
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        view.openModel(path: "/tmp/y.txt", content: "one", readOnly: false)
        let clean = expectation(description: "clean")
        view.onDirtyChanged = { path, isDirty in
            if path == "/tmp/y.txt", !isDirty { clean.fulfill() }
        }
        view.setContent(path: "/tmp/y.txt", content: "two")
        wait(for: [clean], timeout: 10)

        let roundTrip = expectation(description: "content")
        view.requestContent(path: "/tmp/y.txt") { content in
            XCTAssertEqual(content, "two")
            roundTrip.fulfill()
        }
        wait(for: [roundTrip], timeout: 10)
    }

    /// Commands issued before `ready` are queued and replayed in order, so the
    /// pane view never has to care whether Monaco has booted yet.
    func testCommandsIssuedBeforeReadyReplay() {
        let view = EditorWebView()
        XCTAssertFalse(view.isReady)
        view.openModel(path: "/tmp/z.md", content: "# early", readOnly: false)

        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        let roundTrip = expectation(description: "content")
        view.requestContent(path: "/tmp/z.md") { content in
            XCTAssertEqual(content, "# early")
            roundTrip.fulfill()
        }
        wait(for: [roundTrip], timeout: 10)
    }

    /// Monaco's `min` build ships its stylesheet as a separate file that the
    /// AMD `vs/css` plugin injects at load time. If that ever breaks, the page
    /// still answers `ready` and the editor still round-trips text — it just
    /// renders as unstyled soup. So assert the stylesheet actually applied,
    /// via a rule only `editor.main.css` supplies.
    func testMonacoStylesheetApplies() {
        let view = EditorWebView()
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        view.openModel(path: "/tmp/styled.txt", content: "hello", readOnly: false)
        let styled = expectation(description: "styled")
        view.webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('#editor .monaco-editor')).position"
        ) { value, _ in
            XCTAssertEqual(value as? String, "relative", "editor.main.css did not load")
            styled.fulfill()
        }
        wait(for: [styled], timeout: 10)
    }

    /// The diff view's line diff is computed by Monaco's editor web worker.
    /// Getting a worker to run at all from a `file://` page is delicate — see
    /// the long comment at the top of `bridge.js` — and when it fails it fails
    /// silently, leaving the Changes tab showing two identical-looking panes.
    /// So assert a real computed change comes back.
    ///
    /// It asserts the computation, not the pixels, on purpose: Monaco renders
    /// its lines inside `requestAnimationFrame`, which never ticks for a web
    /// view in this headless test host, so `.view-line` is legitimately 0 here
    /// even for a plain editor.
    func testDiffEditorComputesChanges() {
        let view = EditorWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        view.showDiff(path: "/tmp/d.txt", original: "one\ntwo\n", modified: "one\ntwo\nthree\n")
        XCTAssertTrue(
            pollUntilPositive(view, "window.omniagent.diffChangesForTesting()"),
            "the editor web worker never computed the diff"
        )
    }

    /// `closeModel` really disposes: a later read for that path is nil, not
    /// stale text.
    func testCloseModelDisposes() {
        let view = EditorWebView()
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        view.openModel(path: "/tmp/gone.txt", content: "bye", readOnly: false)
        view.closeModel(path: "/tmp/gone.txt")
        let gone = expectation(description: "gone")
        view.requestContent(path: "/tmp/gone.txt") { content in
            XCTAssertNil(content)
            gone.fulfill()
        }
        wait(for: [gone], timeout: 10)
    }

    /// Polls a JS expression that returns a count until it is positive. The
    /// diff editor's work is asynchronous and has no bridge event of its own.
    private func pollUntilPositive(_ view: EditorWebView, _ script: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var count = 0
            let step = expectation(description: "poll")
            view.webView.evaluateJavaScript(script) { value, _ in
                count = (value as? NSNumber)?.intValue ?? 0
                step.fulfill()
            }
            wait(for: [step], timeout: 5)
            if count > 0 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}

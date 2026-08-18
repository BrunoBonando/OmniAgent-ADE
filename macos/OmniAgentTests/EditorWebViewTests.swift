import WebKit
import XCTest
@testable import OmniAgent

final class EditorWebViewTests: XCTestCase {
    func testJSLiteralEscapes() {
        XCTAssertEqual(EditorWebView.jsLiteral("a"), "\"a\"")
        XCTAssertEqual(EditorWebView.jsLiteral("a\"b\n"), "\"a\\\"b\\n\"")
    }

    /// The only judge that matters for `jsLiteral` is the engine that will
    /// evaluate its output, so evaluate it. Decoding with the same
    /// `JSONSerialization` that encoded it would be circular, and would miss
    /// exactly the characters where JSON and JavaScript string literals used to
    /// disagree: U+2028/U+2029 are legal in JSON but were syntax errors inside a
    /// JS string literal until ES2019.
    func testJSLiteralSurvivesTheJavaScriptEngine() {
        let view = EditorWebView()
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        let tricky = [
            "a",
            "</script>",
            "path with 'quotes' \"and\" \\slashes\\ and\nnewlines",
            "tabs\tand\rcarriage returns",
            "line\u{2028}and paragraph\u{2029}separators",
            "unicode: café — 🍎 — \u{0000}nul",
            "backtick ` and ${notATemplate}",
        ]
        for value in tricky {
            let literal = EditorWebView.jsLiteral(value)
            let done = expectation(description: "eval")
            view.webView.evaluateJavaScript("(\(literal))") { evaluated, error in
                XCTAssertNil(error, "JS rejected the literal for \(value.debugDescription)")
                XCTAssertEqual(evaluated as? String, value, "round-trip failed for \(value.debugDescription)")
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
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

    /// `setContent` is Swift replacing the buffer behind the user, so the tab
    /// must land clean *without ever passing through dirty*. Monaco fires
    /// `onDidChangeContent` synchronously inside `setValue`, so the naive order
    /// (write, then rebase) posts `dirty:true` first and arms a 2 s snapshot of
    /// content Swift had just written itself. Assert the whole event sequence,
    /// not just its final state.
    func testSetContentNeverFlickersDirtyOrArmsASnapshot() {
        let view = EditorWebView()
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        let path = "/tmp/quiet.txt"
        view.openModel(path: path, content: "one", readOnly: false)

        var dirtyEvents: [Bool] = []
        var snapshots: [String] = []
        let clean = expectation(description: "clean")
        clean.assertForOverFulfill = false
        view.onDirtyChanged = { changed, isDirty in
            guard changed == path else { return }
            dirtyEvents.append(isDirty)
            if !isDirty { clean.fulfill() }
        }
        view.onSnapshot = { changed, content in
            if changed == path { snapshots.append(content) }
        }

        view.setContent(path: path, content: "two")
        wait(for: [clean], timeout: 10)
        XCTAssertEqual(dirtyEvents, [false], "setContent flickered the tab through dirty")

        // The snapshot debounce is 2 s; give an armed timer room to fire.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(snapshots, [], "setContent armed a spurious content snapshot")
        XCTAssertEqual(dirtyEvents, [false], "a late dirtyChanged arrived after setContent")
    }

    /// The changes view: rows render, and `appendFileDiff` finds the right one.
    /// The path deliberately carries quotes, a dash and a space — it travels
    /// through `jsLiteral` twice and is matched back by `data-path`, so this
    /// covers the escaping and the row lookup at once.
    func testChangesViewRendersRowsAndFillsTheRightFileDiff() {
        let view = EditorWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        let tricky = "src/b — it's \"quoted\".txt"
        view.showChanges(files: [(path: "src/a.swift", badge: "M"), (path: tricky, badge: "A")])

        XCTAssertEqual(evaluate(view, "document.querySelectorAll('#changes .file').length"), "2")
        XCTAssertEqual(evaluate(view, "document.querySelectorAll('#changes .file')[1].dataset.path"), tricky)
        XCTAssertEqual(evaluate(view, "document.querySelectorAll('#changes .badge')[1].textContent"), "A")
        XCTAssertEqual(evaluate(view, "document.querySelectorAll('#changes .badge')[1].className"), "badge A")
        XCTAssertEqual(evaluate(view, "getComputedStyle(document.getElementById('changes')).display"), "block")

        view.appendFileDiff(path: tricky, text: "@@ -1 +1 @@\n-old\n+new\n context")

        let detail = "document.querySelectorAll('#changes .file')[1].querySelector('pre')"
        XCTAssertEqual(evaluate(view, "\(detail).dataset.loaded"), "1")
        XCTAssertEqual(evaluate(view, "\(detail).querySelectorAll('.hunk').length"), "1")
        XCTAssertEqual(evaluate(view, "\(detail).querySelectorAll('.del').length"), "1")
        XCTAssertEqual(evaluate(view, "\(detail).querySelectorAll('.add').length"), "1")
        XCTAssertEqual(evaluate(view, "\(detail).querySelector('.add').textContent.trim()"), "+new")
        // The other row must be untouched — this is what row matching by DOM
        // position used to get wrong.
        XCTAssertEqual(
            evaluate(view, "document.querySelectorAll('#changes .file')[0].querySelector('pre').textContent"),
            ""
        )
    }

    /// The other half of the changes protocol: the three gestures a row
    /// supports each reach Swift as the right event.
    func testChangesViewGesturesReachSwift() {
        let view = EditorWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        let path = "src/a.swift"
        view.showChanges(files: [(path: path, badge: "M")])

        // Single click expands the row and asks Swift for its diff.
        let asked = expectation(description: "requestFileDiff")
        view.onRequestFileDiff = { if $0 == path { asked.fulfill() } }
        evaluate(view, "(document.querySelector('#changes .row').click(), 'ok')")
        wait(for: [asked], timeout: 10)

        // Clicking the "open file" affordance opens the file, not the diff.
        let openedFile = expectation(description: "changesOpen file")
        view.onChangesOpen = { opened, asDiff in
            if opened == path, !asDiff { openedFile.fulfill() }
        }
        evaluate(view, "(document.querySelector('#changes .open-file').click(), 'ok')")
        wait(for: [openedFile], timeout: 10)

        // Double click opens it as a diff.
        let openedDiff = expectation(description: "changesOpen diff")
        view.onChangesOpen = { opened, asDiff in
            if opened == path, asDiff { openedDiff.fulfill() }
        }
        evaluate(
            view,
            "(document.querySelector('#changes .row')"
                + ".dispatchEvent(new MouseEvent('dblclick', { bubbles: true })), 'ok')"
        )
        wait(for: [openedDiff], timeout: 10)
    }

    /// `showMessage` is the placeholder state, and it must also be the *only*
    /// visible region — `showOnly` is what keeps the four panes exclusive.
    func testShowMessageIsTheOnlyVisibleRegion() {
        let view = EditorWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let ready = expectation(description: "ready")
        view.onReady = { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        view.showChanges(files: [(path: "src/a.swift", badge: "M")])
        view.showMessage("Select a file to edit")

        XCTAssertEqual(evaluate(view, "document.getElementById('message').textContent"), "Select a file to edit")
        for region in ["message", "editor", "diff", "changes"] {
            XCTAssertEqual(
                evaluate(view, "getComputedStyle(document.getElementById('\(region)')).display"),
                region == "message" ? "block" : "none",
                "#\(region) visibility"
            )
        }
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

    /// Evaluates a JS expression and returns it stringified, failing the test
    /// on a JS error rather than quietly yielding nil.
    @discardableResult
    private func evaluate(
        _ view: EditorWebView,
        _ script: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        var result: String?
        let done = expectation(description: "eval")
        view.webView.evaluateJavaScript("String(\(script))") { value, error in
            if let error { XCTFail("JS error for \(script): \(error)", file: file, line: line) }
            result = value as? String
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result
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

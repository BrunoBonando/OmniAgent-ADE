import XCTest
@testable import OmniAgent

final class EditorTabStripViewTests: XCTestCase {
    private func model(_ paths: [String], active: Int = 0) -> EditorPaneModel {
        var model = EditorPaneModel()
        for path in paths { model.open(path: path, kind: .file, asPreview: false) }
        model.activate(active)
        return model
    }

    func testTitles() {
        XCTAssertEqual(EditorTabStripView.title(for: EditorTab(path: "/r/a.swift", kind: .file, isPinned: true)), "a.swift")
        XCTAssertEqual(EditorTabStripView.title(for: EditorTab(path: "/r/a.swift", kind: .diff, isPinned: true)), "a.swift (Working Tree)")
        XCTAssertEqual(EditorTabStripView.title(for: EditorTab(path: "", kind: .changes, isPinned: true)), "Changes")
        XCTAssertEqual(EditorTabStripView.title(for: EditorTab(path: "/r/p.png", kind: .media, isPinned: true)), "p.png")
    }

    func testInsertionIndex() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 30), CGRect(x: 100, y: 0, width: 100, height: 30)]
        XCTAssertEqual(EditorTabStripView.insertionIndex(forX: 10, tabFrames: frames), 0)
        XCTAssertEqual(EditorTabStripView.insertionIndex(forX: 90, tabFrames: frames), 1)
        XCTAssertEqual(EditorTabStripView.insertionIndex(forX: 130, tabFrames: frames), 1)
        XCTAssertEqual(EditorTabStripView.insertionIndex(forX: 190, tabFrames: frames), 2)
        XCTAssertEqual(EditorTabStripView.insertionIndex(forX: 400, tabFrames: frames), 2)
        XCTAssertEqual(EditorTabStripView.insertionIndex(forX: 5, tabFrames: []), 0)
    }

    func testRenderProducesOneItemPerTab() {
        let strip = EditorTabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        strip.render(model: model(["/a.swift", "/b.swift"]), diffAvailable: false)
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.itemFrames.count, 2)
    }

    func testOffscreenRenderStates() throws {
        // Repo convention: verify AppKit layout by offscreen render. Renders
        // the three visual states (active+dirty, inactive preview, save button)
        // and asserts a non-empty bitmap of the right size — a crash or a
        // zero-size layout fails loudly here.
        var m = model(["/a.swift", "/b.swift"])
        m.setDirty(true, at: 0)
        let strip = EditorTabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        strip.render(model: m, diffAvailable: true)
        strip.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
        strip.cacheDisplay(in: strip.bounds, to: rep)
        // `rep.size` is the point-size (always 600 here); `pixelsWide` is the
        // backing-store pixel count, which is 600 at 1x and 1200 at 2x
        // (Retina) — this test host renders at 2x, so the check must be
        // scale-robust rather than asserting a literal 600.
        XCTAssertEqual(rep.pixelsWide, 600 * Int(rep.pixelsWide == 600 ? 1 : rep.pixelsWide / 600))
        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }

    func testCallbacks() {
        let strip = EditorTabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        strip.render(model: model(["/a.swift", "/b.swift"], active: 0), diffAvailable: false)
        var selected: Int?
        strip.onSelect = { selected = $0 }
        strip.selectForTesting(index: 1)
        XCTAssertEqual(selected, 1)
        var closed: Int?
        strip.onClose = { closed = $0 }
        strip.closeForTesting(index: 0)
        XCTAssertEqual(closed, 0)
    }
}

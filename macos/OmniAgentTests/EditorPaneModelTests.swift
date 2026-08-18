import XCTest

@testable import OmniAgent

/// VS Code's tab rules, pinned as a pure value. Everything the editor pane
/// later renders — the italic preview title, the dirty dot, which tab a drop
/// lands on — is a reading of this model, so these tests carry the weight the
/// spec asks them to (`docs/superpowers/specs/2026-08-18-editor-pane-design.md`
/// §8: "pure model tests carry the weight").
final class EditorPaneModelTests: XCTestCase {
    func testOpenAppendsAndActivates() {
        var model = EditorPaneModel()
        let index = model.open(path: "/a.swift", kind: .file, asPreview: false)
        XCTAssertEqual(index, 0)
        XCTAssertEqual(model.tabs, [EditorTab(path: "/a.swift", kind: .file, isPinned: true, isDirty: false)])
        XCTAssertEqual(model.activeIndex, 0)
    }

    func testPreviewTabIsReused() {
        var model = EditorPaneModel()
        model.open(path: "/a.swift", kind: .file, asPreview: true)
        model.open(path: "/b.swift", kind: .file, asPreview: true)
        XCTAssertEqual(model.tabs.map(\.path), ["/b.swift"])
        XCTAssertFalse(model.tabs[0].isPinned)
    }

    func testPinnedTabsAreNotReusedByPreviews() {
        var model = EditorPaneModel()
        model.open(path: "/a.swift", kind: .file, asPreview: false)
        model.open(path: "/b.swift", kind: .file, asPreview: true)
        XCTAssertEqual(model.tabs.map(\.path), ["/a.swift", "/b.swift"])
    }

    func testOpeningAnAlreadyOpenPathFocusesIt() {
        var model = EditorPaneModel()
        model.open(path: "/a.swift", kind: .file, asPreview: false)
        model.open(path: "/b.swift", kind: .file, asPreview: false)
        let index = model.open(path: "/a.swift", kind: .file, asPreview: true)
        XCTAssertEqual(index, 0)
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.activeIndex, 0)
    }

    func testReopeningPinnedDoesNotUnpin() {
        var model = EditorPaneModel()
        model.open(path: "/a.swift", kind: .file, asPreview: false)
        model.open(path: "/a.swift", kind: .file, asPreview: true)
        XCTAssertTrue(model.tabs[0].isPinned)
    }

    func testOpeningAsPinnedPinsAnExistingPreview() {
        var model = EditorPaneModel()
        model.open(path: "/a.swift", kind: .file, asPreview: true)
        model.open(path: "/a.swift", kind: .file, asPreview: false)
        XCTAssertTrue(model.tabs[0].isPinned)
    }

    func testDirtyPins() {
        var model = EditorPaneModel()
        model.open(path: "/a.swift", kind: .file, asPreview: true)
        model.setDirty(true, at: 0)
        XCTAssertTrue(model.tabs[0].isPinned)
        XCTAssertTrue(model.tabs[0].isDirty)
        model.setDirty(false, at: 0)
        XCTAssertTrue(model.tabs[0].isPinned)  // saving does not un-pin
        XCTAssertFalse(model.tabs[0].isDirty)
    }

    func testSameFileEditorAndDiffAreDistinctTabs() {
        var model = EditorPaneModel()
        model.open(path: "/a.swift", kind: .file, asPreview: false)
        model.open(path: "/a.swift", kind: .diff, asPreview: false)
        XCTAssertEqual(model.tabs.count, 2)
    }

    func testChangesTabIsUnique() {
        var model = EditorPaneModel()
        model.open(path: "", kind: .changes, asPreview: false)
        model.open(path: "", kind: .changes, asPreview: false)
        XCTAssertEqual(model.tabs.count, 1)
    }

    func testCloseAdjustsActiveIndex() {
        var model = EditorPaneModel()
        model.open(path: "/a.swift", kind: .file, asPreview: false)
        model.open(path: "/b.swift", kind: .file, asPreview: false)
        model.open(path: "/c.swift", kind: .file, asPreview: false)
        model.activate(2)
        XCTAssertEqual(model.close(at: 0)?.path, "/a.swift")
        XCTAssertEqual(model.activeIndex, 1)  // still /c.swift
        XCTAssertEqual(model.activeTab?.path, "/c.swift")
        model.close(at: 1)
        XCTAssertEqual(model.activeIndex, 0)
        model.close(at: 0)
        XCTAssertNil(model.activeTab)
        XCTAssertNil(model.close(at: 0))  // out of range is nil, not a crash
    }

    func testMoveKeepsActiveTabIdentity() {
        var model = EditorPaneModel()
        model.open(path: "/a.swift", kind: .file, asPreview: false)
        model.open(path: "/b.swift", kind: .file, asPreview: false)
        model.open(path: "/c.swift", kind: .file, asPreview: false)
        model.activate(0)
        model.move(from: 0, to: 2)
        XCTAssertEqual(model.tabs.map(\.path), ["/b.swift", "/c.swift", "/a.swift"])
        XCTAssertEqual(model.activeTab?.path, "/a.swift")
    }

    func testInsertDedupes() {
        var model = EditorPaneModel()
        model.open(path: "/a.swift", kind: .file, asPreview: false)
        let index = model.insert(EditorTab(path: "/a.swift", kind: .file, isPinned: true, isDirty: false), at: 0)
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(index, 0)
        let second = model.insert(EditorTab(path: "/b.swift", kind: .file, isPinned: true, isDirty: false), at: 0)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(model.tabs.map(\.path), ["/b.swift", "/a.swift"])
        XCTAssertEqual(model.activeTab?.path, "/b.swift")  // an inserted (dropped) tab takes focus
    }
}

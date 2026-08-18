import XCTest
@testable import OmniAgent

/// `EditorPanesCodec`: the native-only `editor_panes_native` row's
/// serialize/deserialize pair, mirroring `BrowserPanesCodec`'s per-entry
/// repair shape (a bad field costs the field, a bad entry costs the entry).
final class EditorPanesTests: XCTestCase {
    func testRoundTrip() {
        let panes = [
            PersistedEditorPane(
                tabs: [
                    PersistedEditorTab(path: "/repo/a.swift", kind: "file", pinned: true),
                    PersistedEditorTab(path: "/repo/b.swift", kind: "diff", pinned: false),
                    PersistedEditorTab(path: "", kind: "changes", pinned: true),
                ],
                active: 1,
                group: "session-1",
                groupLabel: "Main"
            ),
            PersistedEditorPane(tabs: [], active: 0, group: nil, groupLabel: nil),
        ]
        XCTAssertEqual(EditorPanesCodec.deserialize(EditorPanesCodec.serialize(panes)), panes)
    }

    func testSerializeIsDeterministic() {
        let panes = [PersistedEditorPane(tabs: [PersistedEditorTab(path: "/a", kind: "file", pinned: true)], active: 0, group: "g1", groupLabel: "L")]
        XCTAssertEqual(EditorPanesCodec.serialize(panes), EditorPanesCodec.serialize(panes))
    }

    func testCorruptRowRestoresEmpty() {
        XCTAssertEqual(EditorPanesCodec.deserialize(nil), [])
        XCTAssertEqual(EditorPanesCodec.deserialize(""), [])
        XCTAssertEqual(EditorPanesCodec.deserialize("not json"), [])
        XCTAssertEqual(EditorPanesCodec.deserialize(#"{"panes": 3}"#), [])
    }

    func testTabRepairRules() {
        let raw = #"{"panes":[{"active":9,"tabs":[{"path":"/ok","kind":"file","pinned":true},{"path":"","kind":"file","pinned":true},{"path":"/x","kind":"martian","pinned":true},{"path":"","kind":"changes","pinned":true},{"kind":"file"}]}]}"#
        let panes = EditorPanesCodec.deserialize(raw)
        XCTAssertEqual(panes.count, 1)
        // empty-path file dropped, unknown kind dropped, path-less entry dropped;
        // empty-path changes kept; active clamped into range.
        XCTAssertEqual(panes[0].tabs.map(\.kind), ["file", "changes"])
        XCTAssertEqual(panes[0].active, 1)
    }

    func testInvalidGroupDropsJustTheField() {
        let raw = #"{"panes":[{"active":0,"tabs":[{"path":"/a","kind":"file","pinned":true}],"group":"has spaces!","groupLabel":"  "}]}"#
        let panes = EditorPanesCodec.deserialize(raw)
        XCTAssertNil(panes[0].group)
        XCTAssertNil(panes[0].groupLabel)
    }

    func testSettingsKey() {
        XCTAssertEqual(SettingsKey.editorPanes, "editor_panes_native")
    }
}

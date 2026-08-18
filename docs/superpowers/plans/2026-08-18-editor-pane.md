# Editor Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dead left-menu "Files" button with a tabbed editor pane kind — Monaco-based editing, git diffs, native image/PDF previews, and drag-and-drop tabs — in the native macOS app.

**Architecture:** A new `PaneKind.editor` clones the browser pane's integration pattern (no PTY, native-only persistence row, five creation entry points). The pane's content view hosts a native AppKit tab strip over a swap container that shows either one shared WKWebView running a bundled Monaco (file/diff/changes tabs) or a native media view (image/PDF tabs). A pure `EditorPaneModel` value type owns all tab semantics so preview/pin/dirty/close rules are testable without UI.

**Tech Stack:** Swift/AppKit, WKWebView + Monaco 0.52.2 (bundled offline), PDFKit, XCTest. No new SPM dependencies.

**Spec:** `docs/superpowers/specs/2026-08-18-editor-pane-design.md` — read it first; every requirement below argues from it.

## Global Constraints

- **Native-rule exception is scoped:** Monaco-in-WKWebView is allowed ONLY inside the editor pane's content surface. Tab strip, chrome, drag-and-drop, media viewers: native AppKit. Never cite this exception elsewhere.
- **Xcode-only test loop:** run tests with `./macos/build.sh test` (Debug, no Rust needed). Single test class: `xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/<ClassName>`. Tests are HOSTED in OmniAgent.app (`TEST_HOST` is set), so `Bundle.main` is the app bundle and WKWebView/offscreen renders work.
- **pbxproj registration procedure** (the project does NOT use file-system-synchronized groups — every new file must be registered by hand): for each new Swift file, add four entries to `macos/OmniAgent.xcodeproj/project.pbxproj`: (1) a `PBXBuildFile` line in the build-file section, (2) a `PBXFileReference` line in the file-reference section, (3) the file reference id in the `OmniAgent` (app sources) or `OmniAgentTests` PBXGroup `children` list, (4) the build-file id in that target's `PBXSourcesBuildPhase` `files` list. Generate ids with `uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'`. Copy the exact formatting of the neighbouring `BrowserPanes.swift` / `BrowserPanesTests.swift` entries. For the `monaco` resource folder (Task 6): one `PBXFileReference` with `lastKnownFileType = folder; path = monaco;` under the `OmniAgent` group, plus a `PBXBuildFile` in the app target's `PBXResourcesBuildPhase` (folder references copy recursively). Verify every registration with `./macos/build.sh build` before writing code that depends on it.
- **Persistence rule:** editor panes persist ONLY to the native-only `editor_panes_native` settings row, never the shared `layout` row (the web codec destroys unknown fields on rewrite — see `SettingsKey.browserPanes`'s doc comment).
- **Commit style:** conventional commits (`feat(macos): …`, `test(macos): …`). Every commit ends with both trailers:
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>` and the Claude trailer the session already uses. **Push after every commit** (standing rule).
- **Never `git stash`** in this working tree (shared by concurrent sessions).
- **MCP contract untouched:** nothing in this plan touches `crates/mcp-server`.
- **TDD:** every task writes its failing test first, watches it fail, then implements.
- Monaco version is pinned: **monaco-editor 0.52.2** (MIT). Assets are committed, upgrades are deliberate.
- File size cap for editing: **10 MB** (`EditorFileClass.maxEditableBytes`); larger text files open read-only.

---

### Task 1: Remove the Files destination button

The left-menu "Files" button is a dead destination: clicking it blanks the pane grid and shows "Files / Coming in a later step." The sidebar FILES *tree* (lower half) stays — it becomes the editor's launcher in Task 11.

**Files:**
- Modify: `macos/OmniAgent/WorkspaceShell.swift` (destination enum ~:22-56, `setFilesSummary` ~:2733-2737, `onDiffTotals` wiring ~:2451-2453)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (nothing structural — `applyDestination` is destination-generic; verify only)
- Test: `macos/OmniAgentTests/WorkspaceShellTests.swift` (update any test pinning four destinations)

**Interfaces:**
- Consumes: `WorkspaceDestination` (CaseIterable — nav rows are built from `allCases`).
- Produces: `WorkspaceDestination` with three cases (`dashboard`, `board`, `terminals`). `setFilesSummary` and the files nav-row diff plumbing are gone; `WorkspaceFilesTreeView.onDiffTotals` remains (its header label still shows `+N −M`) but no longer feeds a nav row.

- [ ] **Step 1: Find and update tests that pin the destinations**

Run: `grep -n "files\|Files\|destination" macos/OmniAgentTests/WorkspaceShellTests.swift macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`

Any test asserting 4 nav rows, a `.files` case, or `setFilesSummary` behaviour: update it to expect 3 destinations and delete `setFilesSummary` assertions. Add one new test pinning the removal:

```swift
func testFilesDestinationIsGone() {
    XCTAssertEqual(WorkspaceDestination.allCases.map(\.rawValue), ["dashboard", "board", "terminals"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/WorkspaceShellTests`
Expected: FAIL (four cases still exist).

- [ ] **Step 3: Remove the case and its plumbing**

In `WorkspaceShell.swift`:
- Delete `case files` and its three switch arms (`title`, `subtitle`, `glyph`) from `WorkspaceDestination`.
- Delete the whole `setFilesSummary(added:removed:changed:)` method.
- In `WorkspaceSidebarView`'s init, delete the `filesTree.onDiffTotals = …` closure that called `setFilesSummary` (the tree's own header still updates itself via `setDiff`).

Search for stragglers: `grep -rn "\.files\b\|setFilesSummary" macos/OmniAgent/` — fix every hit (e.g. `WorkspacePlaceholderView` needs no change; it is destination-generic).

- [ ] **Step 4: Run the full suite**

Run: `./macos/build.sh test`
Expected: PASS.

- [ ] **Step 5: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): remove the dead Files destination from the left menu" && git push
```

---

### Task 2: EditorPaneModel — tab semantics as a pure value

The heart of the feature: VS Code's preview/pin/dirty/close/move rules, with zero UI. Everything later renders this model.

**Files:**
- Create: `macos/OmniAgent/EditorPaneModel.swift`
- Test: `macos/OmniAgentTests/EditorPaneModelTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (register both, per Global Constraints)

**Interfaces:**
- Produces (exact, later tasks depend on these):
  - `enum EditorTabKind: String, Equatable, CaseIterable { case file, diff, changes, media }`
  - `struct EditorTab: Equatable { var path: String; var kind: EditorTabKind; var isPinned: Bool; var isDirty: Bool }` (`path` is absolute; `""` for `.changes`)
  - `struct EditorPaneModel: Equatable` with: `tabs: [EditorTab]`, `activeIndex: Int`, `activeTab: EditorTab?`, `index(of:kind:) -> Int?`, `@discardableResult mutating open(path:kind:asPreview:) -> Int`, `mutating activate(_:)`, `mutating pin(at:)`, `mutating setDirty(_:at:)`, `@discardableResult mutating close(at:) -> EditorTab?`, `mutating move(from:to:)`, `@discardableResult mutating insert(_:at:) -> Int`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import OmniAgent

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
        XCTAssertTrue(model.tabs[0].isPinned) // saving does not un-pin
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
        XCTAssertEqual(model.activeIndex, 1) // still /c.swift
        XCTAssertEqual(model.activeTab?.path, "/c.swift")
        model.close(at: 1)
        XCTAssertEqual(model.activeIndex, 0)
        model.close(at: 0)
        XCTAssertNil(model.activeTab)
        XCTAssertNil(model.close(at: 0)) // out of range is nil, not a crash
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
        XCTAssertEqual(model.activeTab?.path, "/b.swift") // an inserted (dropped) tab takes focus
    }
}
```

- [ ] **Step 2: Register the two files in the pbxproj, run, verify FAIL**

Expected: compile error — `EditorPaneModel` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// What one editor tab shows.
enum EditorTabKind: String, Equatable, CaseIterable {
    case file      // an editable Monaco model
    case diff      // one file's working tree vs HEAD, read-only
    case changes   // the repo-wide overview; at most one per pane
    case media     // native image/PDF preview, read-only, never dirty
}

/// One tab. `path` is the absolute file path (`""` for `.changes`). A tab is
/// identified by `(path, kind)` — the same file's editor and diff are two tabs.
struct EditorTab: Equatable {
    var path: String
    var kind: EditorTabKind
    var isPinned: Bool
    var isDirty: Bool = false
}

/// VS Code's tab semantics as a pure value: preview tabs (italic, reused by
/// the next single-click open) vs pinned tabs, dirty-pins, close/move/insert.
/// The view renders this; nothing here touches AppKit or the filesystem.
struct EditorPaneModel: Equatable {
    private(set) var tabs: [EditorTab] = []
    private(set) var activeIndex: Int = 0

    var activeTab: EditorTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    func index(of path: String, kind: EditorTabKind) -> Int? {
        tabs.firstIndex { $0.path == path && $0.kind == kind }
    }

    /// Open a tab. An already-open `(path, kind)` is focused, never duplicated
    /// (and pinned when the open is deliberate). A preview open reuses the
    /// existing preview tab if one exists; a pinned open appends.
    @discardableResult
    mutating func open(path: String, kind: EditorTabKind, asPreview: Bool) -> Int {
        if let existing = index(of: path, kind: kind) {
            activeIndex = existing
            if !asPreview { tabs[existing].isPinned = true }
            return existing
        }
        let tab = EditorTab(path: path, kind: kind, isPinned: !asPreview)
        if asPreview, let preview = tabs.firstIndex(where: { !$0.isPinned && !$0.isDirty }) {
            tabs[preview] = tab
            activeIndex = preview
            return preview
        }
        tabs.append(tab)
        activeIndex = tabs.count - 1
        return activeIndex
    }

    mutating func activate(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
    }

    mutating func pin(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].isPinned = true
    }

    /// Dirty pins: an edited preview is a real tab (VS Code's rule). Saving
    /// clears dirty but never un-pins.
    mutating func setDirty(_ dirty: Bool, at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].isDirty = dirty
        if dirty { tabs[index].isPinned = true }
    }

    @discardableResult
    mutating func close(at index: Int) -> EditorTab? {
        guard tabs.indices.contains(index) else { return nil }
        let closed = tabs.remove(at: index)
        if index < activeIndex {
            activeIndex -= 1
        } else if activeIndex >= tabs.count {
            activeIndex = max(0, tabs.count - 1)
        }
        return closed
    }

    /// `destination` is the index in the post-removal array, matching what a
    /// drop indicator between tabs means. The active tab keeps its identity.
    mutating func move(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), source != destination else { return }
        let active = activeTab
        let tab = tabs.remove(at: source)
        let clamped = min(max(0, destination), tabs.count)
        tabs.insert(tab, at: clamped)
        if let active, let index = tabs.firstIndex(of: active) { activeIndex = index }
    }

    /// A tab arriving from another pane. Dedupes by `(path, kind)` — a drop of
    /// something already open focuses it. The landed tab takes focus.
    @discardableResult
    mutating func insert(_ tab: EditorTab, at index: Int) -> Int {
        if let existing = self.index(of: tab.path, kind: tab.kind) {
            activeIndex = existing
            return existing
        }
        let clamped = min(max(0, index), tabs.count)
        tabs.insert(tab, at: clamped)
        activeIndex = clamped
        return clamped
    }
}
```

Note the one deliberate deviation from the naive rule: `open(asPreview: true)` never reuses a preview tab that is *dirty* — a dirty tab is pinned by `setDirty`, but the guard is belt-and-braces so an edited buffer can never be silently replaced.

- [ ] **Step 4: Run to verify PASS**

Run the single class, then `./macos/build.sh test`.

- [ ] **Step 5: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): EditorPaneModel — VS Code tab semantics as a pure value" && git push
```

---

### Task 3: EditorPanesCodec and the native-only settings row

Persistence mirrors `BrowserPanesCodec` exactly: `JSONSerialization`, `.sortedKeys`, per-entry repair, never throws.

**Files:**
- Create: `macos/OmniAgent/EditorPanes.swift`
- Test: `macos/OmniAgentTests/EditorPanesTests.swift`
- Modify: `macos/OmniAgent/SettingsKeys.swift` (one new key)
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `EditorTabKind` (Task 2, for kind validation), `SessionIdentifier.isValid` (existing).
- Produces:
  - `struct PersistedEditorTab: Equatable { var path: String; var kind: String; var pinned: Bool }`
  - `struct PersistedEditorPane: Equatable { var tabs: [PersistedEditorTab]; var active: Int; var group: String?; var groupLabel: String? }`
  - `enum EditorPanesCodec { static func serialize(_: [PersistedEditorPane]) -> String; static func deserialize(_: String?) -> [PersistedEditorPane] }`
  - `SettingsKey.editorPanes == "editor_panes_native"`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import OmniAgent

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
```

- [ ] **Step 2: Register, run, verify FAIL**

- [ ] **Step 3: Implement**

Add to `SettingsKeys.swift`, directly under the `browserPanes` entry:

```swift
    /// Native-only — `browserPanes`'s reasoning applied to editor panes: the
    /// web codec would destroy this shape on its next `layout` rewrite. One
    /// JSON object, `{"panes":[{tabs:[{path,kind,pinned}],active,group?,groupLabel?}]}`
    /// — see `EditorPanesCodec`. No TypeScript twin, by design.
    static let editorPanes = "editor_panes_native"
```

Create `macos/OmniAgent/EditorPanes.swift`:

```swift
import Foundation

/// One persisted editor tab — `EditorTab` minus runtime state (`isDirty` is
/// never persisted; there is no hot exit in v1).
struct PersistedEditorTab: Equatable {
    var path: String
    /// `EditorTabKind.rawValue`. Stored as a string so an unknown kind from a
    /// future build drops the tab rather than the whole pane.
    var kind: String
    var pinned: Bool
}

/// One editor pane's persisted shape, stored under `SettingsKey.editorPanes`.
struct PersistedEditorPane: Equatable {
    var tabs: [PersistedEditorTab]
    var active: Int
    var group: String?
    var groupLabel: String?
}

/// Serializes/deserializes the `editor_panes_native` settings row. Mirrors
/// `BrowserPanesCodec` exactly: `JSONSerialization` (not `Codable`), the same
/// `.sortedKeys` write-dedupe requirement, per-field repair, never throws.
enum EditorPanesCodec {
    static func serialize(_ panes: [PersistedEditorPane]) -> String {
        let payload: [String: Any] = ["panes": panes.map(encodedPane)]
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"panes":[]}"#
        }
        return json
    }

    private static func encodedPane(_ pane: PersistedEditorPane) -> [String: Any] {
        var dict: [String: Any] = [
            "tabs": pane.tabs.map { ["path": $0.path, "kind": $0.kind, "pinned": $0.pinned] },
            "active": pane.active,
        ]
        if let group = pane.group, SessionIdentifier.isValid(group) {
            dict["group"] = group
        }
        if let label = pane.groupLabel {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { dict["groupLabel"] = trimmed }
        }
        return dict
    }

    /// Repair rules:
    /// - a pane whose `tabs` is not an array is dropped (an empty array is a
    ///   legitimate empty pane and restores as one);
    /// - a tab with an unknown `kind` is dropped;
    /// - a tab with an empty `path` is dropped unless its kind is `changes`
    ///   (the one tab that legitimately has no path);
    /// - `active` is clamped into the surviving tabs' range;
    /// - an invalid `group`/blank `groupLabel` drops just that field.
    static func deserialize(_ raw: String?) -> [PersistedEditorPane] {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let rawPanes = parsed["panes"] as? [Any]
        else {
            return []
        }
        return rawPanes.compactMap(decodePane)
    }

    private static func decodePane(_ element: Any) -> PersistedEditorPane? {
        guard
            let dict = element as? [String: Any],
            let rawTabs = dict["tabs"] as? [Any]
        else {
            return nil
        }
        let tabs = rawTabs.compactMap(decodeTab)
        let active = (dict["active"] as? Int) ?? 0

        var group: String?
        if let groupRaw = dict["group"] as? String, SessionIdentifier.isValid(groupRaw) {
            group = groupRaw
        }
        var groupLabel: String?
        if let labelRaw = dict["groupLabel"] {
            let trimmed = ((labelRaw as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            groupLabel = trimmed.isEmpty ? nil : trimmed
        }
        return PersistedEditorPane(
            tabs: tabs,
            active: min(max(0, active), max(0, tabs.count - 1)),
            group: group,
            groupLabel: groupLabel
        )
    }

    private static func decodeTab(_ element: Any) -> PersistedEditorTab? {
        guard
            let dict = element as? [String: Any],
            let path = dict["path"] as? String,
            let kind = dict["kind"] as? String,
            EditorTabKind(rawValue: kind) != nil
        else {
            return nil
        }
        guard !path.isEmpty || kind == EditorTabKind.changes.rawValue else { return nil }
        return PersistedEditorTab(path: path, kind: kind, pinned: (dict["pinned"] as? Bool) ?? true)
    }
}
```

- [ ] **Step 4: Run to verify PASS** (class, then full suite)

- [ ] **Step 5: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): EditorPanesCodec + editor_panes_native settings row" && git push
```

---

### Task 4: The `PaneKind.editor` seam — descriptor, restoration, outline, chrome nouns

Thread the new kind through every place `browser` is already special-cased. No view exists yet; this task is pure model/metadata and compiles green because the kind is inert until Task 10 builds a surface for it.

**Files:**
- Modify: `macos/OmniAgent/PaneContentView.swift` (enum)
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (`PaneDescriptor` fields ~:18-84; header subtitle noun ~:1531; `descriptorChanged` engine/branch ~:1739-1749; `updateAccessibilityLabel` ~:1767-1775)
- Modify: `macos/OmniAgent/WorkspaceRestoration.swift` (`RestoredPane` fields; `persistedTabs` already excludes non-terminal — verify)
- Modify: `macos/OmniAgent/SessionOutline.swift` (`defaultPaneName` ~:142, `isGeneratedPaneName` ~:155, `nextPaneNumber` ~:167)
- Modify: `macos/OmniAgent/CommandPalette.swift` (`detail` for pane rows ~:87)
- Modify: `macos/OmniAgent/WorkspaceShell.swift` (`TerminalRowView` icon ~:1476)
- Test: `macos/OmniAgentTests/PaneWorkspaceViewTests.swift`, `macos/OmniAgentTests/WorkspaceRestorationTests.swift` (add cases; no new files)

**Interfaces:**
- Produces:
  - `PaneKind.editor`
  - `PaneDescriptor.editorTabs: [PersistedEditorTab]` (default `[]`), `PaneDescriptor.editorActiveIndex: Int` (default `0`), both as trailing init params with defaults
  - `RestoredPane.editorTabs: [PersistedEditorTab]` (default `[]`), `RestoredPane.editorActiveIndex: Int` (default `0`)
  - `SessionOutline.defaultPaneName` returns `"Editor N"` for `.editor`
  - `nextPaneNumber` numbers editors on their own ladder (engine ignored for every non-terminal kind)

- [ ] **Step 1: Write the failing tests**

Add to `WorkspaceRestorationTests.swift`:

```swift
func testEditorPanesNeverReachTheSharedLayoutRow() {
    let editor = PaneDescriptor(
        sessionID: "editor-1", group: "g", project: "proj",
        kind: .editor
    )
    let terminal = PaneDescriptor(sessionID: "term-1", group: "g", project: "proj")
    XCTAssertEqual(
        WorkspaceRestoration.persistedTabs(from: [editor, terminal]).map(\.id),
        ["term-1"]
    )
}
```

Add to `PaneWorkspaceViewTests.swift` (SessionOutline lives in its test neighbourhood; put these where `defaultPaneName`/browser numbering tests already live — `grep -rn "Browser 1\|defaultPaneName" macos/OmniAgentTests/` and sit beside them):

```swift
func testEditorPlaceholderName() {
    let pane = PaneDescriptor(sessionID: "e", group: "g", kind: .editor)
    XCTAssertEqual(SessionOutline.paneLabel(pane), "Editor 1")
    XCTAssertTrue(SessionOutline.isGeneratedPaneName("Editor 3"))
}

func testEditorNumberingIgnoresEngine() {
    var first = PaneDescriptor(sessionID: "e1", group: "g", kind: .editor)
    first.autoNumber = 1
    let next = SessionOutline.nextPaneNumber([first], group: "g", engine: .shell, kind: .editor)
    XCTAssertEqual(next, 2)
}

func testEditorPaneCostsNoTerminalSlot() {
    let workspace = PaneWorkspaceView { _ in StubPaneContent() } // reuse the existing stub the browser tests use; grep "StubPaneContent\|FakeSurface" for its real name
    XCTAssertTrue(workspace.addPane(PaneDescriptor(sessionID: "e1", group: "g", kind: .editor)))
    XCTAssertEqual(workspace.terminalPaneCount, 0)
}
```

(Adapt the stub-surface name to whatever `BrowserPanesTests`/`PaneWorkspaceViewTests` already use for a fake `PaneContentView` — one exists for the browser-cap tests.)

- [ ] **Step 2: Run, verify FAIL** (compile error: no `.editor` case)

- [ ] **Step 3: Implement the enum + descriptor + restoration fields**

`PaneContentView.swift`:

```swift
enum PaneKind: String, Equatable {
    case terminal
    case browser
    case editor
}
```

`PaneDescriptor` (PaneWorkspaceView.swift): add stored properties and init params, both defaulted so every existing call site compiles unchanged:

```swift
    /// What an `.editor` pane holds: its persisted tab list and active index,
    /// kept on the descriptor for exactly `browserURL`'s reason — so
    /// `persistEditorPanes` can write live panes back to their row without a
    /// second bookkeeping collection.
    var editorTabs: [PersistedEditorTab]
    var editorActiveIndex: Int
```

In `init`, add `editorTabs: [PersistedEditorTab] = [], editorActiveIndex: Int = 0` after `browserURL` and assign. In `init(_ pane: RestoredPane)`, pass `editorTabs: pane.editorTabs, editorActiveIndex: pane.editorActiveIndex`.

`RestoredPane` (WorkspaceRestoration.swift): add `let editorTabs: [PersistedEditorTab]` and `let editorActiveIndex: Int`, with `editorTabs: [PersistedEditorTab] = [], editorActiveIndex: Int = 0` defaults in the explicit init, mirroring how `kind`/`browserURL` were added.

- [ ] **Step 4: Implement the nouns and numbering**

`SessionOutline.swift`:

```swift
    static func defaultPaneName(_ pane: PaneDescriptor) -> String {
        switch pane.kind {
        case .browser: return "Browser \(pane.autoNumber)"
        case .editor: return "Editor \(pane.autoNumber)"
        case .terminal: return defaultPaneName(pane.engine, pane.autoNumber)
        }
    }
```

`isGeneratedPaneName`: extend the prefix check to `parts[0] == "Browser" || parts[0] == "Editor" || Engine.allCases.contains { … }`.

`nextPaneNumber`: the engine only disambiguates terminals —

```swift
        let taken = Set(
            panes
                .filter { $0.group == group && $0.kind == kind && (kind != .terminal || $0.engine == engine) }
                .map(\.autoNumber)
        )
```

`PaneWorkspaceView.swift` chrome — three switch-ifications:

`subtitleProvider` (~:1531): replace the ternary with

```swift
            let noun: String
            switch descriptor.kind {
            case .browser: noun = "browser"
            case .editor: noun = "editor"
            case .terminal: noun = "terminal"
            }
```

`descriptorChanged` (~:1743, :1749): engine badge and branch are terminal-only —

```swift
        header.engine = descriptor.kind == .terminal ? descriptor.engine : nil
        header.refreshSubtitle()
        if descriptor.kind == .terminal { updateBranch(for: descriptor.cwd) }
```

`updateAccessibilityLabel` (~:1768): same switch for the noun.

`CommandPalette.swift` pane-row `detail` (~:87):

```swift
                            detail: {
                                switch pane.kind {
                                case .browser: return "browser"
                                case .editor: return "editor"
                                case .terminal: return pane.engine.rawValue
                                }
                            }(),
```

(The PTY-verb suppression at ~:120 already reads `pane.kind == .terminal` — correct as-is.)

`WorkspaceShell.swift` `TerminalRowView` icon (~:1476):

```swift
        let icon: NSView
        switch pane.kind {
        case .browser: icon = TerminalRowView.browserIcon()
        case .editor: icon = ShellGlyphView(.file, color: ShellPalette.fileGlyph, size: 16, lineWidth: 1.1)
        case .terminal: icon = TerminalRowView.engineIcon(for: pane.engine)
        }
```

Then chase every remaining non-exhaustive switch the compiler reports (`./macos/build.sh build`) — each new arm follows the browser arm's logic with the editor noun.

- [ ] **Step 5: Run to verify PASS** (both classes, then `./macos/build.sh test`)

- [ ] **Step 6: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): PaneKind.editor threaded through descriptor, restoration, outline and chrome" && git push
```

---

### Task 5: EditorFileClass — what kind of thing is this file?

Pure classification: text (editable), image, pdf, binary placeholder, or too-large. Decides which tab kind a click produces and whether Monaco opens read-only.

**Files:**
- Create: `macos/OmniAgent/EditorFileClass.swift`
- Test: `macos/OmniAgentTests/EditorFileClassTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:
  - `enum EditorFileClass: Equatable { case text(readOnly: Bool), image, pdf, binary }`
  - `static let maxEditableBytes = 10 * 1024 * 1024`
  - `static func classify(pathExtension: String, size: Int, sniff: Data) -> EditorFileClass` (pure)
  - `static func classify(url: URL) -> EditorFileClass` (filesystem form: stats + reads first 8 KB)
  - `var tabKind: EditorTabKind` (`.text` → `.file`; `.image`/`.pdf` → `.media`; `.binary` → `.file` — the binary placeholder renders in the web view as a message)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import OmniAgent

final class EditorFileClassTests: XCTestCase {
    func testImagesAndPDFByExtension() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "icns", "bmp"] {
            XCTAssertEqual(EditorFileClass.classify(pathExtension: ext, size: 10, sniff: Data([0, 1])), .image, ext)
        }
        XCTAssertEqual(EditorFileClass.classify(pathExtension: "PDF", size: 10, sniff: Data([0])), .pdf)
    }

    func testSVGIsText() {
        XCTAssertEqual(
            EditorFileClass.classify(pathExtension: "svg", size: 10, sniff: Data("<svg/>".utf8)),
            .text(readOnly: false)
        )
    }

    func testNullByteMeansBinary() {
        XCTAssertEqual(EditorFileClass.classify(pathExtension: "dat", size: 10, sniff: Data([65, 0, 66])), .binary)
    }

    func testHugeTextOpensReadOnly() {
        XCTAssertEqual(
            EditorFileClass.classify(pathExtension: "log", size: EditorFileClass.maxEditableBytes + 1, sniff: Data("a".utf8)),
            .text(readOnly: true)
        )
    }

    func testTabKinds() {
        XCTAssertEqual(EditorFileClass.text(readOnly: false).tabKind, .file)
        XCTAssertEqual(EditorFileClass.image.tabKind, .media)
        XCTAssertEqual(EditorFileClass.pdf.tabKind, .media)
        XCTAssertEqual(EditorFileClass.binary.tabKind, .file)
    }

    func testFilesystemForm() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = dir.appendingPathComponent("a.swift")
        try "let x = 1".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertEqual(EditorFileClass.classify(url: text), .text(readOnly: false))
        let binary = dir.appendingPathComponent("a.bin")
        try Data([1, 2, 0, 4]).write(to: binary)
        XCTAssertEqual(EditorFileClass.classify(url: binary), .binary)
    }
}
```

- [ ] **Step 2: Register, run, verify FAIL**

- [ ] **Step 3: Implement**

```swift
import Foundation

/// What a file is, for the purpose of opening it in an editor pane: editable
/// text (possibly read-only for size), a native image/PDF preview, or a
/// binary we can only describe. SVG is deliberately text — it is XML, and
/// that is VS Code's call too.
enum EditorFileClass: Equatable {
    case text(readOnly: Bool)
    case image
    case pdf
    case binary

    static let maxEditableBytes = 10 * 1024 * 1024
    static let sniffLength = 8 * 1024

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "icns", "bmp",
    ]

    var tabKind: EditorTabKind {
        switch self {
        case .image, .pdf: return .media
        case .text, .binary: return .file
        }
    }

    /// Pure core. `sniff` is the file's first bytes; a null byte anywhere in
    /// them is the classic "not text" tell (git uses the same heuristic).
    static func classify(pathExtension: String, size: Int, sniff: Data) -> EditorFileClass {
        let ext = pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if sniff.contains(0) { return .binary }
        return .text(readOnly: size > maxEditableBytes)
    }

    /// Filesystem form: one stat and one bounded read. An unreadable file is
    /// `.binary` — the placeholder is the honest state for "cannot show this".
    static func classify(url: URL) -> EditorFileClass {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .binary }
        defer { try? handle.close() }
        let sniff = (try? handle.read(upToCount: sniffLength)) ?? Data()
        return classify(pathExtension: url.pathExtension, size: size ?? 0, sniff: sniff)
    }
}
```

(Note: `attributesOfItem` returns `[FileAttributeKey: Any]`; the double-optional dance above is deliberate — write it as the compiler demands, e.g. `let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0`.)

- [ ] **Step 4: Run to verify PASS**

- [ ] **Step 5: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): EditorFileClass — text/image/pdf/binary classification with size cap" && git push
```

---

### Task 6: Monaco assets, the editor page, and the EditorWebView bridge

The one web-tech island. Vendor a pinned Monaco build into the app bundle, write the host page + bridge script, and wrap WKWebView in a typed Swift bridge. Ends with the smoke test that loads real Monaco and gets a `ready` ping.

**Files:**
- Create: `macos/OmniAgent/Resources/monaco/` (vendored `vs/` tree + `editor.html` + `bridge.js` + `LICENSE-monaco.txt`)
- Create: `macos/OmniAgent/EditorWebView.swift`
- Test: `macos/OmniAgentTests/EditorWebViewTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (Swift files + the `monaco` FOLDER reference in the app's Resources phase — see Global Constraints)

**Interfaces:**
- Consumes: nothing from earlier tasks (paths are plain strings here).
- Produces `final class EditorWebView: NSView`:
  - callbacks: `onReady: (() -> Void)?`, `onDirtyChanged: ((String, Bool) -> Void)?`, `onSnapshot: ((String, String) -> Void)?`, `onSaveRequested: ((String) -> Void)?`, `onChangesOpen: ((String, Bool) -> Void)?` (path, asDiff), `onRequestFileDiff: ((String) -> Void)?`, `onCrash: (() -> Void)?`
  - commands: `openModel(path:content:readOnly:)`, `setContent(path:content:)`, `showModel(path:)`, `markSaved(path:)`, `closeModel(path:)`, `requestContent(path:completion:)`, `showDiff(path:original:modified:)`, `showChanges(files: [(path: String, badge: String)])`, `appendFileDiff(path:text:)`, `showMessage(_: String)`
  - `let webView: WKWebView`, `private(set) var isReady: Bool`
  - `static func jsLiteral(_ value: String) -> String` (pure, testable)

**JS→Swift message shapes** (one handler, name `"editor"`; every message a dict with `type`): `{type:"ready"}`, `{type:"dirtyChanged", path, dirty}`, `{type:"contentSnapshot", path, content}` (2 s debounce), `{type:"saveRequested", path}`, `{type:"changesOpen", path, target:"diff"|"file"}`, `{type:"requestFileDiff", path}`.

- [ ] **Step 1: Vendor Monaco (no test yet — this is an asset drop)**

```bash
cd "$SCRATCHPAD" && npm pack monaco-editor@0.52.2 && tar xf monaco-editor-0.52.2.tgz
DEST=/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent/Resources/monaco
mkdir -p "$DEST/vs"
cp package/LICENSE "$DEST/LICENSE-monaco.txt"
cp package/min/vs/loader.js "$DEST/vs/"
cp -R package/min/vs/base "$DEST/vs/base"
cp -R package/min/vs/editor "$DEST/vs/editor"
cp -R package/min/vs/basic-languages "$DEST/vs/basic-languages"
# Deliberately NOT copied: min/vs/language (the TS/CSS/JSON/HTML smart workers).
# v1 wants word-based completion only; the basic-languages tokenizers cover
# highlighting for every language.
du -sh "$DEST"   # expect roughly 6–12 MB
```

- [ ] **Step 2: Write `editor.html`**

`macos/OmniAgent/Resources/monaco/editor.html`:

```html
<!doctype html>
<meta charset="utf-8">
<style>
  html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: #0c0c0f; }
  #editor, #diff { width: 100%; height: 100%; display: none; }
  #changes, #message {
    display: none; height: 100%; overflow: auto; box-sizing: border-box; padding: 12px 14px;
    color: #c2c2cb; font: 12.5px/1.6 ui-monospace, "SF Mono", Menlo, monospace;
  }
  #changes .file { margin-bottom: 2px; }
  #changes .file > .row { cursor: pointer; display: flex; gap: 8px; align-items: baseline; padding: 3px 6px; border-radius: 6px; }
  #changes .file > .row:hover { background: rgba(255, 255, 255, 0.05); }
  #changes .badge { font-weight: 600; width: 1.2em; }
  #changes .badge.M, #changes .badge.R { color: #f0b446; }
  #changes .badge.A, #changes .badge.U { color: #3ecf8e; }
  #changes .badge.D, #changes .badge.\! { color: #f2555a; }
  #changes .open-file { color: #8b95ff; margin-left: auto; font-size: 11px; }
  #changes pre { margin: 2px 0 8px 26px; white-space: pre-wrap; word-break: break-all; }
  #changes pre .add { color: #3ecf8e; }
  #changes pre .del { color: #f2555a; }
  #changes pre .hunk { color: #6e788a; }
</style>
<div id="editor"></div>
<div id="diff"></div>
<div id="changes"></div>
<div id="message"></div>
<script src="vs/loader.js"></script>
<script src="bridge.js"></script>
```

- [ ] **Step 3: Write `bridge.js`**

`macos/OmniAgent/Resources/monaco/bridge.js`:

```js
"use strict";
// The Swift side of this protocol is EditorWebView.swift — keep them in sync.
require.config({ paths: { vs: "vs" } });
window.MonacoEnvironment = { getWorkerUrl: () => "vs/base/worker/workerMain.js" };

let editor = null;
let diffEditor = null;
const models = new Map(); // path -> {model, savedVersionId, viewState, readOnly}
const snapshotTimers = new Map();
let diffModels = null; // {original, modified} — transient, disposed on hide

function post(message) { window.webkit.messageHandlers.editor.postMessage(message); }
function el(id) { return document.getElementById(id); }
function showOnly(id) {
  for (const pane of ["editor", "diff", "changes", "message"]) {
    el(pane).style.display = pane === id ? "block" : "none";
  }
  if (id !== "diff" && diffModels) {
    diffModels.original.dispose();
    diffModels.modified.dispose();
    diffModels = null;
  }
}
function languageFor(path) {
  const dot = path.lastIndexOf(".");
  if (dot < 0) return "plaintext";
  const ext = path.slice(dot).toLowerCase();
  for (const lang of monaco.languages.getLanguages()) {
    if ((lang.extensions || []).some((e) => e.toLowerCase() === ext)) return lang.id;
  }
  return "plaintext";
}

const THEME = {
  base: "vs-dark",
  inherit: true,
  rules: [],
  colors: {
    "editor.background": "#0c0c0f",
    "editor.lineHighlightBackground": "#15151a",
    "editorLineNumber.foreground": "#4a4a55",
    "editorLineNumber.activeForeground": "#b0b0ba",
    "editorCursor.foreground": "#8b95ff",
    "editor.selectionBackground": "#2c2f52",
  },
};

require(["vs/editor/editor.main"], () => {
  monaco.editor.defineTheme("omniagent", THEME);
  editor = monaco.editor.create(el("editor"), {
    theme: "omniagent",
    automaticLayout: true,
    minimap: { enabled: false },
    wordBasedSuggestions: "currentDocument",
    fontSize: 12.5,
    fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
    scrollBeyondLastLine: false,
  });
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
    const model = editor.getModel();
    if (model) post({ type: "saveRequested", path: model.uri.path });
  });
  post({ type: "ready" });
});

window.omniagent = {
  openModel(path, content, readOnly) {
    let entry = models.get(path);
    if (!entry) {
      const model = monaco.editor.createModel(content, undefined, monaco.Uri.file(path));
      entry = { model, savedVersionId: model.getAlternativeVersionId(), viewState: null, readOnly: !!readOnly };
      model.onDidChangeContent(() => {
        post({ type: "dirtyChanged", path, dirty: model.getAlternativeVersionId() !== entry.savedVersionId });
        clearTimeout(snapshotTimers.get(path));
        snapshotTimers.set(path, setTimeout(() => {
          post({ type: "contentSnapshot", path, content: model.getValue() });
        }, 2000));
      });
      models.set(path, entry);
    }
    this.showModel(path);
  },
  setContent(path, content) {
    const entry = models.get(path);
    if (!entry) return;
    entry.model.setValue(content);
    entry.savedVersionId = entry.model.getAlternativeVersionId();
    post({ type: "dirtyChanged", path, dirty: false });
  },
  showModel(path) {
    const entry = models.get(path);
    if (!entry || !editor) return;
    showOnly("editor");
    const previous = editor.getModel();
    if (previous) {
      const prev = models.get(previous.uri.path);
      if (prev) prev.viewState = editor.saveViewState();
    }
    editor.setModel(entry.model);
    editor.updateOptions({ readOnly: entry.readOnly });
    if (entry.viewState) editor.restoreViewState(entry.viewState);
    editor.focus();
  },
  markSaved(path) {
    const entry = models.get(path);
    if (!entry) return;
    entry.savedVersionId = entry.model.getAlternativeVersionId();
    post({ type: "dirtyChanged", path, dirty: false });
  },
  getContent(path) {
    const entry = models.get(path);
    return entry ? entry.model.getValue() : null;
  },
  closeModel(path) {
    const entry = models.get(path);
    if (!entry) return;
    clearTimeout(snapshotTimers.get(path));
    snapshotTimers.delete(path);
    entry.model.dispose();
    models.delete(path);
  },
  showDiff(path, original, modified) {
    showOnly("diff");
    if (!diffEditor) {
      diffEditor = monaco.editor.createDiffEditor(el("diff"), {
        theme: "omniagent",
        automaticLayout: true,
        readOnly: true,
        renderSideBySide: true,
        minimap: { enabled: false },
        fontSize: 12.5,
      });
    }
    if (diffModels) { diffModels.original.dispose(); diffModels.modified.dispose(); }
    const language = languageFor(path);
    diffModels = {
      original: monaco.editor.createModel(original, language),
      modified: monaco.editor.createModel(modified, language),
    };
    diffEditor.setModel(diffModels);
  },
  showChanges(files) {
    showOnly("changes");
    const container = el("changes");
    container.textContent = "";
    if (!files.length) {
      container.textContent = "No changes.";
      return;
    }
    for (const file of files) {
      const wrap = document.createElement("div");
      wrap.className = "file";
      const row = document.createElement("div");
      row.className = "row";
      const badge = document.createElement("span");
      badge.className = "badge " + file.badge;
      badge.textContent = file.badge;
      const name = document.createElement("span");
      name.textContent = file.path;
      const open = document.createElement("span");
      open.className = "open-file";
      open.textContent = "open file";
      row.append(badge, name, open);
      const detail = document.createElement("pre");
      detail.style.display = "none";
      wrap.append(row, detail);
      row.addEventListener("click", (event) => {
        if (event.target === open) {
          post({ type: "changesOpen", path: file.path, target: "file" });
          return;
        }
        if (detail.style.display === "none") {
          detail.style.display = "block";
          if (!detail.dataset.loaded) post({ type: "requestFileDiff", path: file.path });
        } else {
          detail.style.display = "none";
        }
      });
      row.addEventListener("dblclick", () => post({ type: "changesOpen", path: file.path, target: "diff" }));
      container.append(wrap);
    }
  },
  appendFileDiff(path, text) {
    const container = el("changes");
    for (const wrap of container.querySelectorAll(".file")) {
      if (wrap.querySelector(".row span:nth-child(2)").textContent !== path) continue;
      const detail = wrap.querySelector("pre");
      detail.dataset.loaded = "1";
      detail.textContent = "";
      for (const line of text.split("\n")) {
        const span = document.createElement("span");
        span.textContent = line + "\n";
        if (line.startsWith("+") && !line.startsWith("+++")) span.className = "add";
        else if (line.startsWith("-") && !line.startsWith("---")) span.className = "del";
        else if (line.startsWith("@@")) span.className = "hunk";
        detail.append(span);
      }
      return;
    }
  },
  showMessage(text) {
    showOnly("message");
    el("message").textContent = text;
  },
};
```

- [ ] **Step 4: Write the failing Swift tests**

```swift
import WebKit
import XCTest
@testable import OmniAgent

final class EditorWebViewTests: XCTestCase {
    func testJSLiteralEscapes() {
        XCTAssertEqual(EditorWebView.jsLiteral("a"), "\"a\"")
        XCTAssertEqual(EditorWebView.jsLiteral("a\"b\n"), "\"a\\\"b\\n\"")
        XCTAssertEqual(EditorWebView.jsLiteral("</script>"), "\"<\\/script>\"".replacingOccurrences(of: "\\/", with: "\\/"))
        // The exact escaping of "/" may differ by Foundation version; assert round-trip instead:
        let tricky = "path with 'quotes' \"and\" \\slashes\\ and\nnewlines"
        let literal = EditorWebView.jsLiteral(tricky)
        let decoded = try? JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8)) as? [String]
        XCTAssertEqual(decoded?.first, tricky)
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
}
```

(`setContentForTesting` drives `model.setValue` through a raw `evaluateJavaScript` that does NOT reset `savedVersionId` — the bridge's `setContent` deliberately does. Expose it as `func setContentForTesting(path:content:)` calling `run("models.get(...)")`? No — `models` is closed over. Instead add a tiny test hook to `bridge.js`: `window.omniagent.typeForTesting = (path, content) => { const e = models.get(path); if (e) e.model.setValue(content); };` and call it from the Swift method.)

- [ ] **Step 5: Register everything, run, verify FAIL** (no `EditorWebView`)

- [ ] **Step 6: Implement `EditorWebView.swift`**

```swift
import AppKit
import WebKit

/// The Monaco host: one WKWebView per editor pane, running the bundled
/// `Resources/monaco/editor.html`. This class is the whole bridge — typed
/// commands down via `evaluateJavaScript`, typed events up via one
/// `WKScriptMessageHandler`. Swift owns all file I/O; the page never sees a
/// URL outside its own bundle folder.
final class EditorWebView: NSView, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var isReady = false
    /// Commands issued before Monaco's `ready` land here and replay in order.
    private var queued: [String] = []

    var onReady: (() -> Void)?
    var onDirtyChanged: ((String, Bool) -> Void)?
    var onSnapshot: ((String, String) -> Void)?
    var onSaveRequested: ((String) -> Void)?
    var onChangesOpen: ((String, Bool) -> Void)?
    var onRequestFileDiff: ((String) -> Void)?
    var onCrash: (() -> Void)?

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)
        configuration.userContentController.add(self, name: "editor")
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground") // the page paints #0c0c0f
        addSubview(webView)
        loadPage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        webView.frame = bounds
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        webView.frame = bounds
    }

    private func loadPage() {
        guard
            let page = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "monaco"),
            let folder = Bundle.main.url(forResource: "monaco", withExtension: nil)
        else {
            assertionFailure("monaco assets missing from the bundle")
            return
        }
        webView.loadFileURL(page, allowingReadAccessTo: folder)
    }

    // MARK: - Commands (Swift -> JS)

    /// One JSON-escaped JS string literal. Foundation only encodes top-level
    /// arrays/objects portably, so wrap-and-strip.
    static func jsLiteral(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private func run(_ script: String) {
        guard isReady else {
            queued.append(script)
            return
        }
        webView.evaluateJavaScript(script)
    }

    func openModel(path: String, content: String, readOnly: Bool) {
        run("window.omniagent.openModel(\(Self.jsLiteral(path)), \(Self.jsLiteral(content)), \(readOnly))")
    }
    func setContent(path: String, content: String) {
        run("window.omniagent.setContent(\(Self.jsLiteral(path)), \(Self.jsLiteral(content)))")
    }
    func showModel(path: String) { run("window.omniagent.showModel(\(Self.jsLiteral(path)))") }
    func markSaved(path: String) { run("window.omniagent.markSaved(\(Self.jsLiteral(path)))") }
    func closeModel(path: String) { run("window.omniagent.closeModel(\(Self.jsLiteral(path)))") }
    func showDiff(path: String, original: String, modified: String) {
        run("window.omniagent.showDiff(\(Self.jsLiteral(path)), \(Self.jsLiteral(original)), \(Self.jsLiteral(modified)))")
    }
    func showChanges(files: [(path: String, badge: String)]) {
        let payload = files.map { ["path": $0.path, "badge": $0.badge] }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("[]".utf8)
        run("window.omniagent.showChanges(\(String(data: data, encoding: .utf8) ?? "[]"))")
    }
    func appendFileDiff(path: String, text: String) {
        run("window.omniagent.appendFileDiff(\(Self.jsLiteral(path)), \(Self.jsLiteral(text)))")
    }
    func showMessage(_ text: String) { run("window.omniagent.showMessage(\(Self.jsLiteral(text)))") }
    func setContentForTesting(path: String, content: String) {
        run("window.omniagent.typeForTesting(\(Self.jsLiteral(path)), \(Self.jsLiteral(content)))")
    }

    func requestContent(path: String, completion: @escaping (String?) -> Void) {
        guard isReady else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript("window.omniagent.getContent(\(Self.jsLiteral(path)))") { value, _ in
            completion(value as? String)
        }
    }

    // MARK: - Events (JS -> Swift)

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            let replay = queued
            queued = []
            for script in replay { webView.evaluateJavaScript(script) }
            onReady?()
        case "dirtyChanged":
            if let path = body["path"] as? String, let dirty = body["dirty"] as? Bool {
                onDirtyChanged?(path, dirty)
            }
        case "contentSnapshot":
            if let path = body["path"] as? String, let content = body["content"] as? String {
                onSnapshot?(path, content)
            }
        case "saveRequested":
            if let path = body["path"] as? String { onSaveRequested?(path) }
        case "changesOpen":
            if let path = body["path"] as? String {
                onChangesOpen?(path, (body["target"] as? String) != "file")
            }
        case "requestFileDiff":
            if let path = body["path"] as? String { onRequestFileDiff?(path) }
        default:
            break
        }
    }

    /// WebKit's renderer died. Reload the page; the owner re-opens models
    /// (with its crash snapshots) when `onReady` fires again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        queued = []
        onCrash?()
        loadPage()
    }
}
```

Add the `typeForTesting` hook to `bridge.js` (inside `window.omniagent`):

```js
  typeForTesting(path, content) {
    const entry = models.get(path);
    if (entry) entry.model.setValue(content);
  },
```

- [ ] **Step 7: Run to verify PASS** (`EditorWebViewTests` first — the smoke test proves the vendored assets load — then full suite)

- [ ] **Step 8: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): bundled Monaco 0.52.2 + EditorWebView bridge (spec: native-rule exception, editor surface only)" && git push
```

---

### Task 7: EditorTabStripView — the native tab strip

The app's first tab strip: a 30 pt AppKit row rendering an `EditorPaneModel`. Click to select, × to close, dirty dot, italic previews, a Save button while the active tab is dirty, a "± Diff" toggle for changed files, horizontal overflow scroll. Drag *sources* land here too (the drop side is Task 14).

**Files:**
- Create: `macos/OmniAgent/EditorTabStripView.swift`
- Test: `macos/OmniAgentTests/EditorTabStripViewTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `EditorPaneModel`, `EditorTab`, `EditorTabKind` (Task 2).
- Produces `final class EditorTabStripView: NSView`:
  - `static let height: CGFloat = 30`
  - `func render(model: EditorPaneModel, diffAvailable: Bool)`
  - callbacks: `onSelect: ((Int) -> Void)?`, `onClose: ((Int) -> Void)?`, `onPin: ((Int) -> Void)?` (double-click), `onSave: (() -> Void)?`, `onDiffToggle: (() -> Void)?`, `onBeginDrag: ((Int, NSEvent) -> Void)?`
  - `static func title(for tab: EditorTab) -> String` (pure: file/media → last path component; diff → `"name (Working Tree)"`; changes → `"Changes"`)
  - `static func insertionIndex(forX x: CGFloat, tabFrames: [CGRect]) -> Int` (pure — Task 14 uses it)
  - `func showDropIndicator(at index: Int)` / `func clearDropIndicator()` (Task 14 uses them)
  - `private(set) var itemFrames: [CGRect]` (frames of the rendered tab items, exposed for tests and Task 14)

- [ ] **Step 1: Write the failing tests**

```swift
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
        XCTAssertEqual(rep.pixelsWide, 600 * Int(rep.size.width == 600 ? 1 : rep.pixelsWide / 600))
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
```

- [ ] **Step 2: Register, run, verify FAIL**

- [ ] **Step 3: Implement**

Design constraints (follow the sidebar's aesthetic — `ShellPalette`, `ShellFont`): strip background `PaneContainerView.paneBackgroundColor`; active tab a slightly lighter fill (`NSColor(white: 1, alpha: 0.07)`) with `ShellPalette.ink` text; inactive `ShellPalette.inkNav`; preview titles italic (`NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)`); dirty dot is a 7 pt filled circle in `ShellPalette.ink` that swaps to an × button on hover (track with `NSTrackingArea`).

```swift
import AppKit

/// The native tab strip over an editor pane's content — the app's first tab
/// strip, deliberately AppKit (the native-rule exception covers only the
/// editor surface below it). Renders an `EditorPaneModel`; every mutation
/// goes back up through callbacks, the strip never mutates state itself.
final class EditorTabStripView: NSView {
    static let height: CGFloat = 30

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onPin: ((Int) -> Void)?
    var onSave: (() -> Void)?
    var onDiffToggle: (() -> Void)?
    var onBeginDrag: ((Int, NSEvent) -> Void)?

    private let scroll = NSScrollView()
    private let itemsStack = NSStackView()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let diffButton = NSButton(title: "± Diff", target: nil, action: nil)
    private let dropIndicator = NSView()
    private var items: [EditorTabItemView] = []

    private(set) var itemFrames: [CGRect] = []

    // init: wantsLayer, background paneBackgroundColor; scroll horizontal-only
    // (hasHorizontalScroller, autohides, no vertical), documentView = itemsStack
    // (horizontal, spacing 1, edgeInsets 4/6); saveButton + diffButton pinned
    // to the trailing edge OUTSIDE the scroll view (bezelStyle .accessoryBarAction,
    // controlSize .small, hidden by default), targets self / #selector(savePressed)
    // and #selector(diffPressed); dropIndicator: 2pt wide, accent
    // (PaneContainerView.focusedBorderColor), hidden, added above the stack.

    static func title(for tab: EditorTab) -> String {
        switch tab.kind {
        case .changes: return "Changes"
        case .diff: return "\((tab.path as NSString).lastPathComponent) (Working Tree)"
        case .file, .media: return (tab.path as NSString).lastPathComponent
        }
    }

    static func insertionIndex(forX x: CGFloat, tabFrames: [CGRect]) -> Int {
        for (index, frame) in tabFrames.enumerated() where x < frame.midX {
            return index
        }
        return tabFrames.count
    }

    func render(model: EditorPaneModel, diffAvailable: Bool) {
        for view in itemsStack.arrangedSubviews {
            itemsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        items = model.tabs.enumerated().map { index, tab in
            let item = EditorTabItemView(tab: tab, title: Self.title(for: tab), active: index == model.activeIndex)
            item.onPress = { [weak self] in self?.onSelect?(index) }
            item.onDoublePress = { [weak self] in self?.onPin?(index) }
            item.onClosePress = { [weak self] in self?.onClose?(index) }
            item.onDragOut = { [weak self] event in self?.onBeginDrag?(index, event) }
            return item
        }
        for item in items { itemsStack.addArrangedSubview(item) }
        saveButton.isHidden = !(model.activeTab?.isDirty ?? false)
        diffButton.isHidden = !(diffAvailable && model.activeTab?.kind == .file)
        layoutSubtreeIfNeeded()
        itemFrames = items.map { $0.convert($0.bounds, to: self) }
    }

    func showDropIndicator(at index: Int) { /* position at itemFrames[index].minX (or last maxX), unhide */ }
    func clearDropIndicator() { dropIndicator.isHidden = true }

    // Test hooks — the real events go through EditorTabItemView's mouse handling.
    func selectForTesting(index: Int) { items[index].onPress?() }
    func closeForTesting(index: Int) { items[index].onClosePress?() }

    @objc private func savePressed() { onSave?() }
    @objc private func diffPressed() { onDiffToggle?() }
}

/// One tab: title, dirty-dot/close swap on hover, italic preview title.
/// mouseDown records, mouseUp fires press (clickCount >= 2 → double press),
/// mouseDragged past 4 pt fires onDragOut once.
final class EditorTabItemView: NSView {
    var onPress: (() -> Void)?
    var onDoublePress: (() -> Void)?
    var onClosePress: (() -> Void)?
    var onDragOut: ((NSEvent) -> Void)?
    // init(tab:title:active:) builds: title NSTextField (italic when
    // !tab.isPinned), a 16x16 right accessory that draws the dirty dot when
    // tab.isDirty && !hovered, and an × (ShellGlyphView(.close, …)) when
    // hovered or (!tab.isDirty); NSTrackingArea for hover; corner radius 5;
    // width: intrinsic from title + 44; height Self-anchored to 24, centered.
    // mouseDown/mouseUp/mouseDragged implement press/double/drag-out; a click
    // landing in the accessory's frame fires onClosePress instead of onPress.
}
```

The two skeleton comments above are the full behavioural spec for the layout code — write the bodies to match them exactly (frame-based like `BrowserPaneView.applyLayout`, or Auto Layout inside the stack; either is fine as long as `itemFrames` ends up real). Keep every colour/font choice from the design constraints paragraph.

- [ ] **Step 4: Run to verify PASS**

- [ ] **Step 5: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): EditorTabStripView — native tab strip with preview/dirty states" && git push
```

---

### Task 8: MediaTabView — native image and PDF previews

**Files:**
- Create: `macos/OmniAgent/MediaTabView.swift`
- Test: `macos/OmniAgentTests/MediaTabViewTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `EditorFileClass` (Task 5).
- Produces `final class MediaTabView: NSView`:
  - `func show(url: URL, kind: EditorFileClass)` — `.image` → zoomable scrollable `NSImageView` over a checkerboard, with a caption; `.pdf` → `PDFKit.PDFView` (`autoScales`, continuous); anything else → the binary placeholder text
  - `var preferredResponder: NSView` (the `PDFView` for PDFs, `self` otherwise)
  - `static func caption(pixelsWide: Int, pixelsHigh: Int, byteCount: Int) -> String` (pure — `"1024 × 768 · 2.1 MB"` via `ByteCountFormatter`)
  - `static func placeholderText(name: String, byteCount: Int) -> String` (pure — `"a.bin — binary file, 12 KB"`)
  - `static func checkerboard() -> NSImage` (16×16 two-tone pattern tile)

- [ ] **Step 1: Write the failing tests**

```swift
import PDFKit
import XCTest
@testable import OmniAgent

final class MediaTabViewTests: XCTestCase {
    func testCaption() {
        XCTAssertEqual(MediaTabView.caption(pixelsWide: 1024, pixelsHigh: 768, byteCount: 2_097_152), "1024 × 768 · 2.1 MB")
    }

    func testPlaceholder() {
        XCTAssertEqual(MediaTabView.placeholderText(name: "a.bin", byteCount: 12_288), "a.bin — binary file, 12 KB")
    }

    func testShowImageOffscreen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("dot.png")
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemRed.setFill(); rect.fill(); return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)

        let view = MediaTabView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.show(url: url, kind: .image)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }

    func testShowPDFSwapsResponder() {
        let view = MediaTabView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = PDFDocument()
        // An empty PDFDocument written to disk is still a valid PDF file.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        document.write(to: url)
        view.show(url: url, kind: .pdf)
        XCTAssertTrue(view.preferredResponder is PDFView)
    }
}
```

- [ ] **Step 2: Register, run, verify FAIL**

- [ ] **Step 3: Implement**

Byte counts use one shared formatter so the two pure functions agree:

```swift
import AppKit
import PDFKit

/// Native read-only preview for the tabs Monaco should never touch: images
/// (zoomable NSImageView over a checkerboard, with a dimensions·size caption)
/// and PDFs (PDFKit, which brings scroll/zoom/selection/⌘F for free). Also
/// renders the binary-file placeholder. All AppKit — the native-rule
/// exception stops at the Monaco surface.
final class MediaTabView: NSView {
    private let scroll = NSScrollView()
    private let imageView = NSImageView()
    private let pdfView = PDFView()
    private let captionField = NSTextField(labelWithString: "")
    private let placeholderField = NSTextField(labelWithString: "")

    var preferredResponder: NSView { pdfView.isHidden ? self : pdfView }

    // init: background PaneContainerView.paneBackgroundColor; scroll wraps
    // imageView (allowsMagnification 0.25…8, magnificationGesture free via
    // NSScrollView.allowsMagnification), scroll.backgroundColor from the
    // checkerboard pattern (NSColor(patternImage: Self.checkerboard()));
    // captionField pinned bottom-center, secondaryLabelColor, ShellFont.mono(11);
    // placeholderField centered, ShellPalette.inkMuted; pdfView.autoScales = true,
    // displayMode .singlePageContinuous. All three content views hidden until show().

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func caption(pixelsWide: Int, pixelsHigh: Int, byteCount: Int) -> String {
        "\(pixelsWide) × \(pixelsHigh) · \(byteFormatter.string(fromByteCount: Int64(byteCount)))"
    }

    static func placeholderText(name: String, byteCount: Int) -> String {
        "\(name) — binary file, \(byteFormatter.string(fromByteCount: Int64(byteCount)))"
    }

    static func checkerboard() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor(white: 0.10, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            NSColor(white: 0.14, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
    }

    func show(url: URL, kind: EditorFileClass) {
        let byteCount = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        switch kind {
        case .image:
            let image = NSImage(contentsOf: url)
            imageView.image = image
            let rep = image?.representations.first
            captionField.stringValue = Self.caption(
                pixelsWide: rep?.pixelsWide ?? Int(image?.size.width ?? 0),
                pixelsHigh: rep?.pixelsHigh ?? Int(image?.size.height ?? 0),
                byteCount: byteCount
            )
            setVisible(image: true, pdf: false, placeholder: false)
        case .pdf:
            pdfView.document = PDFDocument(url: url)
            setVisible(image: false, pdf: true, placeholder: false)
        case .text, .binary:
            placeholderField.stringValue = Self.placeholderText(name: url.lastPathComponent, byteCount: byteCount)
            setVisible(image: false, pdf: false, placeholder: true)
        }
    }

    private func setVisible(image: Bool, pdf: Bool, placeholder: Bool) {
        scroll.isHidden = !image
        captionField.isHidden = !image
        pdfView.isHidden = !pdf
        placeholderField.isHidden = !placeholder
    }
}
```

Write the init exactly per its skeleton comment (frame-based or Auto Layout — the offscreen test only demands a real render).

- [ ] **Step 4: Run to verify PASS**

- [ ] **Step 5: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): MediaTabView — native image/PDF previews and binary placeholder" && git push
```

---

### Task 9: EditorPaneView — the pane content view

Assembles model + strip + web + media into a `PaneContentView`. Owns file I/O (read on open, atomic write on save), dirty wiring, save prompts on close, crash snapshots, and the callbacks the controller wires in Task 10.

**Files:**
- Create: `macos/OmniAgent/EditorPaneView.swift`
- Test: `macos/OmniAgentTests/EditorPaneViewTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `EditorPaneModel` (2), `PersistedEditorTab` (3), `EditorFileClass` (5), `EditorWebView` (6), `EditorTabStripView` (7), `MediaTabView` (8), `PaneContentView`/`PaneContainerView.paneBackgroundColor` (existing).
- Produces `final class EditorPaneView: NSView, PaneContentView`:
  - `init(initialTabs: [PersistedEditorTab], activeIndex: Int)` — drops tabs whose file no longer exists (except `.changes`), clamps active
  - `private(set) var model: EditorPaneModel`
  - callbacks: `onTitleChange: ((String) -> Void)?`, `onStateChange: (([PersistedEditorTab], Int) -> Void)?`, `onLastTabClosed: (() -> Void)?`, `onOpenDiffRequest: ((URL) -> Void)?` (the ± button and changes-tab rows route up; the controller decides which pane shows the diff — itself)
  - state the controller injects: `var workspaceRoot: URL?`, `var changedPaths: Set<String>` (drives `diffAvailable` + Changes data)
  - actions: `func openFile(_ url: URL, pinned: Bool)`, `func openDiff(_ url: URL)`, `func openChanges()`, `func saveActiveTab()`, `func requestCloseTab(at index: Int)`, `func closeAllTabsAfterConfirmation(completion: @escaping (Bool) -> Void)` (false = user cancelled), `var hasDirtyTabs: Bool`, `func saveAllDirty(completion: @escaping (Bool) -> Void)`
  - alert seams (tests replace them): `var confirmSave: ((_ fileName: String, _ decide: @escaping (EditorSaveDecision) -> Void) -> Void)`, `var presentError: ((String) -> Void)`
  - `enum EditorSaveDecision { case save, discard, cancel }`
  - PaneContentView: `isSelected`, `suspendsDrawing`, `resizeCoalescer` (no-op), `primaryResponderView` (web view for file/diff/changes, media's `preferredResponder` for media, `self` when empty), `focus()`, `scheduleResize() {}`, `flushResize() {}`
- Task 12 extends this class with the diff-content plumbing; Task 15 with mtime-conflict + crash restore. This task lands file open/edit/save/close.

- [ ] **Step 1: Write the failing tests**

Tests drive the pane with a real `EditorWebView` (Monaco boots in ~2–5 s hosted; keep one shared instance per test case via `setUp` waiting on a readiness expectation). File I/O runs against a temp directory.

```swift
import XCTest
@testable import OmniAgent

final class EditorPaneViewTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makePane() -> EditorPaneView {
        let pane = EditorPaneView(initialTabs: [], activeIndex: 0)
        pane.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return pane
    }

    func testOpenFileAddsPreviewTabAndPublishesState() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        var published: [PersistedEditorTab]?
        var title: String?
        pane.onStateChange = { tabs, _ in published = tabs }
        pane.onTitleChange = { title = $0 }
        pane.openFile(url, pinned: false)
        XCTAssertEqual(pane.model.tabs.count, 1)
        XCTAssertFalse(pane.model.tabs[0].isPinned)
        XCTAssertEqual(published?.map(\.path), [url.path])
        XCTAssertEqual(title, "a.swift")
    }

    func testMediaFileOpensAsMediaTab() throws {
        let url = dir.appendingPathComponent("p.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        let pane = makePane()
        pane.openFile(url, pinned: true)
        XCTAssertEqual(pane.model.tabs[0].kind, .media)
    }

    func testDirtyFlowsFromBridgeAndSaveWrites() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        let ready = expectation(description: "ready")
        pane.webHost.onReadyForTesting = { ready.fulfill() }
        wait(for: [ready], timeout: 30)
        pane.openFile(url, pinned: true)

        let dirty = expectation(description: "dirty")
        pane.onStateChange = { tabs, _ in if tabs.first != nil, pane.model.tabs[0].isDirty { dirty.fulfill() } }
        pane.webHost.setContentForTesting(path: url.path, content: "let x = 2")
        wait(for: [dirty], timeout: 10)

        let saved = expectation(description: "saved")
        pane.saveActiveTab { XCTAssertTrue($0); saved.fulfill() } // completion form for tests
        wait(for: [saved], timeout: 10)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let x = 2")
        XCTAssertFalse(pane.model.tabs[0].isDirty)
    }

    func testCloseDirtyTabAsksAndCancelKeepsIt() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        pane.openFile(url, pinned: true)
        pane.modelForTesting { $0.setDirty(true, at: 0) }
        var asked = false
        pane.confirmSave = { _, decide in asked = true; decide(.cancel) }
        pane.requestCloseTab(at: 0)
        XCTAssertTrue(asked)
        XCTAssertEqual(pane.model.tabs.count, 1)
        pane.confirmSave = { _, decide in decide(.discard) }
        pane.requestCloseTab(at: 0)
        XCTAssertEqual(pane.model.tabs.count, 0)
    }

    func testLastTabClosedFires() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        var fired = false
        pane.onLastTabClosed = { fired = true }
        pane.openFile(url, pinned: true)
        pane.requestCloseTab(at: 0)
        XCTAssertTrue(fired)
    }

    func testRestoreDropsVanishedFiles() throws {
        let alive = try write("a.swift", "x")
        let pane = EditorPaneView(
            initialTabs: [
                PersistedEditorTab(path: alive.path, kind: "file", pinned: true),
                PersistedEditorTab(path: dir.appendingPathComponent("gone.swift").path, kind: "file", pinned: true),
                PersistedEditorTab(path: "", kind: "changes", pinned: true),
            ],
            activeIndex: 1
        )
        XCTAssertEqual(pane.model.tabs.map(\.kind), [.file, .changes])
    }
}
```

Notes for the implementer: expose the small test hooks the suite uses — `webHost` (the `EditorWebView`, internal not private), `onReadyForTesting` (alias for `onReady` that does not clobber the pane's own wiring: store the pane's handler and call both), `modelForTesting(_ mutate: (inout EditorPaneModel) -> Void)` (mutates then re-syncs), and a `saveActiveTab(completion:)` overload (the public `saveActiveTab()` calls it with `{ _ in }`).

- [ ] **Step 2: Register, run, verify FAIL**

- [ ] **Step 3: Implement**

The full class skeleton — write every body; the comments state the behaviour each must have:

```swift
import AppKit

enum EditorSaveDecision { case save, discard, cancel }

/// An editor pane's content: a native tab strip over a swap container that
/// shows either the Monaco web surface (file/diff/changes tabs) or a native
/// media view (image/PDF). The PTY half of `PaneContentView` is a no-op,
/// exactly like `BrowserPaneView`. All disk I/O lives here, on the Swift
/// side; Monaco only ever sees strings.
final class EditorPaneView: NSView, PaneContentView {
    let strip = EditorTabStripView()
    let webHost = EditorWebView()
    let mediaHost = MediaTabView()
    private let emptyField = NSTextField(labelWithString: "No file open — click a file in FILES")

    private(set) var model = EditorPaneModel()

    var onTitleChange: ((String) -> Void)?
    var onStateChange: (([PersistedEditorTab], Int) -> Void)?
    var onLastTabClosed: (() -> Void)?
    var onOpenDiffRequest: ((URL) -> Void)?

    var workspaceRoot: URL?
    var changedPaths: Set<String> = [] { didSet { syncChrome() } }

    var confirmSave: ((String, @escaping (EditorSaveDecision) -> Void) -> Void) = EditorPaneView.defaultConfirmSave
    var presentError: ((String) -> Void) = { message in
        let alert = NSAlert()
        alert.messageText = "Could not save"
        alert.informativeText = message
        alert.runModal()
    }

    /// Per-open-file bookkeeping, keyed by absolute path.
    private var encodings: [String: String.Encoding] = [:]
    private var modificationDates: [String: Date] = [:]
    /// Debounced dirty-buffer snapshots from the bridge — crash insurance
    /// (Task 15 replays them on renderer death).
    private(set) var dirtySnapshots: [String: String] = [:]

    // MARK: - PaneContentView
    var isSelected = false
    var suspendsDrawing = false
    weak var resizeCoalescer: PaneResizeCoalescer?
    var primaryResponderView: NSView {
        switch model.activeTab?.kind {
        case .media: return mediaHost.preferredResponder
        case .none: return self
        default: return webHost.webView
        }
    }
    func focus() { window?.makeFirstResponder(primaryResponderView) }
    func scheduleResize() {}
    func flushResize() {}

    init(initialTabs: [PersistedEditorTab], activeIndex: Int) {
        super.init(frame: .zero)
        // wantsLayer; background PaneContainerView.paneBackgroundColor;
        // subviews: strip (top, EditorTabStripView.height), webHost/mediaHost/
        // emptyField filling the rest (isFlipped true; applyLayout mirrors
        // BrowserPaneView's: strip.frame at y=0, content below it — override
        // layout() and setFrameSize(_:)).
        wireStrip()
        wireBridge()
        restore(initialTabs: initialTabs, activeIndex: activeIndex)
    }

    // restore(initialTabs:activeIndex:): filter tabs — keep .changes always;
    // keep others only if FileManager.default.fileExists(atPath:); map kind
    // strings through EditorTabKind(rawValue:) (unknown already dropped by the
    // codec, belt-and-braces here); rebuild model via model.insert in order,
    // then model.activate(clamped index); syncAll() WITHOUT publishing (the
    // restore is what the row already says).

    private func wireStrip() {
        strip.onSelect = { [weak self] index in self?.activateTab(index) }
        strip.onPin = { [weak self] index in
            guard let self else { return }
            model.pin(at: index)
            syncAll()
        }
        strip.onClose = { [weak self] index in self?.requestCloseTab(at: index) }
        strip.onSave = { [weak self] in self?.saveActiveTab() }
        strip.onDiffToggle = { [weak self] in
            guard let self, let tab = model.activeTab, tab.kind == .file else { return }
            onOpenDiffRequest?(URL(fileURLWithPath: tab.path))
        }
        // strip.onBeginDrag wired in Task 14.
    }

    private func wireBridge() {
        webHost.onDirtyChanged = { [weak self] path, dirty in
            guard let self, let index = model.index(of: path, kind: .file) else { return }
            model.setDirty(dirty, at: index)
            if !dirty { dirtySnapshots.removeValue(forKey: path) }
            syncAll()
        }
        webHost.onSnapshot = { [weak self] path, content in
            self?.dirtySnapshots[path] = content
        }
        webHost.onSaveRequested = { [weak self] path in
            guard let self, let index = model.index(of: path, kind: .file) else { return }
            save(at: index) { _ in }
        }
        // onChangesOpen / onRequestFileDiff wired in Tasks 12–13.
        // onCrash wired in Task 15.
    }

    // MARK: - Opening

    func openFile(_ url: URL, pinned: Bool) {
        let classified = EditorFileClass.classify(url: url)
        let kind = classified.tabKind
        let hadTab = model.index(of: url.path, kind: kind) != nil
        model.open(path: url.path, kind: kind, asPreview: !pinned)
        if !hadTab, kind == .file { loadFileTab(url, classified: classified) }
        syncAll()
        showActiveContent()
    }

    // loadFileTab(_:classified:): for .text — read String(contentsOf: .utf8),
    // fall back to .isoLatin1 (record which succeeded in `encodings`); record
    // mtime in modificationDates; webHost.openModel(path:content:readOnly:).
    // For .binary — webHost is NOT involved; showActiveContent routes a binary
    // .file tab to mediaHost.show(url:kind:.binary). Read failures:
    // webHost.showMessage("Could not read <name>").

    func openDiff(_ url: URL) { /* Task 12 — placeholder body: open the tab kind only */ }
    func openChanges() { /* Task 13 */ }

    // activateTab(_:): model.activate; if the newly active file tab's model was
    // never loaded (restore path), loadFileTab now; syncAll + showActiveContent.

    // showActiveContent(): switch model.activeTab?.kind —
    //   .file (text)  → webHost.showModel(path); web visible, media hidden
    //   .file (binary)→ mediaHost.show(url:kind:.binary); media visible
    //   .media        → mediaHost.show(url:kind: classify(url:)); media visible
    //   .diff/.changes→ web visible (content wired in Tasks 12–13)
    //   nil           → emptyField visible
    // Track per-file-tab "is binary" by re-classifying on demand (cheap stat +
    // 8 KB read) rather than a parallel dictionary.

    // MARK: - Saving

    func saveActiveTab() { saveActiveTab { _ in } }
    func saveActiveTab(completion: @escaping (Bool) -> Void) {
        guard let tab = model.activeTab, tab.kind == .file else { completion(false); return }
        guard let index = model.index(of: tab.path, kind: .file) else { completion(false); return }
        save(at: index, completion: completion)
    }

    // save(at:completion:): requestContent from webHost; nil → completion(false).
    // Write with the recorded encoding (default .utf8), atomically:true.
    // Throw → presentError(message), completion(false), stay dirty.
    // Success → refresh modificationDates[path], webHost.markSaved(path),
    // model.setDirty(false, at:), dirtySnapshots.removeValue, syncAll(),
    // completion(true).

    var hasDirtyTabs: Bool { model.tabs.contains(where: \.isDirty) }

    // saveAllDirty(completion:): iterate dirty file tabs serially (chain the
    // async saves); false as soon as one fails; true when all landed.

    // MARK: - Closing

    func requestCloseTab(at index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        let tab = model.tabs[index]
        guard tab.isDirty else {
            performClose(at: index)
            return
        }
        confirmSave((tab.path as NSString).lastPathComponent) { [weak self] decision in
            guard let self else { return }
            switch decision {
            case .cancel: break
            case .discard: performClose(at: index)
            case .save:
                save(at: index) { saved in
                    if saved { self.performClose(at: self.model.index(of: tab.path, kind: .file) ?? index) }
                }
            }
        }
    }

    // performClose(at:): model.close; if closed tab was a text file →
    // webHost.closeModel + drop encodings/modificationDates/dirtySnapshots
    // entries; syncAll + showActiveContent; if model.tabs.isEmpty →
    // onLastTabClosed?().

    // closeAllTabsAfterConfirmation(completion:): walk dirty tabs recursively
    // with confirmSave; any .cancel → completion(false); all resolved →
    // completion(true). (Task 15's quit path calls this.)

    // MARK: - Sync

    // syncAll(): strip.render(model:diffAvailable: activeFileHasChanges());
    // onTitleChange?(activeTitle) where activeTitle is
    // EditorTabStripView.title(for: activeTab) or "Editor";
    // publish: onStateChange?(persistedTabs, model.activeIndex).
    // persistedTabs: model.tabs.map { PersistedEditorTab(path: $0.path,
    // kind: $0.kind.rawValue, pinned: $0.isPinned) }.
    // syncChrome(): strip.render only (changedPaths moved — no state publish).
    // activeFileHasChanges(): activeTab.kind == .file && changedPaths.contains(path).

    private static func defaultConfirmSave(_ name: String, _ decide: @escaping (EditorSaveDecision) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: decide(.save)
        case .alertSecondButtonReturn: decide(.discard)
        default: decide(.cancel)
        }
    }
}
```

Every `// method(...)` comment above is a contract — implement each exactly as described. Accessibility: `setAccessibilityElement(true)`, role `.group`, label `"Editor pane"` in init.

- [ ] **Step 4: Run to verify PASS** (`EditorPaneViewTests`, then full suite)

- [ ] **Step 5: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): EditorPaneView — tabbed Monaco editor pane content view" && git push
```

---

### Task 10: Workspace and controller integration — creation entry points and persistence

Make `.editor` a real pane kind users can create (⇧⌘E, toolbar, palette, sidebar row, hole tile) and that survives relaunch via `editor_panes_native`. This clones the browser pane's five entry points and its read-gate/write-gate persistence pair line for line.

**Files:**
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (makeSurface ~:225-232; wiring branch ~:1470-1484; flags ~:151-156; persistence ~:1330-1391; onPanesChanged ~:279-283; `newBrowserPane`/`newBrowser` neighbourhood ~:672-706; `validateMenuItem` ~:829-863; palette `run` ~:1016-1059; `shellSidebar.onNewBrowser` neighbourhood ~:307-317)
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (`editorPane(for:)` beside `browserPane(for:)` ~:280; `onRequestNewEditorPane` beside `onRequestNewBrowserPane` ~:172; hole tile ~:1236-1247, ~:2826-2880)
- Modify: `macos/OmniAgent/AppDelegate.swift` (menu ~:113)
- Modify: `macos/OmniAgent/WorkspaceToolbar.swift`
- Modify: `macos/OmniAgent/CommandPalette.swift`
- Modify: `macos/OmniAgent/WorkspaceShell.swift` (sidebar "New editor" row ~:1857-1863 + the `onNewEditor` chain)
- Test: `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`, `macos/OmniAgentTests/BrowserPanesTests.swift` (sibling patterns live here — add editor equivalents in a new `macos/OmniAgentTests/EditorPaneIntegrationTests.swift`)

**Interfaces:**
- Consumes: everything from Tasks 2–9.
- Produces:
  - `PaneWorkspaceView.editorPane(for:) -> EditorPaneView?`, `PaneWorkspaceView.onRequestNewEditorPane: (() -> Void)?`
  - Controller: `@objc func newEditorPane(_ sender: Any?)`, `@discardableResult func newEditor(in session: SessionGroupNode?) -> Bool`, `func applyRestoredEditorPanes(_ panes: [PersistedEditorPane])`, `private func persistEditorPanes()`, `private func restoreEditorPanesIfNeeded()`
  - `PaletteAction.newEditorPane`
  - `PaneHolePlaceholderView` grows `onActivateEditor` + a third "+ New editor" line

- [ ] **Step 1: Write the failing tests** (`EditorPaneIntegrationTests.swift` — copy the harness style `BrowserPanesTests` uses for controller tests: construct `WorkspaceWindowController(connection:panes:)` with the test connection double, set `settingsWriter` to a recorder)

```swift
import XCTest
@testable import OmniAgent

final class EditorPaneIntegrationTests: XCTestCase {
    // Use the same helper the browser tests use to make a controller with a
    // stubbed connection (grep "settingsWriter" in BrowserPanesTests /
    // WorkspaceWindowControllerTests and mirror the setup).

    func testNewEditorAddsANonTerminalPane() {
        let controller = makeController() // the mirrored helper
        XCTAssertTrue(controller.newEditor(in: nil))
        let id = controller.workspace.allPaneIDs.last!
        XCTAssertEqual(controller.workspace.descriptor(for: id)?.kind, .editor)
        XCTAssertEqual(controller.workspace.terminalPaneCount, 1) // just the bootstrap terminal
        XCTAssertNotNil(controller.workspace.editorPane(for: id))
    }

    func testEditorStateFlowsToDescriptorAndPersistedRow() throws {
        var written: [String: String] = [:]
        let controller = makeController()
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredEditorPanes([]) // opens the write gate, browser-style
        XCTAssertTrue(controller.newEditor(in: nil))
        let id = controller.workspace.allPaneIDs.last!
        let pane = try XCTUnwrap(controller.workspace.editorPane(for: id))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        pane.openFile(file, pinned: true)

        XCTAssertEqual(controller.workspace.descriptor(for: id)?.editorTabs.map(\.path), [file.path])
        let row = try XCTUnwrap(written[SettingsKey.editorPanes])
        XCTAssertTrue(row.contains(file.lastPathComponent))
    }

    func testRestoreRebuildsPanesAndNeverTouchesTheDaemon() {
        let controller = makeController()
        var ensured: [String] = []
        controller.sessionEnsurer = { ensured.append($0) }
        controller.applyRestoredEditorPanes([
            PersistedEditorPane(tabs: [], active: 0, group: nil, groupLabel: nil)
        ])
        let editors = controller.workspace.allPaneIDs.filter {
            controller.workspace.descriptor(for: $0)?.kind == .editor
        }
        XCTAssertEqual(editors.count, 1)
        XCTAssertTrue(ensured.isEmpty)
    }

    func testWriteGateStaysShutUntilRead() {
        var written: [String: String] = [:]
        let controller = makeController()
        controller.settingsWriter = { key, value in written[key] = value }
        XCTAssertTrue(controller.newEditor(in: nil)) // gate closed: no read yet
        XCTAssertNil(written[SettingsKey.editorPanes])
    }

    func testPaletteOffersNewEditorPane() {
        let commands = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0)
        XCTAssertTrue(commands.contains { $0.action == .newEditorPane })
    }
}
```

- [ ] **Step 2: Register the test file, run, verify FAIL**

- [ ] **Step 3: Implement — surface factory and workspace seams**

`WorkspaceWindowController` init (~:225):

```swift
        workspace = PaneWorkspaceView { descriptor in
            switch descriptor.kind {
            case .terminal:
                return TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
            case .browser:
                return BrowserPaneView(initialURL: descriptor.browserURL)
            case .editor:
                return EditorPaneView(
                    initialTabs: descriptor.editorTabs,
                    activeIndex: descriptor.editorActiveIndex
                )
            }
        }
```

`PaneWorkspaceView`, beside `browserPane(for:)`:

```swift
    /// The concrete editor behind a pane, for the editor-shaped call sites
    /// (tab-state/title wiring, drop routing). `nil` for any other kind.
    func editorPane(for sessionID: String) -> EditorPaneView? {
        containers[sessionID]?.surface as? EditorPaneView
    }
```

and beside `onRequestNewBrowserPane`:

```swift
    /// The hole tile's third affordance: an editor in that cell.
    var onRequestNewEditorPane: (() -> Void)?
```

- [ ] **Step 4: Implement — the controller wiring branch**

In `addPane(_:startSession:)`, extend the non-terminal branch (~:1470):

```swift
        } else if let browser = workspace.browserPane(for: sessionID) {
            // … existing browser wiring unchanged …
        } else if let editor = workspace.editorPane(for: sessionID) {
            editor.onTitleChange = { [weak self] title in
                guard let self else { return }
                workspace.updateDescriptor(for: sessionID) { $0.title = title }
                if workspace.focusedPaneID == sessionID { refreshTitle() }
            }
            // Tab mutations flow into the descriptor; `updateDescriptor` fires
            // `onPanesChanged`, which is what `persistEditorPanes` hangs off —
            // the browser pane's onURLChange pattern, applied to tabs.
            editor.onStateChange = { [weak self] tabs, active in
                self?.workspace.updateDescriptor(for: sessionID) {
                    $0.editorTabs = tabs
                    $0.editorActiveIndex = active
                }
            }
            editor.onLastTabClosed = { [weak self] in
                self?.workspace.closePane(sessionID)
            }
            editor.onOpenDiffRequest = { [weak self] url in self?.openDiffInEditor(url) }
            editor.workspaceRoot = workspaceDirectory(for: pane.project).map { URL(fileURLWithPath: $0) }
                ?? (selectedProjectID.flatMap { self.workspaceDirectory(for: $0) }.map { URL(fileURLWithPath: $0) })
        }
```

(`openDiffInEditor` gets a real body in Task 12 — land it now as a stub that only logs, so this task compiles: `func openDiffInEditor(_ url: URL) {}` with a `// Task 12` comment. This is the one permitted forward reference in the plan, closed three tasks later.)

- [ ] **Step 5: Implement — creation entry points**

Controller, directly under `newBrowser(in:)` (~:706):

```swift
    /// ⇧⌘E — an editor pane in the focused pane's session. `newBrowser(in:)`
    /// minus the URL: no PTY, `startSession: false`, only grid geometry can
    /// refuse it.
    @objc func newEditorPane(_ sender: Any?) {
        newEditor(in: nil)
    }

    @discardableResult
    func newEditor(in session: SessionGroupNode?) -> Bool {
        let sibling = session.map { seed in
            seed.paneIDs.first.flatMap { workspace.descriptor(for: $0) }
        } ?? workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        let template = WorkspaceRestoration.bootstrapPane()
        let group = session?.id ?? sibling?.group ?? template.group
        guard workspace.paneCount(inGroup: group) < PaneGrid.maxPanes else { return false }
        return addPane(
            RestoredPane(
                sessionID: template.sessionID,
                reattaches: false,
                project: sibling?.project ?? session?.project ?? "",
                engine: .shell,
                cwd: "",
                label: nil,
                themeId: nil,
                group: group,
                groupLabel: sibling?.groupLabel ?? session?.name,
                kind: .editor
            ),
            startSession: false
        )
    }
```

`validateMenuItem`: add beside the browser arm —

```swift
        case #selector(newEditorPane(_:)):
            // Like a browser: no PTY cost, only the on-screen grid can refuse.
            return workspace.paneIDs.count < PaneGrid.maxPanes
```

`AppDelegate.swift` (~:114, after the browser item):

```swift
        file.addItem(item("New Editor Pane", Selector(("newEditorPane:")), "e", [.command, .shift]))
```

`WorkspaceToolbar.swift`: add `static let newEditor = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.new-editor")`, insert it after `newBrowser` in the default identifiers, and add the case:

```swift
        case ToolbarItem.newEditor:
            return item(identifier, "New Editor", "doc.text", #selector(newEditorPane(_:)))
```

`CommandPalette.swift`: add `case newEditorPane` to `PaletteAction`; in `build`, after the new-browser row:

```swift
        commands.append(
            PaletteCommand(id: "new-editor", title: "New editor pane", detail: "⇧⌘E", action: .newEditorPane)
        )
```

Controller `run(_:)`: `case .newEditorPane: newEditorPane(nil)`.

Sidebar row (`WorkspaceShell.swift` ~:1863, after the browser row): the sessions tree needs `var onNewEditor: (() -> Void)?` beside `onNewBrowser` (grep its declaration), then:

```swift
                let addEditor = NewTerminalRowView(title: "New editor", shortcut: "⇧⌘E")
                addEditor.onPress = { [weak self] in self?.onNewEditor?() }
                rows.addArrangedSubview(addEditor)
                addEditor.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
```

Chain it: `WorkspaceSidebarView` gets `var onNewEditor: (() -> Void)?` and `sessionsTree.onNewEditor = { [weak self] in self?.onNewEditor?() }` in its init; controller init mirrors the `onNewBrowser` block with `self.newEditor(in: current)`.

Hole tile (`PaneHolePlaceholderView`): add `private let onActivateEditor: () -> Void` (init param, default `{}`), `private static let editorText = "+ New editor" as NSString` drawn with `browserAttributes` under the browser line, an `editorTextRect` derived like `browserTextRect` (below it, same 7 pt gap), and extend the click `dispatch(at:)` to fire it. Wire in `syncHolePlaceholders`:

```swift
            let placeholder = PaneHolePlaceholderView(
                onActivate: { [weak self] in self?.onRequestNewPane?() },
                onActivateBrowser: { [weak self] in self?.onRequestNewBrowserPane?() },
                onActivateEditor: { [weak self] in self?.onRequestNewEditorPane?() }
            )
```

and in the controller init, beside the browser line: `workspace.onRequestNewEditorPane = { [weak self] in self?.newEditorPane(nil) }`.

- [ ] **Step 6: Implement — persistence**

Controller flags (beside the browser pair ~:156):

```swift
    /// The `editor_panes_native` row's two flags — same shape and reasons as
    /// the browser pair above.
    private var editorPanesReadDispatched = false
    private var editorPanesReadCompleted = false
```

Mirror the three browser methods (place directly under `persistBrowserPanes`):

```swift
    private func restoreEditorPanesIfNeeded() {
        guard !editorPanesReadDispatched else { return }
        editorPanesReadDispatched = true
        connection.getSetting(key: SettingsKey.editorPanes) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                applyRestoredEditorPanes(EditorPanesCodec.deserialize(raw))
            case .failure:
                editorPanesReadDispatched = false
            }
        }
    }

    /// Split out for tests, `applyRestoredBrowserPanes`'s shape. Editor panes
    /// never touch `ensureSession` — `addPane`'s kind branch keeps them off
    /// the daemon.
    func applyRestoredEditorPanes(_ panes: [PersistedEditorPane]) {
        editorPanesReadCompleted = true
        for pane in panes
        where workspace.paneCount(inGroup: pane.group ?? WorkspaceRestoration.ungroupedSessionID) < PaneGrid.maxPanes {
            addPane(
                RestoredPane(
                    sessionID: UUID().uuidString,
                    reattaches: false,
                    project: "",
                    engine: .shell,
                    cwd: "",
                    label: nil,
                    themeId: nil,
                    group: pane.group ?? WorkspaceRestoration.ungroupedSessionID,
                    groupLabel: pane.groupLabel,
                    kind: .editor,
                    editorTabs: pane.tabs,
                    editorActiveIndex: pane.active
                ),
                startSession: false
            )
        }
    }

    private func persistEditorPanes() {
        guard editorPanesReadCompleted else { return }
        let panes = workspace.allPaneIDs
            .compactMap { workspace.descriptor(for: $0) }
            .filter { $0.kind == .editor }
            .map {
                PersistedEditorPane(
                    tabs: $0.editorTabs,
                    active: $0.editorActiveIndex,
                    group: $0.group == WorkspaceRestoration.ungroupedSessionID ? nil : $0.group,
                    groupLabel: $0.groupLabel
                )
            }
        write(EditorPanesCodec.serialize(panes), to: SettingsKey.editorPanes)
    }
```

Hook both cycles in: add `self?.persistEditorPanes()` inside the `workspace.onPanesChanged` closure (~:281), and call `restoreEditorPanesIfNeeded()` at the same site that calls `restoreBrowserPanesIfNeeded()` (grep for its call site — it sits in the connection/restore path near `restoreWorkspaceIfNeeded`; add the editor call directly after it).

- [ ] **Step 7: Run to verify PASS** (`EditorPaneIntegrationTests`, then `./macos/build.sh test` — expect palette/outline tests to need the new row accounted for; fix any that enumerate commands exactly)

- [ ] **Step 8: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): editor panes — ⇧⌘E, toolbar, palette, sidebar and hole-tile entry points + native-only persistence" && git push
```

---

### Task 11: Open from the FILES tree — preview semantics end to end

Clicking a file in the sidebar opens it in an editor pane: preview on single click, pinned on double click, focused-not-duplicated when already open anywhere, pane created when none exists.

**Files:**
- Modify: `macos/OmniAgent/WorkspaceShell.swift` (`WorkspaceFilesTreeView.onOpenFile` ~:2012, `activate(_:)` ~:2236-2261; `WorkspaceSidebarView` chain)
- Create: `macos/OmniAgent/DoublePressDetector.swift` (tiny pure helper)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (`openFileInEditor`, most-recent-editor tracking)
- Test: `macos/OmniAgentTests/DoublePressDetectorTests.swift`, additions to `macos/OmniAgentTests/EditorPaneIntegrationTests.swift`

**Interfaces:**
- Consumes: `EditorPaneView.openFile(_:pinned:)`, `.model` (9), `newEditor(in:)` (10).
- Produces:
  - `struct DoublePressDetector { mutating func register(_ target: String, at time: TimeInterval) -> Bool }` — true when this press is the second on the same target within `NSEvent.doubleClickInterval`
  - `WorkspaceFilesTreeView.onOpenFile: ((URL, Bool) -> Void)?` (URL, pinned) — signature change is free, nothing was wired
  - `WorkspaceSidebarView.onOpenFile: ((URL, Bool) -> Void)?`
  - Controller: `func openFileInEditor(_ url: URL, pinned: Bool)`, `private var lastFocusedEditorPaneID: String?`

- [ ] **Step 1: Write the failing tests**

`DoublePressDetectorTests.swift`:

```swift
import XCTest
@testable import OmniAgent

final class DoublePressDetectorTests: XCTestCase {
    func testSecondPressWithinIntervalIsDouble() {
        var detector = DoublePressDetector(interval: 0.4)
        XCTAssertFalse(detector.register("/a", at: 10.0))
        XCTAssertTrue(detector.register("/a", at: 10.3))
        XCTAssertFalse(detector.register("/a", at: 10.5)) // a double resets
    }

    func testDifferentTargetResets() {
        var detector = DoublePressDetector(interval: 0.4)
        XCTAssertFalse(detector.register("/a", at: 10.0))
        XCTAssertFalse(detector.register("/b", at: 10.1))
    }

    func testLatePressIsSingle() {
        var detector = DoublePressDetector(interval: 0.4)
        XCTAssertFalse(detector.register("/a", at: 10.0))
        XCTAssertFalse(detector.register("/a", at: 11.0))
    }
}
```

Additions to `EditorPaneIntegrationTests.swift`:

```swift
    func testOpenFileCreatesAPaneAndAPreviewTab() throws {
        let controller = makeController()
        let file = try makeTempFile("a.swift", "x")
        controller.openFileInEditor(file, pinned: false)
        let editors = controller.workspace.allPaneIDs.filter { controller.workspace.descriptor(for: $0)?.kind == .editor }
        XCTAssertEqual(editors.count, 1)
        let pane = try XCTUnwrap(controller.workspace.editorPane(for: editors[0]))
        XCTAssertEqual(pane.model.tabs.map(\.isPinned), [false])
    }

    func testSecondOpenReusesTheSamePaneAndPreviewTab() throws {
        let controller = makeController()
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: false)
        controller.openFileInEditor(try makeTempFile("b.swift", "y"), pinned: false)
        let editors = controller.workspace.allPaneIDs.filter { controller.workspace.descriptor(for: $0)?.kind == .editor }
        XCTAssertEqual(editors.count, 1)
        XCTAssertEqual(controller.workspace.editorPane(for: editors[0])?.model.tabs.count, 1)
    }

    func testFileOpenAnywhereIsFocusedNotDuplicated() throws {
        let controller = makeController()
        let file = try makeTempFile("a.swift", "x")
        controller.openFileInEditor(file, pinned: true)
        XCTAssertTrue(controller.newEditor(in: nil)) // a second, empty editor pane, now focused
        controller.openFileInEditor(file, pinned: false)
        let panes = controller.workspace.allPaneIDs.compactMap { controller.workspace.editorPane(for: $0) }
        XCTAssertEqual(panes.map(\.model.tabs.count).sorted(), [0, 1]) // no duplicate tab appeared
    }
```

- [ ] **Step 2: Register new files, run, verify FAIL**

- [ ] **Step 3: Implement `DoublePressDetector`**

```swift
import Foundation

/// Single vs double press on tree rows, where AppKit's clickCount is out of
/// reach behind ShellRowView's own mouse handling. Pure: feed it presses,
/// it answers "was that the second press on the same target in time?".
struct DoublePressDetector {
    let interval: TimeInterval
    private var lastTarget: String?
    private var lastTime: TimeInterval = -.infinity

    init(interval: TimeInterval = NSEvent.doubleClickInterval) {
        self.interval = interval
    }

    mutating func register(_ target: String, at time: TimeInterval) -> Bool {
        let isDouble = target == lastTarget && time - lastTime <= interval
        // A recognised double resets, so a triple-click is double + single.
        lastTarget = isDouble ? nil : target
        lastTime = time
        return isDouble
    }
}
```

(`import AppKit` if `NSEvent` demands it.)

- [ ] **Step 4: Wire the tree and the chain**

`WorkspaceFilesTreeView`: change the declaration to `var onOpenFile: ((URL, Bool) -> Void)?`, add `private var doublePress = DoublePressDetector()`, and in `activate(_:)`'s file branch:

```swift
        guard node.isDirectory else {
            selected = node.url
            let pinned = doublePress.register(node.url.path, at: ProcessInfo.processInfo.systemUptime)
            onOpenFile?(node.url, pinned)
            render()
            return
        }
```

`WorkspaceSidebarView`: add `var onOpenFile: ((URL, Bool) -> Void)?` and, in init beside the `filesTree.onDiffTotals` wiring's old spot: `filesTree.onOpenFile = { [weak self] url, pinned in self?.onOpenFile?(url, pinned) }`.

Controller init (with the other `shellSidebar.*` wiring): `shellSidebar.onOpenFile = { [weak self] url, pinned in self?.openFileInEditor(url, pinned: pinned) }`.

- [ ] **Step 5: Implement `openFileInEditor` and recency tracking**

In `workspace.onFocusedPaneChanged` (~:265), before the existing three calls, record recency:

```swift
        workspace.onFocusedPaneChanged = { [weak self] paneID in
            guard let self else { return }
            if let paneID, workspace.descriptor(for: paneID)?.kind == .editor {
                lastFocusedEditorPaneID = paneID
            }
            refreshTitle()
            reloadOutline()
            refreshInspectorIfVisible(for: paneID)
        }
```

New controller methods (near `newEditor(in:)`):

```swift
    private var lastFocusedEditorPaneID: String?

    /// The pane a file opens into: the file's existing tab anywhere first
    /// (focused, never duplicated), then the most recently focused editor
    /// pane, then any editor pane, then a freshly created one.
    private func targetEditorPane() -> (id: String, pane: EditorPaneView)? {
        if let id = lastFocusedEditorPaneID, let pane = workspace.editorPane(for: id) {
            return (id, pane)
        }
        for id in workspace.allPaneIDs where workspace.descriptor(for: id)?.kind == .editor {
            if let pane = workspace.editorPane(for: id) { return (id, pane) }
        }
        guard newEditor(in: nil), let id = workspace.focusedPaneID,
              let pane = workspace.editorPane(for: id) else { return nil }
        return (id, pane)
    }

    func openFileInEditor(_ url: URL, pinned: Bool) {
        let kind = EditorFileClass.classify(url: url).tabKind
        // Already open anywhere? Focus it, per the spec's no-duplicates rule.
        for id in workspace.allPaneIDs {
            guard let pane = workspace.editorPane(for: id),
                  pane.model.index(of: url.path, kind: kind) != nil else { continue }
            workspace.focusPane(id)
            pane.openFile(url, pinned: pinned)
            return
        }
        guard let target = targetEditorPane() else { return }
        workspace.focusPane(target.id)
        target.pane.openFile(url, pinned: pinned)
    }
```

- [ ] **Step 6: Run to verify PASS** (both new classes, then full suite)

- [ ] **Step 7: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): FILES tree opens files in editor panes with VS Code preview semantics" && git push
```

---

### Task 12: Per-file diff tabs

`git show HEAD:<path>` + the working tree, handed to Monaco's diff editor. Entry points: the strip's "± Diff" toggle (already wired to `onOpenDiffRequest` in Task 9), a badge-click in the FILES tree, and a palette row.

**Files:**
- Create: `macos/OmniAgent/GitFileContent.swift`
- Modify: `macos/OmniAgent/WorkspaceFiles.swift` (make `GitStatus.runGit` and `canonicalPath` internal so the new file reuses them)
- Modify: `macos/OmniAgent/EditorPaneView.swift` (real `openDiff` body)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (real `openDiffInEditor` body; palette arm)
- Modify: `macos/OmniAgent/CommandPalette.swift` (`.openDiffForCurrentFile` row)
- Modify: `macos/OmniAgent/WorkspaceShell.swift` (badge-click on file rows)
- Test: `macos/OmniAgentTests/GitFileContentTests.swift`, additions to `EditorPaneIntegrationTests.swift`

**Interfaces:**
- Consumes: `GitStatus.repoRoot(for:)`, `GitStatus.runGit` (existing, visibility widened), `EditorWebView.showDiff` (6), `EditorPaneModel.open(path:kind:.diff)` (2).
- Produces:
  - `enum GitFileContent { static func headVersion(of url: URL, completion: @escaping (Result<String, GitFileContentError>) -> Void); static func unifiedDiff(of url: URL, completion: @escaping (String?) -> Void); static func relativePath(of url: URL, underRoot root: URL) -> String? }` — completions on main, subprocess off main
  - `enum GitFileContentError: Equatable { case notInRepository, gitFailed }` — `headVersion` maps "path not in HEAD" (untracked/added) to `.success("")`
  - `PaletteAction.openDiffForCurrentFile`
  - `WorkspaceFilesTreeView.onOpenDiff: ((URL) -> Void)?`, chained through `WorkspaceSidebarView.onOpenDiff`

- [ ] **Step 1: Write the failing tests** (`GitFileContentTests` builds a real throwaway repo — the pattern `GitStatus`'s own tests use; grep `Process` in `WorkspaceFilesTests.swift` and reuse its git-fixture helper if one exists, else write this one)

```swift
import XCTest
@testable import OmniAgent

final class GitFileContentTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q")
        try git("config", "user.email", "t@t"); try git("config", "user.name", "t")
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git("add", "."); try git("commit", "-qm", "initial")
        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    }

    private func git(_ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repo.path] + args
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testRelativePath() {
        XCTAssertEqual(GitFileContent.relativePath(of: repo.appendingPathComponent("a.txt"), underRoot: repo), "a.txt")
        XCTAssertNil(GitFileContent.relativePath(of: URL(fileURLWithPath: "/etc/hosts"), underRoot: repo))
    }

    func testHeadVersion() {
        let done = expectation(description: "head")
        GitFileContent.headVersion(of: repo.appendingPathComponent("a.txt")) { result in
            XCTAssertEqual(try? result.get(), "one\n")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    func testUntrackedDiffsAgainstEmpty() throws {
        try "new\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let done = expectation(description: "untracked")
        GitFileContent.headVersion(of: repo.appendingPathComponent("b.txt")) { result in
            XCTAssertEqual(try? result.get(), "")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    func testOutsideARepoFails() {
        let done = expectation(description: "fail")
        GitFileContent.headVersion(of: URL(fileURLWithPath: "/private/tmp/definitely-not-a-repo-\(UUID().uuidString).txt")) { result in
            XCTAssertEqual(result, .failure(.notInRepository))
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    func testUnifiedDiff() {
        let done = expectation(description: "diff")
        GitFileContent.unifiedDiff(of: repo.appendingPathComponent("a.txt")) { text in
            XCTAssertTrue(text?.contains("+two") ?? false)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
}
```

- [ ] **Step 2: Register, run, verify FAIL**

- [ ] **Step 3: Implement `GitFileContent`**

First widen visibility in `WorkspaceFiles.swift`: `private static func runGit` → `static func runGit`, `private static func canonicalPath` → `static func canonicalPath` (doc-comment why: "internal for GitFileContent, which speaks the same subprocess dialect").

```swift
import Foundation

enum GitFileContentError: Equatable {
    case notInRepository
    case gitFailed
}

/// Per-file git content for diff tabs. Same subprocess dialect as
/// `GitStatus`: `/usr/bin/env git`, `GIT_OPTIONAL_LOCKS=0`, run off the main
/// thread, answer on it. Monaco computes the diffs; this only fetches the
/// two sides (and, for the Changes tab, one already-unified diff).
enum GitFileContent {
    /// `url` repo-relative under `root`, `/`-separated — the path
    /// `git show HEAD:<path>` wants. `nil` outside the root.
    static func relativePath(of url: URL, underRoot root: URL) -> String? {
        let path = GitStatus.canonicalPath(url)
        let rootPath = GitStatus.canonicalPath(root)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The HEAD version of `url`. Untracked/newly-added (git exits non-zero
    /// with "exists on disk, but not in HEAD") is `.success("")` — a new file
    /// legitimately diffs against nothing. A missing repo is the error the
    /// caller renders as an inline message.
    static func headVersion(of url: URL, completion: @escaping (Result<String, GitFileContentError>) -> Void) {
        queue.async {
            guard let root = GitStatus.repoRoot(for: url),
                  let relative = relativePath(of: url, underRoot: root) else {
                DispatchQueue.main.async { completion(.failure(.notInRepository)) }
                return
            }
            // Not-in-HEAD is a *normal* outcome (untracked file), and runGit
            // collapses every failure to nil — so check membership first:
            // `git cat-file -e HEAD:<path>` exits 1 quietly when absent.
            let exists = GitStatus.runGit(["cat-file", "-e", "HEAD:\(relative)"], in: root) != nil
            let result: Result<String, GitFileContentError>
            if !exists {
                result = .success("")
            } else if let content = GitStatus.runGit(["show", "HEAD:\(relative)"], in: root) {
                result = .success(content)
            } else {
                result = .failure(.gitFailed)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// One file's unified diff vs HEAD — the Changes tab's lazy expansion.
    static func unifiedDiff(of url: URL, completion: @escaping (String?) -> Void) {
        queue.async {
            guard let root = GitStatus.repoRoot(for: url),
                  let relative = relativePath(of: url, underRoot: root) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let text = GitStatus.runGit(["diff", "HEAD", "--", relative], in: root)
                // An untracked file has no diff vs HEAD; show it as all-new.
                ?? GitStatus.runGit(["diff", "--no-index", "--", "/dev/null", relative], in: root)
            DispatchQueue.main.async { completion(text) }
        }
    }

    private static let queue = DispatchQueue(
        label: "ai.omni-agent.ade.editor.git-file-content",
        qos: .userInitiated
    )
}
```

(Caveat for the implementer: `git diff --no-index` exits 1 when files differ, and `runGit` treats non-zero as failure. Handle it by giving `runGit` an `acceptExitCodes: Set<Int32> = [0]` parameter with a default, passing `[0, 1]` here — a two-line change to `runGit`'s `guard`.)

- [ ] **Step 4: Give `openDiff` its real body in `EditorPaneView`**

```swift
    func openDiff(_ url: URL) {
        model.open(path: url.path, kind: .diff, asPreview: false)
        syncAll()
        showActiveContent()
        loadDiffContent(url)
    }

    private func loadDiffContent(_ url: URL) {
        GitFileContent.headVersion(of: url) { [weak self] result in
            guard let self, model.activeTab?.path == url.path, model.activeTab?.kind == .diff else { return }
            switch result {
            case let .success(original):
                let modified = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
                webHost.showDiff(path: url.path, original: original, modified: modified)
            case .failure:
                webHost.showMessage("Could not load the diff for \(url.lastPathComponent) — is this file in a git repository?")
            }
        }
    }
```

And re-load on re-activation: in `activateTab(_:)`/`showActiveContent()`, when the activated tab is `.diff`, call `loadDiffContent(URL(fileURLWithPath: tab.path))` — the spec's "diff tabs re-query on focus".

- [ ] **Step 5: Controller + palette + badge entry points**

Replace the Task 10 stub:

```swift
    /// A diff opens in the same pane resolution `openFileInEditor` uses,
    /// pinned (a diff open is always deliberate).
    func openDiffInEditor(_ url: URL) {
        for id in workspace.allPaneIDs {
            guard let pane = workspace.editorPane(for: id),
                  pane.model.index(of: url.path, kind: .diff) != nil else { continue }
            workspace.focusPane(id)
            pane.openDiff(url)
            return
        }
        guard let target = targetEditorPane() else { return }
        workspace.focusPane(target.id)
        target.pane.openDiff(url)
    }
```

`CommandPalette.swift`: `case openDiffForCurrentFile(path: String)` in `PaletteAction`; in `build`, inside the existing `if let focusedPaneID, let pane = byID[focusedPaneID]` block:

```swift
            if pane.kind == .editor, let active = pane.editorTabs.indices.contains(pane.editorActiveIndex)
                ? pane.editorTabs[pane.editorActiveIndex] : nil,
               active.kind == EditorTabKind.file.rawValue {
                commands.append(
                    PaletteCommand(
                        id: "open-diff",
                        title: "Open diff for \((active.path as NSString).lastPathComponent)",
                        detail: "vs HEAD",
                        action: .openDiffForCurrentFile(path: active.path)
                    )
                )
            }
```

Controller `run(_:)`: `case let .openDiffForCurrentFile(path): openDiffInEditor(URL(fileURLWithPath: path))`.

Badge-click (`WorkspaceShell.swift`): `WorkspaceFileRowView` stores its badge label (promote the local `let badge` to a `private let badgeField: NSTextField` property), exposes `var onBadgePress: (() -> Void)?`, and overrides mouse handling so a click landing in the badge's (inset −6 pt) frame fires it instead of the row press:

```swift
    private var badgePressArmed = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if onBadgePress != nil, !badgeField.isHidden,
           badgeField.frame.insetBy(dx: -6, dy: -6).contains(point) {
            badgePressArmed = true
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if badgePressArmed {
            badgePressArmed = false
            onBadgePress?()
            return
        }
        super.mouseUp(with: event)
    }
```

In `WorkspaceFilesTreeView.appendRows`, after `row.onPress = …`:

```swift
            if !node.isDirectory, annotate(node).gitBadge != nil {
                row.onBadgePress = { [weak self] in self?.onOpenDiff?(node.url) }
            }
```

Add `var onOpenDiff: ((URL) -> Void)?` to the tree, chain through `WorkspaceSidebarView.onOpenDiff`, and wire in the controller init: `shellSidebar.onOpenDiff = { [weak self] url in self?.openDiffInEditor(url) }`.

- [ ] **Step 6: Integration tests, run, PASS**

Add to `EditorPaneIntegrationTests`:

```swift
    func testOpenDiffCreatesAPinnedDiffTab() throws {
        let controller = makeController()
        let file = try makeTempFile("a.swift", "x")
        controller.openDiffInEditor(file)
        let pane = try XCTUnwrap(firstEditorPane(in: controller))
        XCTAssertEqual(pane.model.tabs.map(\.kind), [.diff])
        XCTAssertTrue(pane.model.tabs[0].isPinned)
    }
```

Run the three classes, then `./macos/build.sh test`.

- [ ] **Step 7: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): per-file diff tabs — git show HEAD + Monaco diff editor, badge/palette/strip entry points" && git push
```

---

### Task 13: The Changes overview tab

One tab per pane listing every changed file, hunks expanding lazily, entry points: the `+N −M` header above the FILES tree and the palette.

**Files:**
- Modify: `macos/OmniAgent/EditorPaneView.swift` (real `openChanges` body + bridge wiring)
- Modify: `macos/OmniAgent/WorkspaceShell.swift` (clickable diff header; `onOpenAllChanges` chain; `onStatusChanged` feed)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (`openChangesOverview`; `changedPaths` fan-out; palette arm)
- Modify: `macos/OmniAgent/CommandPalette.swift` (`.showAllChanges` + `hasGitRepo` parameter)
- Test: additions to `EditorPaneIntegrationTests.swift` and `macos/OmniAgentTests/CommandPaletteTests.swift` (grep for the palette's existing test file name and use that)

**Interfaces:**
- Consumes: `GitStatus` (existing), `GitFileContent.unifiedDiff` (12), `EditorWebView.showChanges/appendFileDiff` (6).
- Produces:
  - `WorkspaceFilesTreeView.onOpenAllChanges: (() -> Void)?` and `onStatusChanged: ((GitStatus?) -> Void)?` (fires whenever `setRoot`'s async load lands)
  - `WorkspaceSidebarView.onOpenAllChanges`, `onGitStatusChanged`
  - Controller: `func openChangesOverview()`
  - `PaletteAction.showAllChanges`; `CommandPaletteModel.build(…, hasGitRepo: Bool = false)` appends the row only when true
  - `EditorPaneView.setGitStatus(_ status: GitStatus?)` — updates `changedPaths` AND refreshes an open changes tab

- [ ] **Step 1: Write the failing tests**

```swift
    // EditorPaneIntegrationTests
    func testOpenChangesOverviewCreatesSingletonTab() {
        let controller = makeController()
        controller.openChangesOverview()
        controller.openChangesOverview()
        let pane = firstEditorPane(in: controller)
        XCTAssertEqual(pane?.model.tabs.filter { $0.kind == .changes }.count, 1)
    }
```

```swift
    // palette tests
    func testShowAllChangesOnlyInARepo() {
        let without = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0)
        XCTAssertFalse(without.contains { $0.action == .showAllChanges })
        let with = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0, hasGitRepo: true)
        XCTAssertTrue(with.contains { $0.action == .showAllChanges })
    }
```

- [ ] **Step 2: Run, verify FAIL**

- [ ] **Step 3: Implement — EditorPaneView side**

```swift
    private var gitStatus: GitStatus?

    func setGitStatus(_ status: GitStatus?) {
        gitStatus = status
        changedPaths = Set(status.map { snapshot in
            snapshot.badges.keys.map { snapshot.root.appendingPathComponent($0).path }
        } ?? [])
        if model.activeTab?.kind == .changes { renderChanges() }
    }

    func openChanges() {
        model.open(path: "", kind: .changes, asPreview: false)
        syncAll()
        showActiveContent()
        renderChanges()
    }

    /// Files sorted by path with their single-letter badge — exactly the
    /// FILES tree's letters, so the two surfaces can never disagree.
    private func renderChanges() {
        guard let status = gitStatus else {
            webHost.showMessage("Not a git repository — nothing to show.")
            return
        }
        let files = status.badges
            .sorted { $0.key < $1.key }
            .map { (path: $0.key, badge: Self.badgeLetter($0.value)) }
        webHost.showChanges(files: files)
    }

    static func badgeLetter(_ badge: GitBadge) -> String {
        switch badge {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }
```

Wire the two bridge events in `wireBridge()` (replacing the Task 9 comment):

```swift
        webHost.onRequestFileDiff = { [weak self] relative in
            guard let self, let root = gitStatus?.root else { return }
            let url = root.appendingPathComponent(relative)
            GitFileContent.unifiedDiff(of: url) { [weak self] text in
                self?.webHost.appendFileDiff(path: relative, text: text ?? "Could not load this file's diff.")
            }
        }
        webHost.onChangesOpen = { [weak self] relative, asDiff in
            guard let self, let root = gitStatus?.root else { return }
            let url = root.appendingPathComponent(relative)
            if asDiff { openDiff(url) } else { onOpenFileRequest?(url) }
        }
```

Add `var onOpenFileRequest: ((URL) -> Void)?` beside `onOpenDiffRequest`; the controller wires it to `openFileInEditor(url, pinned: true)` in Task 10's wiring branch (add it there now).

Refresh on focus regained: in `showActiveContent()`'s `.changes` arm, call `renderChanges()` — together with `setGitStatus` this covers both spec refresh triggers.

- [ ] **Step 4: Implement — sidebar and controller side**

`WorkspaceFilesTreeView`: add `var onOpenAllChanges: (() -> Void)?` and `var onStatusChanged: ((GitStatus?) -> Void)?`. In `init`, make the header's diff label clickable:

```swift
        diffField.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(diffHeaderPressed)))
```

with `@objc private func diffHeaderPressed() { onOpenAllChanges?() }`. In `setRoot`'s completion (after `self.onDiffTotals?(…)`): `self.onStatusChanged?(status)`.

`WorkspaceSidebarView`: `var onOpenAllChanges: (() -> Void)?`, `var onGitStatusChanged: ((GitStatus?) -> Void)?`, wired from the tree in init.

Controller init:

```swift
        shellSidebar.onOpenAllChanges = { [weak self] in self?.openChangesOverview() }
        shellSidebar.onGitStatusChanged = { [weak self] status in
            guard let self else { return }
            latestGitStatus = status
            for id in workspace.allPaneIDs {
                workspace.editorPane(for: id)?.setGitStatus(status)
            }
        }
```

with `private var latestGitStatus: GitStatus?` — and in Task 10's editor wiring branch, seed a fresh pane: `editor.setGitStatus(latestGitStatus)` (add it there).

```swift
    func openChangesOverview() {
        guard let target = targetEditorPane() else { return }
        workspace.focusPane(target.id)
        target.pane.setGitStatus(latestGitStatus)
        target.pane.openChanges()
    }
```

`CommandPalette.swift`: `case showAllChanges`; `build` gains `hasGitRepo: Bool = false` and appends after the new-editor row:

```swift
        if hasGitRepo {
            commands.append(
                PaletteCommand(id: "show-all-changes", title: "Show all changes", detail: "git", action: .showAllChanges)
            )
        }
```

Controller: pass `hasGitRepo: latestGitStatus != nil` at the palette build call site (~:995-1008); `run` arm: `case .showAllChanges: openChangesOverview()`.

- [ ] **Step 5: Run to verify PASS** (classes, then full suite)

- [ ] **Step 6: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): Changes overview tab — repo-wide diff list with lazy hunks" && git push
```

---

### Task 14: Tab drag-and-drop — reorder, cross-pane move, edge-insert, hole drop

Tabs drag on a new pasteboard type. Within a strip: live reorder. Onto another editor pane: center moves the tab in, edges insert a new pane adjacent in grid order (the grid-faithful "edge split"). Onto a hole tile: new pane there. Terminal/browser panes and the 8-pane cap refuse.

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (drag type; `addPane(_:inserting:of:)`; container drop handling; hole-tile drop; drop-routing closures)
- Modify: `macos/OmniAgent/EditorPaneView.swift` (drag source + strip drop destination)
- Modify: `macos/OmniAgent/EditorTabStripView.swift` (drop registration + indicator)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (the one drop-mutation broker)
- Create: `macos/OmniAgent/EditorTabDrag.swift` (payload + zone math, pure)
- Test: `macos/OmniAgentTests/EditorTabDragTests.swift`, additions to `PaneGridTests.swift`-style coverage via `PaneWorkspaceViewTests.swift`, additions to `EditorPaneIntegrationTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `EditorPaneModel.move/close/insert` (2), `EditorTabStripView.insertionIndex/showDropIndicator/itemFrames` (7), `PaneGrid.build` (existing).
- Produces:
  - `struct EditorTabDragPayload: Equatable, Codable { var paneID: String; var index: Int }` with `func pasteboardString() -> String?` and `static func decode(_ string: String?) -> EditorTabDragPayload?`
  - `enum EditorTabDropZone: Equatable { case center, insertBefore, insertAfter; static func zone(at point: CGPoint, in bounds: CGRect) -> EditorTabDropZone }` (outer 25% left/top → `.insertBefore`; right/bottom → `.insertAfter`; the view is flipped — top is minY)
  - `PaneWorkspaceView.editorTabDragType` (`"digital.bruno.omniagent.editor-tab"`)
  - `enum PaneInsertPosition { case before, after }`; `PaneWorkspaceView.addPane(_ descriptor:, inserting: PaneInsertPosition, of targetID: String) -> Bool`
  - `PaneWorkspaceView.onEditorTabDropOnPane: ((EditorTabDragPayload, String, EditorTabDropZone) -> Void)?`, `onEditorTabDropOnHole: ((EditorTabDragPayload) -> Void)?`
  - `EditorPaneView.onTabDroppedInStrip: ((EditorTabDragPayload, Int) -> Void)?`, `func removeTabForTransfer(at index: Int) -> EditorTab?`, `func receiveTransferredTab(_ tab: EditorTab, at index: Int)`
  - Controller: `func handleEditorTabDrop(_ payload: EditorTabDragPayload, intoPane targetID: String, at insertIndex: Int)` and `func handleEditorTabEdgeDrop(_ payload: EditorTabDragPayload, target targetID: String, zone: EditorTabDropZone)` and `func handleEditorTabHoleDrop(_ payload: EditorTabDragPayload)`

- [ ] **Step 1: Write the failing pure tests** (`EditorTabDragTests.swift`)

```swift
import XCTest
@testable import OmniAgent

final class EditorTabDragTests: XCTestCase {
    func testPayloadRoundTrip() {
        let payload = EditorTabDragPayload(paneID: "p1", index: 2)
        XCTAssertEqual(EditorTabDragPayload.decode(payload.pasteboardString()), payload)
        XCTAssertNil(EditorTabDragPayload.decode(nil))
        XCTAssertNil(EditorTabDragPayload.decode("junk"))
    }

    func testZones() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 200, y: 100), in: bounds), .center)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 50, y: 100), in: bounds), .insertBefore)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 350, y: 100), in: bounds), .insertAfter)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 200, y: 20), in: bounds), .insertBefore)  // top (flipped)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 200, y: 180), in: bounds), .insertAfter)  // bottom
        // Corners: the horizontal edge wins (wider band).
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 10, y: 10), in: bounds), .insertBefore)
    }
}
```

And the grid-insertion test in `PaneWorkspaceViewTests.swift`:

```swift
    func testInsertingAPaneAdjacentInGridOrder() {
        let workspace = PaneWorkspaceView { _ in StubPaneContent() }
        for id in ["a", "b", "c"] {
            XCTAssertTrue(workspace.addPane(PaneDescriptor(sessionID: id, group: "g", kind: .editor)))
        }
        XCTAssertTrue(workspace.addPane(
            PaneDescriptor(sessionID: "x", group: "g", kind: .editor),
            inserting: .after, of: "a"
        ))
        XCTAssertEqual(workspace.paneIDs, ["a", "x", "b", "c"])
        XCTAssertTrue(workspace.addPane(
            PaneDescriptor(sessionID: "y", group: "g", kind: .editor),
            inserting: .before, of: "a"
        ))
        XCTAssertEqual(workspace.paneIDs, ["y", "a", "x", "b", "c"])
    }
```

- [ ] **Step 2: Register, run, verify FAIL**

- [ ] **Step 3: Implement the pure layer** (`EditorTabDrag.swift`)

```swift
import Foundation

/// What travels on the pasteboard when a tab is dragged: which pane it left
/// and which index it held. The tab itself stays in the source model until
/// the drop commits — a cancelled drag must change nothing.
struct EditorTabDragPayload: Equatable, Codable {
    var paneID: String
    var index: Int

    func pasteboardString() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ string: String?) -> EditorTabDragPayload? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EditorTabDragPayload.self, from: data)
    }
}

/// Where inside a pane a tab drop lands. The outer 25% bands are the
/// grid-faithful "edge split": left/top insert the new pane before the
/// target in grid order, right/bottom after; the ladder re-lays out.
/// `bounds` comes from a flipped view — top is minY.
enum EditorTabDropZone: Equatable {
    case center
    case insertBefore
    case insertAfter

    static func zone(at point: CGPoint, in bounds: CGRect) -> EditorTabDropZone {
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        if x < 0.25 { return .insertBefore }
        if x > 0.75 { return .insertAfter }
        if y < 0.25 { return .insertBefore }
        if y > 0.75 { return .insertAfter }
        return .center
    }
}
```

- [ ] **Step 4: Implement the grid insertion** (`PaneWorkspaceView`)

```swift
enum PaneInsertPosition { case before, after }
```

Refactor `addPane(_:)`'s body into a private core that takes the grid-shaping step as a closure, keeping the public method's behaviour byte-identical (`PaneGrid.synced` append, with its 2→3 special case):

```swift
    @discardableResult
    func addPane(_ descriptor: PaneDescriptor) -> Bool {
        addPane(descriptor) { existing, grid in
            PaneGrid.synced(grid, desiredIDs: existing + [descriptor.sessionID])
        }
    }

    /// Edge-drop insertion: the new pane lands adjacent to `targetID` in grid
    /// order and the ladder re-lays out. `PaneGrid.build` (not `synced`) on
    /// purpose — order is the whole point here, and fractions reset exactly
    /// as they do for any rung change.
    @discardableResult
    func addPane(_ descriptor: PaneDescriptor, inserting position: PaneInsertPosition, of targetID: String) -> Bool {
        guard descriptors[targetID]?.group == descriptor.group else { return false }
        return addPane(descriptor) { existing, _ in
            var ids = existing
            let anchor = ids.firstIndex(of: targetID) ?? max(0, ids.count - 1)
            ids.insert(descriptor.sessionID, at: position == .before ? anchor : anchor + 1)
            return PaneGrid.build(ids)
        }
    }

    private func addPane(
        _ descriptor: PaneDescriptor,
        shapeGrid: ([String], PaneGrid?) -> PaneGrid?
    ) -> Bool {
        // …exactly the existing body, with the one `grids[group] = PaneGrid.synced(…)`
        // line replaced by:
        //     grids[group] = shapeGrid(grids[group]?.paneIDs() ?? [], grids[group])
    }
```

- [ ] **Step 5: Implement source + destinations**

**Drag type** (beside `paneDragType`): `static let editorTabDragType = NSPasteboard.PasteboardType("digital.bruno.omniagent.editor-tab")`.

**Source** (`EditorPaneView`): wire `strip.onBeginDrag` (closing Task 9's comment):

```swift
        strip.onBeginDrag = { [weak self] index, event in self?.beginTabDrag(index: index, event: event) }
```

```swift
    /// The workspace pane id this view is mounted under — set by the
    /// controller's wiring branch (Task 10; add `editor.paneID = sessionID`
    /// there now).
    var paneID: String = ""

    private func beginTabDrag(index: Int, event: NSEvent) {
        guard model.tabs.indices.contains(index),
              let payload = EditorTabDragPayload(paneID: paneID, index: index).pasteboardString()
        else { return }
        let item = NSPasteboardItem()
        item.setString(payload, forType: PaneWorkspaceView.editorTabDragType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let frame = strip.itemFrames.indices.contains(index) ? strip.itemFrames[index] : .zero
        dragItem.setDraggingFrame(strip.convert(frame, to: self), contents: nil)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }
```

with `extension EditorPaneView: NSDraggingSource` returning `.move` within the application (copy `PaneContainerView`'s implementation). Dragging a tab also pins it (spec) — call `model.pin(at: index); syncAll()` in `beginTabDrag`.

**Strip destination** (`EditorTabStripView`): `registerForDraggedTypes([PaneWorkspaceView.editorTabDragType])` in init; implement `draggingEntered/draggingUpdated` (compute `insertionIndex(forX:tabFrames: itemFrames)` from the drag location converted into the strip, `showDropIndicator(at:)`, return `.move`), `draggingExited` (clear), and `performDragOperation`:

```swift
    var onTabDrop: ((EditorTabDragPayload, Int) -> Void)?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearDropIndicator()
        guard let payload = EditorTabDragPayload.decode(
            sender.draggingPasteboard.string(forType: PaneWorkspaceView.editorTabDragType)
        ) else { return false }
        let x = convert(sender.draggingLocation, from: nil).x
        onTabDrop?(payload, Self.insertionIndex(forX: x, tabFrames: itemFrames))
        return true
    }
```

`EditorPaneView` forwards: `strip.onTabDrop = { [weak self] payload, index in self?.onTabDroppedInStrip?(payload, index) }` plus the two transfer primitives:

```swift
    func removeTabForTransfer(at index: Int) -> EditorTab? {
        let removed = model.close(at: index)
        if let removed, removed.kind == .file {
            webHost.closeModel(path: removed.path)
            encodings.removeValue(forKey: removed.path)
            modificationDates.removeValue(forKey: removed.path)
        }
        syncAll()
        showActiveContent()
        if model.tabs.isEmpty { onLastTabClosed?() }
        return removed
    }

    func receiveTransferredTab(_ tab: EditorTab, at index: Int) {
        var arrived = tab
        arrived.isDirty = false // dirty content cannot travel between web views (v1); the move prompts first — see the controller broker
        model.insert(arrived, at: index)
        if arrived.kind == .file { loadFileTab(URL(fileURLWithPath: arrived.path), classified: EditorFileClass.classify(url: URL(fileURLWithPath: arrived.path))) }
        if arrived.kind == .diff { loadDiffContent(URL(fileURLWithPath: arrived.path)) }
        if arrived.kind == .changes { renderChanges() }
        syncAll()
        showActiveContent()
    }
```

**Container destination** (`PaneContainerView`): add `editorTabDragType` to `registerForDraggedTypes` in init; extend `draggingEntered/performDragOperation` — when the pasteboard carries an editor tab: accept only if `workspace?.descriptor(for: paneID)?.kind == .editor` AND (zone is `.center` OR the grid has room), else `[]` (the no-drop cursor the spec demands on terminals/browsers); on perform, route:

```swift
        if let payload = EditorTabDragPayload.decode(
            sender.draggingPasteboard.string(forType: PaneWorkspaceView.editorTabDragType)
        ) {
            let zone = EditorTabDropZone.zone(at: convert(sender.draggingLocation, from: nil), in: bounds)
            workspace?.onEditorTabDropOnPane?(payload, paneID, zone)
            isDropTarget = false
            return true
        }
```

(Zone-aware highlight is a polish item; the full-pane `dropHighlight` is acceptable for v1 — note it in the commit message.)

**Hole destination** (`PaneHolePlaceholderView`): register the type, `draggingEntered` returns `.move` when the payload decodes, `performDragOperation` calls a new `var onDropEditorTab: ((EditorTabDragPayload) -> Void)?`, wired in `syncHolePlaceholders`: `placeholder.onDropEditorTab = { [weak self] payload in self?.onEditorTabDropOnHole?(payload) }`.

- [ ] **Step 6: Implement the controller broker**

All drops mutate through one method set so the rules live in one place. In the controller (wire the closures in init beside the other `workspace.*` closures):

```swift
        workspace.onEditorTabDropOnPane = { [weak self] payload, targetID, zone in
            guard let self else { return }
            if zone == .center {
                handleEditorTabDrop(payload, intoPane: targetID, at: Int.max)
            } else {
                handleEditorTabEdgeDrop(payload, target: targetID, zone: zone)
            }
        }
        workspace.onEditorTabDropOnHole = { [weak self] payload in self?.handleEditorTabHoleDrop(payload) }
```

Strip drops route per pane in Task 10's wiring branch (add there): `editor.onTabDroppedInStrip = { [weak self] payload, index in self?.handleEditorTabDrop(payload, intoPane: sessionID, at: index) }`.

```swift
    /// Reorder within one pane, or move a tab between editor panes. A dirty
    /// tab is saved (or the move cancelled) before it travels — buffers
    /// cannot cross web views in v1.
    func handleEditorTabDrop(_ payload: EditorTabDragPayload, intoPane targetID: String, at insertIndex: Int) {
        guard let source = workspace.editorPane(for: payload.paneID),
              let target = workspace.editorPane(for: targetID) else { return }
        if payload.paneID == targetID {
            source.moveTab(from: payload.index, to: insertIndex)
            return
        }
        let transfer = { [weak self] in
            guard let self, let tab = source.removeTabForTransfer(at: payload.index) else { return }
            target.receiveTransferredTab(tab, at: insertIndex == Int.max ? target.model.tabs.count : insertIndex)
            workspace.focusPane(targetID)
        }
        guard source.model.tabs.indices.contains(payload.index), source.model.tabs[payload.index].isDirty else {
            transfer()
            return
        }
        let name = (source.model.tabs[payload.index].path as NSString).lastPathComponent
        source.confirmSave(name) { decision in
            switch decision {
            case .cancel: break
            case .discard: transfer()
            case .save: source.save(at: payload.index) { if $0 { transfer() } }
            }
        }
    }

    func handleEditorTabEdgeDrop(_ payload: EditorTabDragPayload, target targetID: String, zone: EditorTabDropZone) {
        guard zone != .center,
              let source = workspace.editorPane(for: payload.paneID),
              let targetGroup = workspace.descriptor(for: targetID)?.group,
              workspace.paneCount(inGroup: targetGroup) < PaneGrid.maxPanes,
              source.model.tabs.indices.contains(payload.index)
        else { return }
        // Same save-first rule as a cross-pane move.
        let insert = { [weak self] in
            guard let self, let tab = source.removeTabForTransfer(at: payload.index) else { return }
            let template = WorkspaceRestoration.bootstrapPane()
            let descriptor = PaneDescriptor(
                sessionID: template.sessionID,
                group: targetGroup,
                groupLabel: workspace.descriptor(for: targetID)?.groupLabel,
                project: workspace.descriptor(for: targetID)?.project ?? "",
                kind: .editor,
                editorTabs: [PersistedEditorTab(path: tab.path, kind: tab.kind.rawValue, pinned: true)],
                editorActiveIndex: 0
            )
            guard workspace.addPane(
                descriptor,
                inserting: zone == .insertBefore ? .before : .after,
                of: targetID
            ) else { return }
            // The surface factory built the pane from the descriptor's tabs;
            // run the controller wiring the ordinary addPane path would have.
            wireEditorPane(descriptor.sessionID)
        }
        deliverAfterSavePrompt(source: source, index: payload.index, then: insert)
    }

    func handleEditorTabHoleDrop(_ payload: EditorTabDragPayload) {
        guard let source = workspace.editorPane(for: payload.paneID),
              source.model.tabs.indices.contains(payload.index),
              let group = workspace.activeGroup,
              workspace.paneCount(inGroup: group) < PaneGrid.maxPanes
        else { return }
        let drop = { [weak self] in
            guard let self, let tab = source.removeTabForTransfer(at: payload.index) else { return }
            let template = WorkspaceRestoration.bootstrapPane()
            let descriptor = PaneDescriptor(
                sessionID: template.sessionID,
                group: group,
                kind: .editor,
                editorTabs: [PersistedEditorTab(path: tab.path, kind: tab.kind.rawValue, pinned: true)],
                editorActiveIndex: 0
            )
            // Plain append: the grid's hole is the next fill slot, so the new
            // pane lands exactly where the drop happened.
            guard workspace.addPane(descriptor) else { return }
            wireEditorPane(descriptor.sessionID)
        }
        deliverAfterSavePrompt(source: source, index: payload.index, then: drop)
    }
```

(`workspace.activeGroup` is `private(set)` and readable; the hole tile only ever exists in the active session's grid, so the active group is the right home for the new pane. `save(at:completion:)` on `EditorPaneView` must be **internal**, not private — `deliverAfterSavePrompt` calls it; adjust Task 9's body accordingly when you get here.)

Two refactors this forces, do them as part of this step: (a) extract the Task 10 `else if let editor = …` wiring branch into `private func wireEditorPane(_ sessionID: String)` and call it from both `addPane(_:startSession:)` and the drop paths; (b) extract the dirty-save-then prompt into `private func deliverAfterSavePrompt(source: EditorPaneView, index: Int, then: @escaping () -> Void)` used by all three handlers. Also add the tiny `EditorPaneView.moveTab(from:to:)` (calls `model.move`, `syncAll()`).

Note the direct `PaneDescriptor` construction: edge/hole drops bypass `addPane(_:startSession:)` (which appends — wrong shape for an insert), so they call `workspace.addPane(…, inserting:…)` directly and then `wireEditorPane`. `updateDescriptor`-driven persistence still fires through `onPanesChanged`.

- [ ] **Step 7: Integration tests + full suite**

Add to `EditorPaneIntegrationTests`:

```swift
    func testCenterDropMovesTabBetweenPanesAndClosesEmptySource() throws {
        let controller = makeController()
        let file = try makeTempFile("a.swift", "x")
        controller.openFileInEditor(file, pinned: true)
        let sourceID = try XCTUnwrap(controller.workspace.allPaneIDs.last)
        XCTAssertTrue(controller.newEditor(in: nil))
        let targetID = try XCTUnwrap(controller.workspace.focusedPaneID)
        controller.handleEditorTabDrop(
            EditorTabDragPayload(paneID: sourceID, index: 0),
            intoPane: targetID, at: 0
        )
        XCTAssertNil(controller.workspace.editorPane(for: sourceID)) // source closed with its last tab
        XCTAssertEqual(controller.workspace.editorPane(for: targetID)?.model.tabs.map(\.path), [file.path])
    }

    func testEdgeDropInsertsANewPaneAdjacent() throws {
        let controller = makeController()
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: true)
        controller.openFileInEditor(try makeTempFile("b.swift", "y"), pinned: true) // 2 tabs, 1 pane
        let paneID = try XCTUnwrap(controller.workspace.focusedPaneID)
        let before = controller.workspace.paneIDs.count
        controller.handleEditorTabEdgeDrop(
            EditorTabDragPayload(paneID: paneID, index: 1),
            target: paneID, zone: .insertAfter
        )
        XCTAssertEqual(controller.workspace.paneIDs.count, before + 1)
    }
```

Run everything: `./macos/build.sh test`.

- [ ] **Step 8: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): editor tab drag-and-drop — reorder, cross-pane move, grid edge-insert, hole drop" && git push
```

---

### Task 15: External changes, renderer-crash recovery, quit/close prompts

The spec's §7 hardening: mtime conflict detection, WKWebView crash restore from snapshots, and the dirty prompts at pane close, window close, and app quit.

**Files:**
- Modify: `macos/OmniAgent/EditorPaneView.swift`
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (`closePane` guard; `windowShouldClose`)
- Modify: `macos/OmniAgent/AppDelegate.swift` (`applicationShouldTerminate`)
- Test: additions to `EditorPaneViewTests.swift` and `EditorPaneIntegrationTests.swift`

**Interfaces:**
- Consumes: everything already built.
- Produces:
  - `EditorPaneView.checkExternalChanges()` — called from `focus()` and `activateTab`
  - `var confirmConflict: ((String, @escaping (_ takeDisk: Bool) -> Void) -> Void)` seam (default NSAlert "Keep Mine" / "Take Disk")
  - Controller: `func promptDirtyEditorTabs(completion: @escaping (Bool) -> Void)` (true = proceed) — used by `closePane`, `windowShouldClose`, and `AppDelegate.applicationShouldTerminate`

- [ ] **Step 1: Write the failing tests**

```swift
    // EditorPaneViewTests
    func testCleanBufferSilentlyReloadsOnExternalChange() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        // mtime granularity: force a distinct date.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        pane.checkExternalChanges()
        let reloaded = expectation(description: "reloaded")
        pane.webHost.requestContent(path: url.path) { content in
            XCTAssertEqual(content, "v2"); reloaded.fulfill()
        }
        wait(for: [reloaded], timeout: 10)
    }

    func testDirtyBufferConflictPrompts() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        pane.modelForTesting { $0.setDirty(true, at: 0) }
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        var asked = false
        pane.confirmConflict = { _, decide in asked = true; decide(false) } // keep mine
        pane.checkExternalChanges()
        XCTAssertTrue(asked)
        XCTAssertTrue(pane.model.tabs[0].isDirty)
    }

    func testCrashRestoreReplaysDirtySnapshot() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        pane.injectSnapshotForTesting(path: url.path, content: "edited-but-unsaved")
        pane.modelForTesting { $0.setDirty(true, at: 0) }
        pane.simulateRendererCrashForTesting()
        waitUntilReady(pane) // the page reloads and re-arms
        let restored = expectation(description: "restored")
        pane.webHost.requestContent(path: url.path) { content in
            XCTAssertEqual(content, "edited-but-unsaved"); restored.fulfill()
        }
        wait(for: [restored], timeout: 15)
        XCTAssertTrue(pane.model.tabs[0].isDirty)
    }
```

```swift
    // EditorPaneIntegrationTests
    func testCloseDirtyEditorPaneAsksFirst() throws {
        let controller = makeController()
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: true)
        let id = try XCTUnwrap(controller.workspace.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspace.editorPane(for: id))
        pane.modelForTesting { $0.setDirty(true, at: 0) }
        pane.confirmSave = { _, decide in decide(.cancel) }
        controller.closePane(nil)
        XCTAssertNotNil(controller.workspace.editorPane(for: id)) // cancel kept it
        pane.confirmSave = { _, decide in decide(.discard) }
        controller.closePane(nil)
        XCTAssertNil(controller.workspace.editorPane(for: id))
    }
```

Add the small test hooks: `waitUntilReady(_:)` helper (expectation on `onReadyForTesting`), `injectSnapshotForTesting(path:content:)` (writes `dirtySnapshots`), `simulateRendererCrashForTesting()` (calls the same routine `webViewWebContentProcessDidTerminate` triggers — expose the pane's crash handler as an internal method).

- [ ] **Step 2: Run, verify FAIL**

- [ ] **Step 3: Implement — external changes**

```swift
    var confirmConflict: ((String, @escaping (_ takeDisk: Bool) -> Void) -> Void) = { name, decide in
        let alert = NSAlert()
        alert.messageText = "\(name) changed on disk"
        alert.informativeText = "You have unsaved edits, and the file was modified outside the editor (probably by an agent)."
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Take Disk")
        decide(alert.runModal() == .alertSecondButtonReturn)
    }

    /// Spec §2: clean buffer + newer mtime on focus → silent reload; dirty →
    /// keep-mine / take-disk. Deleted-on-disk marks the title, keeps the
    /// buffer (save recreates).
    func checkExternalChanges() {
        for (index, tab) in model.tabs.enumerated() where tab.kind == .file {
            let path = tab.path
            guard let recorded = modificationDates[path] else { continue }
            guard FileManager.default.fileExists(atPath: path) else {
                deletedPaths.insert(path)   // strip renders "name (deleted)"
                syncAll()
                continue
            }
            deletedPaths.remove(path)
            let current = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? recorded
            guard current > recorded else { continue }
            modificationDates[path] = current
            let reload = { [weak self] in
                guard let self else { return }
                let encoding = encodings[path] ?? .utf8
                if let content = try? String(contentsOfFile: path, encoding: encoding) {
                    webHost.setContent(path: path, content: content)
                    model.setDirty(false, at: index)
                    dirtySnapshots.removeValue(forKey: path)
                    syncAll()
                }
            }
            if tab.isDirty {
                confirmConflict((path as NSString).lastPathComponent) { takeDisk in
                    if takeDisk { reload() }
                    // Keep Mine: buffer stays dirty; the recorded mtime above
                    // already advanced, so the prompt does not repeat until
                    // the disk changes again.
                }
            } else {
                reload()
            }
        }
    }
```

Add `private var deletedPaths: Set<String> = []`, thread it into the strip title (`syncAll` appends `" (deleted)"` for members — extend `EditorTabStripView.render` with a `deletedPaths: Set<String> = []` parameter), and call `checkExternalChanges()` at the top of `focus()` and inside `activateTab(_:)`.

- [ ] **Step 4: Implement — crash restore**

Wire the Task 9 comment:

```swift
        webHost.onCrash = { [weak self] in self?.restoreAfterRendererCrash() }
```

```swift
    /// The renderer died. `EditorWebView` reloads the page; when Monaco
    /// answers ready again, re-open every text-file model — dirty ones from
    /// their last ~2 s snapshot (spec §7: unsaved edits survive), clean ones
    /// from disk — and re-show the active tab.
    func restoreAfterRendererCrash() {
        let previousReady = webHost.onReady
        webHost.onReady = { [weak self] in
            guard let self else { return }
            webHost.onReady = previousReady
            previousReady?()
            for (index, tab) in model.tabs.enumerated() where tab.kind == .file {
                let url = URL(fileURLWithPath: tab.path)
                guard case .text(let readOnly) = EditorFileClass.classify(url: url) else { continue }
                let encoding = encodings[tab.path] ?? .utf8
                let diskContent = (try? String(contentsOfFile: tab.path, encoding: encoding)) ?? ""
                let content = tab.isDirty ? (dirtySnapshots[tab.path] ?? diskContent) : diskContent
                webHost.openModel(path: tab.path, content: content, readOnly: readOnly)
                if tab.isDirty { model.setDirty(true, at: index) } // survives the reload
            }
            syncAll()
            showActiveContent()
        }
    }
```

`simulateRendererCrashForTesting()` calls `webHost.webViewWebContentProcessDidTerminate(webHost.webView)`.

- [ ] **Step 5: Implement — the three prompts**

Controller: guard `closePane(_ sender:)` — before the existing `workspace.closePane(focused)` line:

```swift
        if let editor = workspace.editorPane(for: focused), editor.hasDirtyTabs {
            editor.closeAllTabsAfterConfirmation { [weak self] proceed in
                guard proceed, let self else { return }
                lastStatus.removeValue(forKey: focused)
                workspace.closePane(focused)
            }
            return
        }
```

Add the shared walk:

```swift
    /// Walks every editor pane's dirty tabs with save prompts. `true` means
    /// everything resolved (saved or discarded); `false` means the user
    /// cancelled and the close/quit must stop.
    func promptDirtyEditorTabs(completion: @escaping (Bool) -> Void) {
        let editors = workspace.allPaneIDs.compactMap { workspace.editorPane(for: $0) }.filter(\.hasDirtyTabs)
        func step(_ remaining: [EditorPaneView]) {
            guard let next = remaining.first else { completion(true); return }
            next.closeAllTabsAfterConfirmation { proceed in
                proceed ? step(Array(remaining.dropFirst())) : completion(false)
            }
        }
        step(editors)
    }
```

`windowShouldClose` (controller is already the window's delegate):

```swift
    private var closeApproved = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeApproved else { return true }
        let dirty = workspace.allPaneIDs.compactMap { workspace.editorPane(for: $0) }.contains(where: \.hasDirtyTabs)
        guard dirty else { return true }
        promptDirtyEditorTabs { [weak self] proceed in
            guard proceed, let self else { return }
            closeApproved = true
            sender.close()
        }
        return false
    }
```

(If the controller already implements other `NSWindowDelegate` methods, add this beside them; if `windowShouldClose` exists, merge the guard into it.)

`AppDelegate`:

```swift
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controllers = NSApp.windows.compactMap { $0.windowController as? WorkspaceWindowController }
        let dirty = controllers.filter { controller in
            controller.workspace.allPaneIDs.contains {
                controller.workspace.editorPane(for: $0)?.hasDirtyTabs == true
            }
        }
        guard !dirty.isEmpty else { return .terminateNow }
        func step(_ remaining: [WorkspaceWindowController]) {
            guard let next = remaining.first else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            next.promptDirtyEditorTabs { proceed in
                proceed ? step(Array(remaining.dropFirst())) : NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        step(dirty)
        return .terminateLater
    }
```

(Check `workspace` is reachable from AppDelegate — it is `let workspace` internal on the controller; if it is `private`, widen to `internal` with a doc comment.)

- [ ] **Step 6: Run to verify PASS** (`EditorPaneViewTests`, `EditorPaneIntegrationTests`, then full suite)

- [ ] **Step 7: Commit and push**

```bash
git add -A macos && git commit -m "feat(macos): editor hardening — external-change conflicts, renderer-crash restore, dirty prompts on close/quit" && git push
```

---

### Task 16: Final verification and packaged build

**Files:**
- Modify: none planned — this task only verifies, packages, and reconciles docs.

- [ ] **Step 1: Spec sweep**

Re-read `docs/superpowers/specs/2026-08-18-editor-pane-design.md` section by section against the code. For each spec claim, name the file/test that delivers it; fix anything missing ON A TASK, not ad hoc (if a real gap surfaces, add a task to this plan, implement it TDD, commit separately).

- [ ] **Step 2: Full test suite**

Run: `./macos/build.sh test`
Expected: PASS, zero skips in the new classes.

- [ ] **Step 3: Manual smoke in the real app**

```bash
scripts/rebuild-app.sh --no-notarize
```

(This quits the running app AND restarts the PTY daemon — expected, standing decision.) Then in the installed app, walk the spec's happy paths: click a file (preview italic), double-click (pins), edit (dirty dot + Save), ⌘S inside Monaco, ⌘F find, drag a tab between panes, drag to an edge (new pane), click a git badge (diff), click the `+N −M` header (Changes), open an image and a PDF, quit with a dirty tab (prompt).

- [ ] **Step 4: Update the repo instructions**

Add one line to `.github/copilot-instructions.md`'s architecture section mentioning the editor pane (Monaco-in-WKWebView exception, `editor_panes_native` row), then run `./scripts/sync-instructions.sh` to regenerate the agent files. Commit.

- [ ] **Step 5: Final commit, push**

```bash
git add -A && git commit -m "docs: editor pane — sync instructions after feature completion" && git push
```

Report completion against the spec, listing any deliberate deviations discovered during implementation.

---

## Plan self-review notes (already applied)

- **Spec coverage:** §1→Tasks 2/9/11; §2→Tasks 6/9/15; §3→Tasks 12/13; §4→Tasks 7/14; §5→Tasks 3/10; §6→Tasks 1/10/11; §7→Tasks 5/9/15; §8→every task's test steps. Future-work items (LSP, hot exit, FSEvents) are deliberately absent.
- **Known intentional gaps (v1, per spec):** zone-aware drop highlight is full-pane; dirty buffers save-or-discard before crossing panes (buffers don't travel between web views); minimap off.
- **Type consistency:** interfaces blocks are authoritative; when a body sketch and an interfaces block disagree, the interfaces block wins.






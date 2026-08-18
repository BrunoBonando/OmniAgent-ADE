import Foundation

/// What one editor tab shows.
enum EditorTabKind: String, Equatable, CaseIterable {
    case file  // an editable Monaco model
    case diff  // one file's working tree vs HEAD, read-only
    case changes  // the repo-wide overview; at most one per pane
    case media  // native image/PDF preview, read-only, never dirty
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
        // A preview tab that is *dirty* is never recycled. `setDirty` already
        // pins an edited buffer, so this second guard is belt-and-braces: no
        // path through this type can silently drop unsaved work.
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

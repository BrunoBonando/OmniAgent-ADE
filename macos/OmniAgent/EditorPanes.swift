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

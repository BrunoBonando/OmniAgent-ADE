import Foundation

/// One browser pane's last loaded URL — the native-only mirror of
/// `PersistedTab`, stored under `SettingsKey.browserPanes` instead of the
/// shared `layout` row. No `id`/`project`/`engine`/`cwd`: a browser pane's
/// identity does not need to survive relaunch (nothing reattaches to it,
/// there is no PTY to reconnect), only its URL, group and group label do —
/// see the spec's "last-URL only, native-only" persistence design.
struct PersistedBrowserPane: Equatable {
    var url: String
    var group: String?
    var groupLabel: String?
}

/// Serializes/deserializes the `browser_panes_native` settings row —
/// `{"panes": PersistedBrowserPane[]}`. Mirrors `PersistedLayoutCodec`'s
/// shape exactly: `JSONSerialization` rather than `Codable` (a throwing
/// decode of one malformed array element would fail the whole array), the
/// same `.sortedKeys` write, the same per-field repair semantics.
enum BrowserPanesCodec {
    static func serialize(_ panes: [PersistedBrowserPane]) -> String {
        let payload: [String: Any] = ["panes": panes.map(encodedPane)]
        guard
            JSONSerialization.isValidJSONObject(payload),
            // `.sortedKeys` for exactly `PersistedLayoutCodec.serialize`'s
            // reason: `WorkspaceWindowController.write(_:to:)` dedupes a
            // settings write by comparing this string to the last one
            // written, and `Dictionary` iteration order is not stable
            // across two dictionaries holding the same pairs.
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"panes":[]}"#
        }
        return json
    }

    private static func encodedPane(_ pane: PersistedBrowserPane) -> [String: Any] {
        var dict: [String: Any] = ["url": pane.url]
        if let group = pane.group, SessionIdentifier.isValid(group) {
            dict["group"] = group
        }
        if let groupLabel = pane.groupLabel {
            let trimmed = groupLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                dict["groupLabel"] = trimmed
            }
        }
        return dict
    }

    /// Never throws — a corrupt/missing row restores to "no browser panes"
    /// rather than crashing the app on launch. Per-entry repair, exactly
    /// `PersistedLayoutCodec.deserialize`'s shape:
    ///
    /// - `url` missing, not a string, or empty drops the WHOLE entry (a
    ///   browser pane with nothing to load is not worth restoring);
    /// - an invalid `group` drops just that field (the pane restores
    ///   ungrouped instead of vanishing);
    /// - a `groupLabel` that is not a non-empty string after trimming drops
    ///   just that field.
    static func deserialize(_ raw: String?) -> [PersistedBrowserPane] {
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

    private static func decodePane(_ element: Any) -> PersistedBrowserPane? {
        guard
            let dict = element as? [String: Any],
            let url = dict["url"] as? String,
            !url.isEmpty
        else {
            return nil
        }

        var group: String?
        if let groupRaw = dict["group"] as? String, SessionIdentifier.isValid(groupRaw) {
            group = groupRaw
        }

        var groupLabel: String?
        if let groupLabelRaw = dict["groupLabel"] {
            let trimmed = ((groupLabelRaw as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            groupLabel = trimmed.isEmpty ? nil : trimmed
        }

        return PersistedBrowserPane(url: url, group: group, groupLabel: groupLabel)
    }
}

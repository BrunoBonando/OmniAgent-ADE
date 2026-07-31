import Foundation

/// The engines a terminal pane can run — the native mirror of
/// `ui/src/state/agents.ts`'s `AVAILABLE_AGENTS` (order matters: it is the
/// oracle for a future native "cycle engine" action, same as
/// `ui/src/state/sessions.ts`'s `cycleEngine`).
enum Engine: String, Codable, CaseIterable, Equatable {
    case claude
    case codex
    case shell
    case copilot
    case antigravity
}

/// A pane's terminal color theme — the native mirror of
/// `ui/src/lib/terminalThemes.ts`'s `TERMINAL_THEME_IDS`.
enum TerminalThemeId: String, Codable, CaseIterable, Equatable {
    case standard
    case matrix
    case amber
}

/// Session ids (and session/pane-group ids, which share the same shape) —
/// the native mirror of `ui/src/state/sessions.ts`'s `isValidSessionId`/
/// `MAX_SESSION_ID_LEN`. An id becomes both a transcript filename and a tmux
/// target on the Rust side (`src-tauri/src/sessions.rs`'s
/// `is_valid_session_id`), so this is a validation gate, not a sanitizer —
/// checked byte-for-byte (`[A-Za-z0-9_-]`, 1...96), not with a
/// Unicode-aware `Character.isLetter`/`isNumber`, which would wrongly admit
/// accented letters the Rust/JS regex rejects.
enum SessionIdentifier {
    static let maxLength = 96

    static func isValid(_ value: String) -> Bool {
        guard (1...maxLength).contains(value.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (0x41...0x5A).contains(byte) // A-Z
                || (0x61...0x7A).contains(byte) // a-z
                || (0x30...0x39).contains(byte) // 0-9
                || byte == 0x5F // _
                || byte == 0x2D // -
        }
    }
}

/// The shape persisted under `LAYOUT_SETTING_KEY` (`"layout"`) — the exact
/// mirror of `ui/src/state/sessions.ts`'s `PersistedTab`. The web/Tauri app
/// reads/writes the same `settings` row (same `brain.db`), so every field
/// name and optionality here must match byte-for-byte; `PersistedLayoutCodec`
/// is the only thing allowed to construct/serialize this from raw JSON.
struct PersistedTab: Equatable {
    var project: String
    var engine: Engine
    var cwd: String
    var id: String?
    var label: String?
    var themeId: TerminalThemeId?
    var group: String?
    var groupLabel: String?

    init(
        project: String,
        engine: Engine,
        cwd: String,
        id: String? = nil,
        label: String? = nil,
        themeId: TerminalThemeId? = nil,
        group: String? = nil,
        groupLabel: String? = nil
    ) {
        self.project = project
        self.engine = engine
        self.cwd = cwd
        self.id = id
        self.label = label
        self.themeId = themeId
        self.group = group
        self.groupLabel = groupLabel
    }
}

/// `{tabs: PersistedTab[]}` — the top-level JSON object stored under the
/// `"layout"` settings key.
struct Layout: Equatable {
    var tabs: [PersistedTab]
}

/// Serializes/deserializes the `"layout"` settings row — the native port of
/// `ui/src/state/sessions.ts`'s `serializeLayout`/`deserializeLayout`,
/// including `deserialize`'s per-field repair semantics (see its own doc).
///
/// Built on `JSONSerialization` rather than `Codable` on purpose:
/// `deserialize` must tolerate individually malformed fields (a bad
/// `themeId`, a duplicate `id`, ...) without losing the whole pane, which a
/// strict `Codable`/`JSONDecoder` parse of `[PersistedTab]` cannot express —
/// a throwing decode of one array element fails the entire array.
enum PersistedLayoutCodec {
    static func serialize(_ tabs: [PersistedTab]) -> String {
        let payload: [String: Any] = ["tabs": tabs.map(encodedTab)]
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"tabs":[]}"#
        }
        return json
    }

    private static func encodedTab(_ tab: PersistedTab) -> [String: Any] {
        var dict: [String: Any] = [
            "project": tab.project,
            "engine": tab.engine.rawValue,
            "cwd": tab.cwd,
        ]
        // An id the backend would reject as a `restoreId` is not worth
        // storing — it can only produce a failed restore next launch.
        if let id = tab.id, SessionIdentifier.isValid(id) {
            dict["id"] = id
        }
        if let label = tab.label, !label.isEmpty {
            dict["label"] = label
        }
        if let themeId = tab.themeId {
            dict["themeId"] = themeId.rawValue
        }
        if let group = tab.group, SessionIdentifier.isValid(group) {
            dict["group"] = group
        }
        if let groupLabel = tab.groupLabel {
            let trimmed = groupLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                dict["groupLabel"] = trimmed
            }
        }
        return dict
    }

    /// Never throws — a corrupt/missing layout restores to "no tabs" rather
    /// than crashing the app on launch. Two kinds of fields are handled
    /// differently, exactly mirroring `ui/src/state/sessions.ts`'s
    /// `deserializeLayout`:
    ///
    /// - `project`/`cwd` missing, `engine` unrecognized, or `label` present
    ///   but not a string, drops the WHOLE tab (a fresh session next launch
    ///   is the least-bad failure mode for a truly malformed entry);
    /// - an invalid `themeId` (e.g. a preset removed in a later version)
    ///   drops just that field — the pane falls back to the default theme
    ///   rather than losing the session it was attached to;
    /// - an invalid *or duplicated* `id` drops just that field, so the tab
    ///   restores as a fresh session instead of disappearing (the backend
    ///   rejects a `restoreId` naming a session already live in this app);
    /// - an invalid `group` drops just that field (the pane restores,
    ///   ungrouped, instead of vanishing);
    /// - a `groupLabel` that is not a non-empty string after trimming drops
    ///   just that field (falls back to a derived default name).
    static func deserialize(_ raw: String?) -> [PersistedTab] {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let rawTabs = parsed["tabs"] as? [Any]
        else {
            return []
        }

        var seenIDs = Set<String>()
        return rawTabs.compactMap { decodeTab($0, seenIDs: &seenIDs) }
    }

    private static func decodeTab(_ element: Any, seenIDs: inout Set<String>) -> PersistedTab? {
        guard
            let dict = element as? [String: Any],
            let project = dict["project"] as? String,
            let cwd = dict["cwd"] as? String,
            let engineRaw = dict["engine"] as? String,
            let engine = Engine(rawValue: engineRaw)
        else {
            return nil
        }
        // `label` is optional, but a present-and-wrong-typed value costs the
        // whole tab — same hard-filter treatment `engine` gets above.
        if let labelValue = dict["label"], !(labelValue is String) {
            return nil
        }

        var themeId: TerminalThemeId?
        if let themeRaw = dict["themeId"] as? String {
            themeId = TerminalThemeId(rawValue: themeRaw)
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

        var id: String?
        if let idRaw = dict["id"] as? String, SessionIdentifier.isValid(idRaw), !seenIDs.contains(idRaw) {
            id = idRaw
            seenIDs.insert(idRaw)
        }

        return PersistedTab(
            project: project,
            engine: engine,
            cwd: cwd,
            id: id,
            label: dict["label"] as? String,
            themeId: themeId,
            group: group,
            groupLabel: groupLabel
        )
    }
}

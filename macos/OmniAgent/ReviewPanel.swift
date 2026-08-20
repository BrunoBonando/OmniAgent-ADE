import Foundation

// The review panel's per-session state — the 2026-08-20 redesign's §5
// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md):
// which tabs are open, which is active, whether the panel is showing, its
// width, and the Files tab's little preferences. Persisted in the
// native-only `review_panel_native` settings row keyed by session group id
// — its own row for `browser_panes_native`'s reason: fields on the shared
// `layout` row would be stripped by the web build's next rewrite.

/// The views the panel can show. Raw values are the persisted names in the
/// `review_panel_native` row, so renaming a case is a migration.
enum ReviewPanelTab: String, CaseIterable, Equatable {
    case changes
    case files
    case browser
    case insights

    var title: String {
        switch self {
        case .changes: return "Changes"
        case .files: return "Files"
        case .browser: return "Browser"
        case .insights: return "Insights"
        }
    }

    /// The tab's SF Symbol — the toolbar's vocabulary.
    var symbolName: String {
        switch self {
        case .changes: return "plus.forwardslash.minus"
        case .files: return "folder"
        case .browser: return "globe"
        case .insights: return "chart.bar.xaxis"
        }
    }

    /// What a session starts with — the spec's "Changes and Files are the
    /// default tab set". Browser and Insights are what the "+" menu offers
    /// from here.
    static let defaultTabs: [ReviewPanelTab] = [.changes, .files]
}

/// One session's panel state. `openFile`, `treePosition` and `showHidden`
/// belong to tabs later tasks build (Files); declared now because they are
/// part of the row's shape and the codec must carry them through a rewrite
/// rather than strip them.
struct ReviewPanelSessionState: Equatable {
    var open = false
    /// `ReviewPanelTab.rawValue`s, in tab-bar order. Strings rather than the
    /// enum so a tab from a future build survives in the row (dropped on
    /// read, kept on write-through of what this build holds).
    var tabs: [String] = ReviewPanelTab.defaultTabs.map(\.rawValue)
    var activeTab: String = ReviewPanelTab.changes.rawValue
    var width: Double?
    var openFile: String?
    /// `"left"` / `"right"` — the Files tab's tree-position preference.
    var treePosition: String?
    var showHidden: Bool?

    /// Indistinguishable from a session that never touched the panel — not
    /// worth a row entry (`SessionMeta.isEmpty`'s reasoning).
    var isDefault: Bool { self == ReviewPanelSessionState() }
}

/// Serializes/deserializes the `review_panel_native` settings row:
/// `{"sessions":{"<group id>":{open,tabs,activeTab,width?,openFile?,treePosition?,showHidden?}}}`.
/// Mirrors `SessionMetaCodec` exactly: `JSONSerialization` (not `Codable`),
/// the same `.sortedKeys` write-dedupe requirement, per-field repair, never
/// throws.
enum ReviewPanelStateCodec {
    static let treePositions = ["left", "right"]

    static func serialize(_ states: [String: ReviewPanelSessionState]) -> String {
        var entries: [String: Any] = [:]
        for (group, state) in states where SessionIdentifier.isValid(group) && !state.isDefault {
            let tabs = normalizedTabs(state.tabs)
            var dict: [String: Any] = [
                "open": state.open,
                "tabs": tabs,
                "activeTab": tabs.contains(state.activeTab) ? state.activeTab : (tabs.first ?? ""),
            ]
            if let width = state.width, width.isFinite, width > 0 { dict["width"] = width }
            if let file = state.openFile, !file.isEmpty { dict["openFile"] = file }
            if let position = state.treePosition, treePositions.contains(position) {
                dict["treePosition"] = position
            }
            if let hidden = state.showHidden { dict["showHidden"] = hidden }
            entries[group] = dict
        }
        let payload: [String: Any] = ["sessions": entries]
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"sessions":{}}"#
        }
        return json
    }

    /// Repair rules:
    /// - an entry that is not a dictionary, or keyed by an id that could not
    ///   survive the daemon protocol, is dropped;
    /// - an unknown or duplicate tab name is dropped (first occurrence wins);
    /// - an `activeTab` not among the surviving tabs falls back to the first
    ///   of them;
    /// - a non-positive or non-numeric `width` drops just the width;
    /// - a `treePosition` that is not `"left"`/`"right"` drops just that field;
    /// - an entry that repairs down to the default state is dropped — an
    ///   entry indistinguishable from "never touched" is a claim, not a fact.
    static func deserialize(_ raw: String?) -> [String: ReviewPanelSessionState] {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let entries = parsed["sessions"] as? [String: Any]
        else {
            return [:]
        }
        var states: [String: ReviewPanelSessionState] = [:]
        for (group, element) in entries {
            guard SessionIdentifier.isValid(group), let dict = element as? [String: Any] else {
                continue
            }
            var state = ReviewPanelSessionState()
            state.open = (dict["open"] as? Bool) ?? false
            state.tabs = normalizedTabs((dict["tabs"] as? [Any])?.compactMap { $0 as? String } ?? [])
            let active = (dict["activeTab"] as? String) ?? ""
            state.activeTab = state.tabs.contains(active) ? active : (state.tabs.first ?? "")
            if let width = numeric(dict["width"]), width.isFinite, width > 0 {
                state.width = width
            }
            if let file = dict["openFile"] as? String, !file.isEmpty {
                state.openFile = file
            }
            if let position = dict["treePosition"] as? String, treePositions.contains(position) {
                state.treePosition = position
            }
            if let hidden = dict["showHidden"] as? Bool {
                state.showHidden = hidden
            }
            if !state.isDefault { states[group] = state }
        }
        return states
    }

    private static func normalizedTabs(_ tabs: [String]) -> [String] {
        var seen: Set<String> = []
        return tabs.filter { ReviewPanelTab(rawValue: $0) != nil && seen.insert($0).inserted }
    }

    /// `JSONSerialization` hands back `NSNumber` in several bridged guises,
    /// and a JSON `true` is one of them — a bool is not a width.
    private static func numeric(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.doubleValue
    }
}

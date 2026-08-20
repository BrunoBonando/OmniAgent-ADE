import AppKit

// Per-workspace customization — the 2026-08-20 redesign's §3
// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md): the
// Customize… dialog's display name and folder colour, persisted in the
// native-only `workspace_customizations_native` settings row keyed by
// workspace path, plus the tiny codec for the `closed_workspaces` row the
// Remove-workspace path writes — that one shared with the web build, so its
// shape is `ui/src/state/closedWorkspaces.ts`'s bare array of ids.

/// The dialog's eight swatches, in the order they render. Persisted by raw
/// value, so the cases' strings are a contract with past launches — and the
/// tints reuse colours the design already owns (`ShellPalette`, the avatar
/// gradients) rather than introducing a ninth family.
enum WorkspaceColor: String, CaseIterable {
    case gray
    case green
    case blue
    case purple
    case pink
    case red
    case orange
    case gold

    var tint: NSColor {
        switch self {
        case .gray: return NSColor(srgbRed: 154 / 255, green: 154 / 255, blue: 164 / 255, alpha: 1)
        case .green: return ShellPalette.green
        case .blue: return ShellPalette.blue
        case .purple: return NSColor(srgbRed: 182 / 255, green: 150 / 255, blue: 242 / 255, alpha: 1)
        case .pink: return NSColor(srgbRed: 237 / 255, green: 129 / 255, blue: 195 / 255, alpha: 1)
        case .red: return ShellPalette.red
        case .orange: return NSColor(srgbRed: 255 / 255, green: 155 / 255, blue: 115 / 255, alpha: 1)
        case .gold: return ShellPalette.amber
        }
    }
}

/// One workspace's customization. Both fields optional: either alone is a
/// meaningful customization, and neither means "not customized" — which the
/// codec refuses to store.
struct WorkspaceCustomization: Equatable {
    var displayName: String?
    var color: WorkspaceColor?

    var isEmpty: Bool { displayName == nil && color == nil }
}

/// Serializes/deserializes the `workspace_customizations_native` settings
/// row: `{"workspaces":{"<path>":{"name"?,"color"?}}}`. Mirrors
/// `EditorPanesCodec` exactly: `JSONSerialization` (not `Codable`), the same
/// `.sortedKeys` write-dedupe requirement, per-field repair, never throws.
enum WorkspaceCustomizationsCodec {
    static func serialize(_ customizations: [String: WorkspaceCustomization]) -> String {
        var entries: [String: Any] = [:]
        for (path, customization) in customizations where !customization.isEmpty {
            var dict: [String: Any] = [:]
            if let name = trimmed(customization.displayName) { dict["name"] = name }
            if let color = customization.color { dict["color"] = color.rawValue }
            entries[path] = dict
        }
        let payload: [String: Any] = ["workspaces": entries]
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"workspaces":{}}"#
        }
        return json
    }

    /// Repair rules:
    /// - an entry that is not a dictionary is dropped;
    /// - a blank `name` drops just the name;
    /// - a `color` this build does not know drops just the colour;
    /// - an entry with neither field left is dropped — an empty
    ///   customization is a claim, not a fact.
    static func deserialize(_ raw: String?) -> [String: WorkspaceCustomization] {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let entries = parsed["workspaces"] as? [String: Any]
        else {
            return [:]
        }
        var customizations: [String: WorkspaceCustomization] = [:]
        for (path, element) in entries {
            guard let dict = element as? [String: Any] else { continue }
            let customization = WorkspaceCustomization(
                displayName: trimmed(dict["name"] as? String),
                color: (dict["color"] as? String).flatMap(WorkspaceColor.init(rawValue:))
            )
            if !customization.isEmpty {
                customizations[path] = customization
            }
        }
        return customizations
    }

    private static func trimmed(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The `closed_workspaces` row, shape-for-shape with
/// `ui/src/state/closedWorkspaces.ts`'s serialize/deserialize pair: a bare
/// JSON array of workspace ids. Sorted on the way out so the same set always
/// writes the same bytes (the write-dedupe compares strings); the web build
/// does not care about the order.
enum ClosedWorkspacesCodec {
    static func serialize(_ ids: Set<String>) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: ids.sorted()),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }

    /// Never throws: a corrupt row means "nothing is closed", which shows
    /// the user more than they asked for rather than hiding work — the web
    /// codec's own rule. Non-string members are skipped, not fatal.
    static func deserialize(_ raw: String?) -> Set<String> {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else {
            return []
        }
        return Set(parsed.compactMap { $0 as? String })
    }
}

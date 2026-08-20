import Foundation

// Per-session metadata — the 2026-08-20 redesign's §3
// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md): the
// session context menu's pin and nested-session facts, persisted in the
// native-only `session_meta_native` settings row keyed by session group id.
// Deliberately its own row rather than fields on the shared `layout` row,
// `browser_panes_native`'s reasoning: the web codec strips fields it does
// not know on every rewrite.

/// One session group's metadata. Both fields optional in spirit: either
/// alone is a fact worth storing, and neither means "nothing to say" — which
/// the codec refuses to store.
struct SessionMeta: Equatable {
    var pinned = false
    /// The session this one was created nested under — `Create nested
    /// session` records the right-clicked group here.
    var parent: String?

    var isEmpty: Bool { !pinned && parent == nil }
}

extension SessionMeta {
    /// Drops entries for groups no live pane carries any more, and clears a
    /// `parent` pointing at one — an entry left empty by that clearing is
    /// dropped too. Run against the restored layout, so a session deleted on
    /// another launch does not leave its pin or its children's indent behind.
    static func pruned(
        _ meta: [String: SessionMeta],
        live: Set<String>
    ) -> [String: SessionMeta] {
        var out: [String: SessionMeta] = [:]
        for (group, entry) in meta {
            guard live.contains(group) else { continue }
            var repaired = entry
            if let parent = repaired.parent, !live.contains(parent) {
                repaired.parent = nil
            }
            if !repaired.isEmpty { out[group] = repaired }
        }
        return out
    }

    /// Project mode's session order for one workspace: pinned sessions
    /// first (stable on both sides of the split), and every nested session
    /// directly under its top-level ancestor, marked `nested`.
    ///
    /// Depth is clamped to 1 by construction — a chain deeper than one
    /// level flattens under its root rather than stepping further right,
    /// which is also what keeps a corrupt row honest: a parent not in this
    /// list costs the indent, not the session, and a parent cycle resolves
    /// to whichever member the walk ends on, with anything still unplaced
    /// appended top-level rather than vanishing.
    static func arrange(
        _ sessions: [SessionGroupNode],
        meta: [String: SessionMeta]
    ) -> [(session: SessionGroupNode, nested: Bool)] {
        guard !meta.isEmpty else { return sessions.map { ($0, false) } }
        let ids = Set(sessions.map(\.id))

        func parentID(of id: String) -> String? {
            guard let parent = meta[id]?.parent, parent != id, ids.contains(parent) else {
                return nil
            }
            return parent
        }

        /// The top-level ancestor — the walk stops at a session with no
        /// (usable) parent, or on the first repeat in a cycle.
        func rootID(of id: String) -> String {
            var current = id
            var seen: Set<String> = [current]
            while let parent = parentID(of: current), !seen.contains(parent) {
                current = parent
                seen.insert(parent)
            }
            return current
        }

        var topLevel: [SessionGroupNode] = []
        var childrenByRoot: [String: [SessionGroupNode]] = [:]
        for session in sessions {
            let root = rootID(of: session.id)
            if root == session.id {
                topLevel.append(session)
            } else {
                childrenByRoot[root, default: []].append(session)
            }
        }

        func pinnedFirst(_ list: [SessionGroupNode]) -> [SessionGroupNode] {
            list.filter { meta[$0.id]?.pinned == true }
                + list.filter { meta[$0.id]?.pinned != true }
        }

        var out: [(session: SessionGroupNode, nested: Bool)] = []
        var placed = Set<String>()
        for session in pinnedFirst(topLevel) {
            out.append((session, false))
            placed.insert(session.id)
            for child in pinnedFirst(childrenByRoot[session.id] ?? []) {
                out.append((child, true))
                placed.insert(child.id)
            }
        }
        // A cycle can leave members with no top-level root at all; they
        // still render, un-nested, in their incoming order.
        for session in sessions where !placed.contains(session.id) {
            out.append((session, false))
        }
        return out
    }
}

/// Serializes/deserializes the `session_meta_native` settings row:
/// `{"sessions":{"<group id>":{"pinned"?,"parent"?}}}`. Mirrors
/// `EditorPanesCodec` exactly: `JSONSerialization` (not `Codable`), the same
/// `.sortedKeys` write-dedupe requirement, per-field repair, never throws.
enum SessionMetaCodec {
    static func serialize(_ meta: [String: SessionMeta]) -> String {
        var entries: [String: Any] = [:]
        for (group, entry) in meta where SessionIdentifier.isValid(group) {
            var dict: [String: Any] = [:]
            if entry.pinned { dict["pinned"] = true }
            if let parent = entry.parent, SessionIdentifier.isValid(parent), parent != group {
                dict["parent"] = parent
            }
            if !dict.isEmpty { entries[group] = dict }
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
    /// - a non-bool `pinned` reads as unpinned;
    /// - an invalid or self-referencing `parent` drops just the parent;
    /// - an entry with neither field left is dropped — an empty entry is a
    ///   claim, not a fact.
    static func deserialize(_ raw: String?) -> [String: SessionMeta] {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let entries = parsed["sessions"] as? [String: Any]
        else {
            return [:]
        }
        var meta: [String: SessionMeta] = [:]
        for (group, element) in entries {
            guard SessionIdentifier.isValid(group), let dict = element as? [String: Any] else {
                continue
            }
            var parent: String?
            if let raw = dict["parent"] as? String, SessionIdentifier.isValid(raw), raw != group {
                parent = raw
            }
            let entry = SessionMeta(pinned: (dict["pinned"] as? Bool) ?? false, parent: parent)
            if !entry.isEmpty { meta[group] = entry }
        }
        return meta
    }
}

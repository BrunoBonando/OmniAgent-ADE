import Foundation

/// The `remote_control` settings row: what this Mac offers to remote
/// viewers, and the *only* thing a remote connection is allowed to touch —
/// the remote-session-control spec's §2 ("Per-workspace enablement and the
/// projection",
/// docs/superpowers/specs/2026-08-30-remote-session-control-design.md).
///
/// ```json
/// {"workspaces":[{"id":"…","name":"…",
///   "sessions":[{"id":"…","title":"…","engine":"claude","group":"…"}]}]}
/// ```
///
/// The shape is a contract with `crates/omniagent-pty-daemon`'s `relay.rs`,
/// which deserializes this row on every authorization decision (a SQLite
/// point read, no cache) and refuses any `Attach`/`Input` naming a session
/// that is not in it. So the keys here are snake_case-exact and the type is
/// a pure function of the layout: the row is rewritten on every toggle *and*
/// on every layout persist, so a session added to an enabled workspace shows
/// up remotely without anyone remembering to refresh, and a workspace that
/// stops being enabled stops being reachable in the same instant.
///
/// Deliberately not `PersistedLayoutCodec`'s `JSONSerialization` shape:
/// nothing here has to survive a half-malformed field the way a user's
/// layout does. A projection that will not decode is a projection of
/// nothing, which is the safe answer — it denies rather than admits.
enum RemoteControlProjection {
    /// One daemon session (one PTY, one pane) — `PersistedTab.id` is the
    /// daemon's own session id, which is what a viewer will `Attach` with.
    struct Session: Codable, Equatable {
        let id: String
        let title: String
        let engine: String
        let group: String?
    }

    /// One workspace: `PersistedTab.project`, the same string the sidebar's
    /// `WorkspaceTreeEntry.id` and `workspaceContextMenu(for:)` carry.
    struct Workspace: Codable, Equatable {
        let id: String
        let name: String
        let sessions: [Session]
    }

    struct Payload: Codable, Equatable {
        let workspaces: [Workspace]
    }

    /// Enabled workspaces only, in the order their first session appears in
    /// `tabs` — the sidebar's order. An enabled workspace with nothing
    /// running does not appear at all: there is nothing to attach to, and
    /// the daemon's "keep the control channel open iff ≥ 1 workspace" rule
    /// then costs nothing while the Mac is idle.
    static func build(
        tabs: [PersistedTab],
        enabledWorkspaceIDs: Set<String>,
        workspaceLabels: [String: String]
    ) -> Payload {
        var order: [String] = []
        var sessions: [String: [Session]] = [:]
        for tab in tabs {
            guard enabledWorkspaceIDs.contains(tab.project) else { continue }
            // A pane with no session id has no daemon session behind it yet,
            // so there is nothing a viewer could attach to.
            guard let id = tab.id, !id.isEmpty else { continue }
            if sessions[tab.project] == nil {
                sessions[tab.project] = []
                order.append(tab.project)
            }
            sessions[tab.project]?.append(
                Session(
                    id: id,
                    title: tab.label ?? tab.groupLabel ?? id,
                    engine: tab.engine.rawValue,
                    group: tab.group
                )
            )
        }
        return Payload(
            workspaces: order.map { project in
                Workspace(
                    id: project,
                    // The name a remote viewer prints for this workspace is
                    // the one the local sidebar prints — the Customize…
                    // display name when there is one, else the brain's
                    // label, else the path.
                    name: workspaceLabels[project] ?? SessionOutline.projectLabel(project, labels: workspaceLabels),
                    sessions: sessions[project] ?? []
                )
            }
        )
    }

    static func encode(_ payload: Payload) -> String {
        let encoder = JSONEncoder()
        // `.sortedKeys` for `WorkspaceWindowController.write(_:to:)`'s
        // change detection (see `PersistedLayoutCodec.serialize`), and
        // `.withoutEscapingSlashes` because every workspace id is a path:
        // `"\/Users\/…"` is the same JSON but unreadable in the row a human
        // debugging this will `sqlite3` out by hand.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard
            let data = try? encoder.encode(payload),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"workspaces":[]}"#
        }
        return json
    }

    /// Never throws: an unreadable row means "nothing is shared", which is
    /// the safe direction for a row that is an authorization list.
    static func decode(_ raw: String?) -> Payload {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return Payload(workspaces: [])
        }
        return payload
    }

    /// The `remote_control_workspaces` row — a plain JSON array of ids,
    /// `ClosedWorkspacesCodec`'s shape for the same reason: sorted so the
    /// same set always serializes to the same bytes.
    static func encodeEnabled(_ ids: Set<String>) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ids.sorted(),
                options: [.withoutEscapingSlashes]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }

    static func decodeEnabled(_ raw: String?) -> Set<String> {
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

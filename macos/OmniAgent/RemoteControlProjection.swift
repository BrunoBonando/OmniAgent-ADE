import AppKit

/// The `remote_control` settings row: what this Mac offers to remote
/// viewers, and the *only* thing a remote connection is allowed to touch —
/// the remote-session-control spec's §2 ("Per-workspace enablement and the
/// projection",
/// docs/superpowers/specs/2026-08-30-remote-session-control-design.md), in
/// the schema v2 shape phase 2 defines ("The viewer's sidebar mirrors the
/// host",
/// docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md).
///
/// ```json
/// {"version":2,
///  "workspaces":[{"id":"…","name":"…","tint":"#RRGGBB|null","order":0,
///    "sessions":[{"id":"…","label":"…","order":0,
///      "panes":[{"id":"…","title":"…","engine":"claude","kind":"terminal","order":0}]}]}]}
/// ```
///
/// Phase 1 flattened every *pane* into a "session" whose title fell back to
/// the session group's label, so three panes of one session arrived on the
/// viewer as "Session 1" three times and the structure differed from the
/// host's sidebar. v2 carries the host's real tree — workspace → session →
/// panes — derived from the same `SessionOutline.group` the local sidebar
/// renders, which is what makes the two sidebars structurally identical
/// rather than merely similar.
///
/// **The attachable id is the pane id**, as in phase 1: `sessions[].id` is
/// the host's session-*group* id, and `crates/omniagent-pty-daemon`'s
/// `remote_session_ids` walks `workspaces[].sessions[].panes[].id`. The
/// daemon deserializes this row on every authorization decision (a SQLite
/// point read, no cache) and refuses any `Attach`/`Input` naming a pane that
/// is not in it. So the keys here are exact, and the type is a pure function
/// of the layout: the row is rewritten on every toggle *and* on every layout
/// persist, so a session added to an enabled workspace shows up remotely
/// without anyone remembering to refresh, and a workspace that stops being
/// enabled stops being reachable in the same instant.
///
/// Deliberately not `PersistedLayoutCodec`'s `JSONSerialization` shape:
/// nothing here has to survive a half-malformed field the way a user's
/// layout does. A projection that will not decode is a projection of
/// nothing, which is the safe answer — it denies rather than admits.
enum RemoteControlProjection {
    /// The schema this build writes. Bumped only alongside both readers (the
    /// daemon's `remote_session_ids` and `decode` below).
    static let currentVersion = 2

    /// One pane — a daemon session id a viewer can `Attach` with, plus what
    /// the row prints. Only `.terminal` panes are attachable; the others are
    /// carried for structural fidelity so the viewer's tree has the same
    /// shape as the host's.
    struct Pane: Codable, Equatable {
        let id: String
        let title: String
        let engine: String
        let kind: String
        let order: Int
    }

    /// One session group — `SessionGroupNode.id`, the host's own grouping,
    /// with its panes inside it in the host's order.
    struct Session: Codable, Equatable {
        let id: String
        let label: String
        let order: Int
        let panes: [Pane]
    }

    /// One workspace: `PaneDescriptor.project`, the same string the sidebar's
    /// `WorkspaceTreeEntry.id` and `workspaceContextMenu(for:)` carry.
    struct Workspace: Codable, Equatable {
        let id: String
        let name: String
        /// The host's folder tint as `#RRGGBB`, `nil` when the workspace has
        /// none — so the colours match on both Macs.
        let tint: String?
        let order: Int
        let sessions: [Session]
    }

    struct Payload: Codable, Equatable {
        let version: Int
        let workspaces: [Workspace]

        /// `version` defaulted so every construction site says only what it
        /// means; a payload this app builds is always the current schema.
        init(version: Int = RemoteControlProjection.currentVersion, workspaces: [Workspace]) {
            self.version = version
            self.workspaces = workspaces
        }
    }

    /// The host's tree, projected: enabled workspaces only — every one of
    /// them, in the order their first pane appears (the sidebar's order),
    /// with the enabled ones that have nothing running after them, sorted so
    /// the row is stable.
    ///
    /// Grouped by `SessionOutline.group` — the *same* function the host
    /// sidebar uses — which is what guarantees the two structures cannot
    /// drift: one session with three panes is one row with three pane dots on
    /// both Macs, named the same thing, in the same order.
    ///
    /// An enabled workspace with no sessions is listed with an empty
    /// `sessions` array rather than dropped. That is load-bearing: the daemon
    /// keeps its control channel open *iff* the projection lists ≥ 1
    /// workspace, so dropping the empty ones would close the tunnel the
    /// instant a user enabled Remote Control on a workspace that happens to
    /// have nothing running — the machine would go OFFLINE seconds after
    /// being turned on, which is the opposite of what the toggle says.
    static func build(
        panes: [PaneDescriptor],
        enabledWorkspaceIDs: Set<String>,
        workspaceLabels: [String: String],
        tints: [String: NSColor]
    ) -> Payload {
        // A pane with no session id has no daemon session behind it yet, so
        // there is nothing a viewer could attach to. A pane this Mac is
        // itself *viewing* is another machine's session and is never
        // re-shared (`localPaneDescriptors` already filters those out at the
        // call site; this is the same rule stated where the trust boundary
        // lives).
        let shared = panes.filter { pane in
            enabledWorkspaceIDs.contains(pane.project) && !pane.sessionID.isEmpty && !pane.isRemote
        }
        var descriptors: [String: PaneDescriptor] = [:]
        for pane in shared { descriptors[pane.sessionID] = pane }

        var workspaces = SessionOutline.group(shared, focusedPaneID: nil)
            .enumerated()
            .map { index, node in
                Workspace(
                    id: node.project,
                    name: name(node.project, labels: workspaceLabels),
                    tint: tints[node.project].flatMap(hex),
                    order: index,
                    sessions: node.sessions.enumerated().map { sessionIndex, session in
                        Session(
                            id: session.id,
                            label: session.label,
                            order: sessionIndex,
                            panes: session.paneIDs.enumerated().compactMap { paneIndex, id in
                                guard let pane = descriptors[id] else { return nil }
                                return Pane(
                                    id: id,
                                    // The name the host's own row prints —
                                    // the user's label, else the live title,
                                    // else the derived placeholder.
                                    title: SessionOutline.paneLabel(pane),
                                    engine: pane.engine.rawValue,
                                    kind: pane.kind.rawValue,
                                    order: paneIndex
                                )
                            }
                        )
                    }
                )
            }

        // Enabled but with nothing running: appended in sorted order, so the
        // list is stable across runs (`Set` has no order of its own).
        let listed = Set(workspaces.map(\.id))
        for project in enabledWorkspaceIDs.sorted() where !listed.contains(project) {
            workspaces.append(
                Workspace(
                    id: project,
                    name: name(project, labels: workspaceLabels),
                    tint: tints[project].flatMap(hex),
                    order: workspaces.count,
                    sessions: []
                )
            )
        }
        return Payload(workspaces: workspaces)
    }

    /// The projection as the sidebar's own values — the *same*
    /// `WorkspaceTreeEntry`/`SessionGroupNode` types the local tree renders,
    /// which is the whole point: the viewer draws a remote machine through
    /// the ordinary workspace/session rows rather than a second row variant
    /// that could drift from them.
    ///
    /// `idPrefix` names the machine this payload came from — a viewer passes
    /// `remote:<device>`, so a workspace another Mac shares (`remote:<device>/
    /// <workspace>`) can never collide with the same folder open locally, and
    /// the sessions carry that same string as their project, which is where
    /// `openRemoteSession` puts the panes it opens. Empty (the default)
    /// leaves the projection's own ids alone. This is the *only* place these
    /// values are built: a second construction beside it is how the two
    /// sidebars would drift apart again.
    static func treeEntries(_ payload: Payload, idPrefix: String = "") -> [WorkspaceTreeEntry] {
        // Sorted by the host's `order` and never re-sorted — the host's
        // ordering is the answer, and re-deriving one here is exactly the
        // drift this schema exists to prevent.
        payload.workspaces.sorted { $0.order < $1.order }.map { workspace in
            WorkspaceTreeEntry(
                id: idPrefix.isEmpty ? workspace.id : "\(idPrefix)/\(workspace.id)",
                label: workspace.name,
                sessions: workspace.sessions.sorted { $0.order < $1.order }.map { session in
                    let panes = session.panes.sorted { $0.order < $1.order }
                    return SessionGroupNode(
                        id: session.id,
                        project: idPrefix.isEmpty ? workspace.id : idPrefix,
                        // `name` means "a name a human actually stored on the
                        // panes". The projection carries no such fact, and a
                        // row prints `name ?? label` either way.
                        name: nil,
                        label: session.label,
                        // The host's cwd is not projected: it names a
                        // directory on the *other* Mac, and a viewer that
                        // printed it would be pointing at a path that may not
                        // exist here.
                        cwd: "",
                        // Every pane, so the dots match the host's row…
                        paneIDs: panes.map(\.id),
                        // …but only a terminal has a daemon session behind it
                        // for a viewer to attach to. An editor or browser id
                        // handed to `Attach` names nothing the daemon knows:
                        // the pane would open empty and never connect.
                        terminalPaneIDs: panes
                            .filter { $0.kind == PaneKind.terminal.rawValue }
                            .map(\.id),
                        // "Currently on screen" is a fact about the host's
                        // focus, which is not the viewer's.
                        isCurrent: false
                    )
                },
                tint: color(workspace.tint)
            )
        }
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
            return #"{"version":\#(currentVersion),"workspaces":[]}"#
        }
        return json
    }

    /// Never throws: an unreadable row means "nothing is shared", which is
    /// the safe direction for a row that is an authorization list.
    ///
    /// v1 or v2 in, always v2 out. A v1 row (no `version` key, panes
    /// flattened as `sessions`) is lifted into one one-pane session per
    /// entry, so a host that has not updated yet still renders and still
    /// opens. That matters only during the window where one Mac has phase 2
    /// and the other does not.
    static func decode(_ raw: String?) -> Payload {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return Payload(workspaces: [])
        }
        let decoder = JSONDecoder()
        if
            let version = (try? decoder.decode(VersionProbe.self, from: data))?.version,
            version == currentVersion
        {
            return (try? decoder.decode(Payload.self, from: data)) ?? Payload(workspaces: [])
        }
        guard let legacy = try? decoder.decode(LegacyPayload.self, from: data) else {
            return Payload(workspaces: [])
        }
        return lift(legacy)
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

    // MARK: - Schema v1

    /// Just enough of the row to tell the schemas apart: a v1 row has no
    /// `version` key at all.
    private struct VersionProbe: Decodable {
        let version: Int?
    }

    private struct LegacySession: Codable, Equatable {
        let id: String
        let title: String
        let engine: String
        let group: String?
    }

    private struct LegacyWorkspace: Codable, Equatable {
        let id: String
        let name: String
        let sessions: [LegacySession]
    }

    private struct LegacyPayload: Codable, Equatable {
        let workspaces: [LegacyWorkspace]
    }

    /// A v1 row as the current schema: every flattened entry becomes a
    /// one-pane session, keeping the pane id — which is what a viewer
    /// attaches with — exactly where it was.
    private static func lift(_ legacy: LegacyPayload) -> Payload {
        Payload(
            workspaces: legacy.workspaces.enumerated().map { index, workspace in
                Workspace(
                    id: workspace.id,
                    name: workspace.name,
                    tint: nil,
                    order: index,
                    sessions: workspace.sessions.enumerated().map { sessionIndex, session in
                        Session(
                            // The entry's own id: v1 had no session-group id
                            // worth trusting (`group` is nullable and shared
                            // between entries), and the id a viewer already
                            // navigates by is this one.
                            id: session.id,
                            label: session.title,
                            order: sessionIndex,
                            panes: [
                                Pane(
                                    id: session.id,
                                    title: session.title,
                                    engine: session.engine,
                                    // v1 projected terminals only.
                                    kind: PaneKind.terminal.rawValue,
                                    order: 0
                                )
                            ]
                        )
                    }
                )
            }
        )
    }

    // MARK: - Names and colours

    /// The name a remote viewer prints for a workspace is the one the local
    /// sidebar prints — the Customize… display name when there is one, else
    /// the brain's label, else the path.
    private static func name(_ project: String, labels: [String: String]) -> String {
        labels[project] ?? SessionOutline.projectLabel(project, labels: labels)
    }

    /// `#RRGGBB` in sRGB — a colour space, not a device one, so the two Macs
    /// agree on the bytes whatever their displays are.
    private static func hex(_ color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X",
            channel(srgb.redComponent),
            channel(srgb.greenComponent),
            channel(srgb.blueComponent)
        )
    }

    /// The inverse, tolerant of anything that is not a colour: an unreadable
    /// tint is no tint, which renders as the default folder glyph rather than
    /// failing.
    private static func color(_ hex: String?) -> NSColor? {
        guard var text = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

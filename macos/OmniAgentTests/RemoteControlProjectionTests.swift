import AppKit
import XCTest

@testable import OmniAgent

/// The `remote_control` settings row the daemon authorizes against and
/// remote viewers read — the remote-session-control spec's §2, now in its
/// phase-2 shape ("The viewer's sidebar mirrors the host",
/// docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md).
///
/// Three facts are pinned here because both the Rust side and the viewer
/// depend on them: the projection carries *only* enabled workspaces (it is
/// the whole trust boundary — nothing else on this Mac is ever visible
/// remotely), the JSON keys are the exact contract `relay.rs`/`server.rs`
/// deserialize, and the tree is the host's own — workspace → session → panes,
/// derived from the same `SessionOutline.group` the local sidebar renders,
/// which is what makes the two sidebars structurally identical.
final class RemoteControlProjectionTests: XCTestCase {
    private func pane(
        _ id: String,
        project: String,
        group: String,
        groupLabel: String? = nil,
        label: String? = nil,
        engine: Engine = .shell
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: groupLabel,
            project: project,
            engine: engine,
            label: label
        )
    }

    private func tab(
        _ id: String,
        project: String,
        label: String? = nil,
        group: String? = nil,
        groupLabel: String? = nil,
        engine: Engine = .shell
    ) -> PersistedTab {
        PersistedTab(
            project: project,
            engine: engine,
            cwd: project,
            id: id,
            label: label,
            group: group,
            groupLabel: groupLabel
        )
    }

    /// Finding 2 of Bruno's two-Mac session, in one assertion: three panes of
    /// one session used to arrive as "Session 1" three times, because phase 1
    /// flattened panes into "sessions" and fell back to the group's label for
    /// each one's title.
    func testThreePanesOfOneSessionAreOneSessionWithThreePanes() {
        let payload = RemoteControlProjection.build(
            panes: [pane("s1", project: "/a", group: "g1", groupLabel: "Session 1", label: "claude"),
                    pane("s2", project: "/a", group: "g1", groupLabel: "Session 1", label: "shell"),
                    pane("s3", project: "/a", group: "g1", groupLabel: "Session 1", label: "logs")],
            enabledWorkspaceIDs: ["/a"], workspaceLabels: ["/a": "Alpha"], tints: [:])

        XCTAssertEqual(payload.version, 2)
        XCTAssertEqual(payload.workspaces.count, 1)
        XCTAssertEqual(payload.workspaces[0].sessions.count, 1, "one session, not one per pane")
        XCTAssertEqual(payload.workspaces[0].sessions[0].label, "Session 1")
        XCTAssertEqual(payload.workspaces[0].sessions[0].panes.map(\.id), ["s1", "s2", "s3"])
        XCTAssertEqual(payload.workspaces[0].sessions[0].panes.map(\.title), ["claude", "shell", "logs"])
    }

    /// The viewer sorts by `order` and never re-sorts, so the host's order
    /// has to survive the round trip — and so does the workspace tint, which
    /// is what makes the two sidebars the same colour.
    func testOrderingAndTintSurviveTheRoundTrip() {
        let payload = RemoteControlProjection.build(
            panes: [pane("s1", project: "/b", group: "g2"), pane("s2", project: "/a", group: "g1")],
            enabledWorkspaceIDs: ["/a", "/b"], workspaceLabels: ["/a": "Alpha", "/b": "Beta"],
            tints: ["/a": NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)])
        XCTAssertEqual(payload.workspaces.map(\.order), [0, 1])
        XCTAssertEqual(payload.workspaces.first { $0.id == "/a" }?.tint, "#FF0000")
        XCTAssertEqual(RemoteControlProjection.decode(RemoteControlProjection.encode(payload)), payload)
    }

    /// One Mac updates before the other, so a v1 row has to keep working:
    /// it is read as one one-pane session per entry rather than dropped.
    func testAPhase1ProjectionStillDecodes() {
        let v1 = #"{"workspaces":[{"id":"/a","name":"Alpha","sessions":[{"id":"s1","title":"one","engine":"shell","group":null}]}]}"#
        let payload = RemoteControlProjection.decode(v1)
        XCTAssertEqual(payload.version, 2)
        XCTAssertEqual(payload.workspaces[0].sessions.map(\.label), ["one"])
        XCTAssertEqual(payload.workspaces[0].sessions[0].panes.map(\.id), ["s1"],
                       "a v1 entry becomes a one-pane session so old hosts still open")
    }

    /// The viewer renders the projection through the *same* `WorkspaceTreeEntry`
    /// / `SessionGroupNode` values the local tree does — that shared type is
    /// what makes the two sidebars structurally identical.
    func testTreeEntriesMirrorTheHostStructure() {
        let payload = RemoteControlProjection.build(
            panes: [pane("s1", project: "/a", group: "g1", groupLabel: "Session 1"),
                    pane("s2", project: "/a", group: "g1", groupLabel: "Session 1")],
            enabledWorkspaceIDs: ["/a"], workspaceLabels: ["/a": "Alpha"], tints: [:])
        let entries = RemoteControlProjection.treeEntries(payload)
        XCTAssertEqual(entries.map(\.label), ["Alpha"])
        XCTAssertEqual(entries[0].sessions.count, 1)
        XCTAssertEqual(entries[0].sessions[0].label, "Session 1")
        XCTAssertEqual(entries[0].sessions[0].paneIDs, ["s1", "s2"], "pane dots match the host's")
    }

    /// The daemon reads this row with `serde_json` against a fixed shape and
    /// walks `workspaces[].sessions[].panes[].id` for the ids a viewer may
    /// attach to. Every key here is that contract, so a rename shows up as a
    /// test failure on this side instead of a silent authorization refusal on
    /// the other. Slashes stay unescaped: workspace ids are paths, and the row
    /// is read by a human as often as by `serde_json`.
    func testEncodedJSONIsTheDaemonsContract() {
        let payload = RemoteControlProjection.build(
            panes: [pane("s1", project: "/a", group: "g1", groupLabel: "one", label: "editor", engine: .claude)],
            enabledWorkspaceIDs: ["/a"],
            workspaceLabels: ["/a": "Alpha"],
            tints: ["/a": NSColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1)]
        )
        XCTAssertEqual(
            RemoteControlProjection.encode(payload),
            ##"{"version":2,"workspaces":[{"id":"/a","name":"Alpha","order":0,"sessions":[{"id":"g1","label":"one","order":0,"panes":[{"engine":"claude","id":"s1","kind":"terminal","order":0,"title":"editor"}]}],"tint":"#0080FF"}]}"##
        )
    }

    /// Only enabled workspaces are ever projected — the projection *is* the
    /// trust boundary, so a workspace nobody shared has to be absent, not
    /// merely unlisted somewhere else.
    func testOnlyEnabledWorkspacesAreProjected() {
        let payload = RemoteControlProjection.build(
            panes: [pane("s1", project: "/a", group: "g1", label: "one"),
                    pane("s2", project: "/b", group: "g2")],
            enabledWorkspaceIDs: ["/a"],
            workspaceLabels: ["/a": "Alpha"],
            tints: [:]
        )
        XCTAssertEqual(payload.workspaces.map(\.id), ["/a"])
        XCTAssertEqual(payload.workspaces[0].name, "Alpha")
        XCTAssertEqual(payload.workspaces[0].sessions.flatMap(\.panes).map(\.id), ["s1"])
        XCTAssertEqual(payload.workspaces[0].sessions[0].panes[0].engine, "shell")
        XCTAssertEqual(payload.workspaces[0].sessions[0].panes[0].kind, "terminal")
    }

    /// An enabled workspace with nothing running is listed with an empty
    /// `sessions` array, not dropped. The daemon keeps its control channel
    /// open iff the projection lists >= 1 workspace, so dropping it would
    /// close the tunnel the instant a user enabled Remote Control on an idle
    /// workspace — the Mac would read as offline seconds after being turned
    /// on. Idle workspaces sort after the busy ones, so the row is stable
    /// across runs (`Set` has no order of its own).
    func testAnEnabledWorkspaceWithNoSessionsIsStillProjected() {
        let payload = RemoteControlProjection.build(
            panes: [pane("s1", project: "/a", group: "g1")],
            enabledWorkspaceIDs: ["/a", "/b", "/c"],
            workspaceLabels: ["/b": "Beta"],
            tints: [:]
        )
        XCTAssertEqual(payload.workspaces.map(\.id), ["/a", "/b", "/c"])
        XCTAssertEqual(payload.workspaces.map(\.order), [0, 1, 2])
        XCTAssertEqual(payload.workspaces[1].name, "Beta")
        XCTAssertEqual(payload.workspaces[1].sessions, [])
        XCTAssertEqual(payload.workspaces[2].sessions, [])
    }

    /// Nothing enabled is an empty projection, not an absent row: the daemon
    /// closes its control channel on exactly this value.
    func testNothingEnabledProjectsNoWorkspaces() {
        let payload = RemoteControlProjection.build(
            panes: [pane("s1", project: "/a", group: "g1")],
            enabledWorkspaceIDs: [],
            workspaceLabels: [:],
            tints: [:]
        )
        XCTAssertEqual(payload, .init(workspaces: []))
        XCTAssertEqual(RemoteControlProjection.encode(payload), #"{"version":2,"workspaces":[]}"#)
    }

    /// An unreadable row means "nothing is shared", which is the safe answer
    /// for a row that is an authorization list.
    func testDecodeToleratesGarbageAndTheEnabledRowRoundTrips() {
        XCTAssertEqual(RemoteControlProjection.decode("not json"), .init(workspaces: []))
        XCTAssertEqual(RemoteControlProjection.decode(nil), .init(workspaces: []))
        XCTAssertEqual(RemoteControlProjection.decode(#"{"version":9,"workspaces":[]}"#), .init(workspaces: []))
        XCTAssertEqual(
            RemoteControlProjection.decodeEnabled(RemoteControlProjection.encodeEnabled(["/a", "/b"])),
            ["/a", "/b"]
        )
        XCTAssertEqual(RemoteControlProjection.decodeEnabled(nil), [])
        XCTAssertEqual(RemoteControlProjection.decodeEnabled("{"), [])
    }

    /// The phase-1 `build(tabs:)` overload survives only until T8 moves the
    /// window's two call sites onto `build(panes:)`. While it exists it keeps
    /// phase-1's flattening — one session per pane, the pane id attachable —
    /// lifted into the v2 shape, so nothing regresses in the meantime.
    func testTheDeprecatedTabsOverloadStillCarriesAttachablePaneIDs() {
        let payload = RemoteControlProjection.build(
            tabs: [tab("s1", project: "/a", label: "one", group: "g1")],
            enabledWorkspaceIDs: ["/a"],
            workspaceLabels: ["/a": "Alpha"]
        )
        XCTAssertEqual(payload.version, 2)
        XCTAssertEqual(payload.workspaces[0].sessions.map(\.label), ["one"])
        XCTAssertEqual(payload.workspaces[0].sessions.flatMap(\.panes).map(\.id), ["s1"])
    }
}

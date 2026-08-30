import XCTest

@testable import OmniAgent

/// The `remote_control` settings row the daemon authorizes against and
/// remote viewers read — the remote-session-control spec's §2
/// ("Per-workspace enablement and the projection",
/// docs/superpowers/specs/2026-08-30-remote-session-control-design.md).
///
/// Two facts are pinned here because the Rust side depends on them: the
/// projection carries *only* enabled workspaces (it is the whole trust
/// boundary — nothing else on this Mac is ever visible remotely), and the
/// JSON keys are the exact snake_case contract `relay.rs` deserializes.
final class RemoteControlProjectionTests: XCTestCase {
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

    func testOnlyEnabledWorkspacesAreProjected() {
        let payload = RemoteControlProjection.build(
            tabs: [tab("s1", project: "/a", label: "one"), tab("s2", project: "/b")],
            enabledWorkspaceIDs: ["/a"],
            workspaceLabels: ["/a": "Alpha"]
        )
        XCTAssertEqual(payload.workspaces.map(\.id), ["/a"])
        XCTAssertEqual(payload.workspaces[0].name, "Alpha")
        XCTAssertEqual(payload.workspaces[0].sessions.map(\.id), ["s1"])
        XCTAssertEqual(payload.workspaces[0].sessions[0].title, "one")
        XCTAssertEqual(payload.workspaces[0].sessions[0].engine, "shell")
    }

    func testEncodeDecodeRoundTripsAndToleratesGarbage() {
        let payload = RemoteControlProjection.build(
            tabs: [tab("s1", project: "/a")],
            enabledWorkspaceIDs: ["/a"],
            workspaceLabels: [:]
        )
        XCTAssertEqual(RemoteControlProjection.decode(RemoteControlProjection.encode(payload)), payload)
        XCTAssertEqual(RemoteControlProjection.decode("not json"), .init(workspaces: []))
        XCTAssertEqual(RemoteControlProjection.decode(nil), .init(workspaces: []))
        XCTAssertEqual(
            RemoteControlProjection.decodeEnabled(RemoteControlProjection.encodeEnabled(["/a", "/b"])),
            ["/a", "/b"]
        )
        XCTAssertEqual(RemoteControlProjection.decodeEnabled(nil), [])
        XCTAssertEqual(RemoteControlProjection.decodeEnabled("{"), [])
    }

    /// The daemon reads this row with `serde_json` against a fixed shape:
    /// `{"workspaces":[{"id","name","sessions":[{"id","title","engine","group"}]}]}`.
    /// Every key here is that contract, so a rename shows up as a test
    /// failure on this side instead of a silent authorization refusal on the
    /// other. Slashes stay unescaped: workspace ids are paths, and the row
    /// is read by a human as often as by `serde_json`.
    func testEncodedJSONIsTheDaemonsContract() throws {
        let payload = RemoteControlProjection.build(
            tabs: [tab("s1", project: "/a", label: "one", group: "g1")],
            enabledWorkspaceIDs: ["/a"],
            workspaceLabels: ["/a": "Alpha"]
        )
        XCTAssertEqual(
            RemoteControlProjection.encode(payload),
            #"{"workspaces":[{"id":"/a","name":"Alpha","sessions":[{"engine":"shell","group":"g1","id":"s1","title":"one"}]}]}"#
        )
    }

    /// Workspaces keep the order their first session appeared in — the
    /// sidebar's order, not `Set`'s (which has none).
    func testWorkspacesKeepFirstAppearanceOrderAndGatherEverySession() {
        let payload = RemoteControlProjection.build(
            tabs: [
                tab("s1", project: "/b"),
                tab("s2", project: "/a"),
                tab("s3", project: "/b"),
            ],
            enabledWorkspaceIDs: ["/a", "/b"],
            workspaceLabels: [:]
        )
        XCTAssertEqual(payload.workspaces.map(\.id), ["/b", "/a"])
        XCTAssertEqual(payload.workspaces[0].sessions.map(\.id), ["s1", "s3"])
    }

    /// `label ?? groupLabel ?? id`, and a workspace with no stored label
    /// falls back to `SessionOutline.projectLabel` — the same name the
    /// sidebar row prints.
    func testTitleAndNameFallbacks() {
        let payload = RemoteControlProjection.build(
            tabs: [
                tab("s1", project: "/a", groupLabel: "the session"),
                tab("s2", project: "/a"),
            ],
            enabledWorkspaceIDs: ["/a"],
            workspaceLabels: [:]
        )
        XCTAssertEqual(payload.workspaces[0].name, "/a")
        XCTAssertEqual(payload.workspaces[0].sessions.map(\.title), ["the session", "s2"])
    }

    /// A pane the daemon has no session for cannot be attached to remotely,
    /// so it is not offered.
    func testTabsWithoutASessionIDAreDropped() {
        var idless = tab("", project: "/a")
        idless.id = nil
        let payload = RemoteControlProjection.build(
            tabs: [idless, tab("s1", project: "/a")],
            enabledWorkspaceIDs: ["/a"],
            workspaceLabels: [:]
        )
        XCTAssertEqual(payload.workspaces[0].sessions.map(\.id), ["s1"])
    }

    /// An enabled workspace with nothing running is listed with an empty
    /// `sessions` array, not dropped. The daemon keeps its control channel
    /// open iff the projection lists >= 1 workspace, so dropping it would
    /// close the tunnel the instant a user enabled Remote Control on an idle
    /// workspace — the Mac would read as offline seconds after being turned
    /// on.
    func testAnEnabledWorkspaceWithNoSessionsIsStillProjected() {
        let payload = RemoteControlProjection.build(
            tabs: [tab("s1", project: "/a")],
            enabledWorkspaceIDs: ["/a", "/b", "/c"],
            workspaceLabels: ["/b": "Beta"]
        )
        // Sessions first in layout order, then the idle ones sorted — `Set`
        // has no order of its own and the row must be stable across runs.
        XCTAssertEqual(payload.workspaces.map(\.id), ["/a", "/b", "/c"])
        XCTAssertEqual(payload.workspaces[1].name, "Beta")
        XCTAssertEqual(payload.workspaces[1].sessions, [])
        XCTAssertEqual(payload.workspaces[2].sessions, [])
        XCTAssertEqual(
            RemoteControlProjection.encode(
                RemoteControlProjection.build(tabs: [], enabledWorkspaceIDs: ["/a"], workspaceLabels: [:])
            ),
            #"{"workspaces":[{"id":"/a","name":"/a","sessions":[]}]}"#
        )
    }

    /// Nothing enabled is an empty projection, not an absent row: the daemon
    /// closes its control channel on exactly this value.
    func testNothingEnabledProjectsNoWorkspaces() {
        let payload = RemoteControlProjection.build(
            tabs: [tab("s1", project: "/a")],
            enabledWorkspaceIDs: [],
            workspaceLabels: [:]
        )
        XCTAssertEqual(payload, .init(workspaces: []))
        XCTAssertEqual(RemoteControlProjection.encode(payload), #"{"workspaces":[]}"#)
    }
}

# Remote Session Control Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Neither Mac's window can disturb the other's terminal, the viewer's sidebar is structurally identical to the host's, a machine appears without relaunching the app, and the host can see and disconnect whoever is watching.

**Architecture:** The PTY grid stays owned by the host — the daemon refuses `Resize` from remote clients and tells attached viewers the session's size, and the viewer renders that grid scaled to fit its own pane. The `remote_control` projection grows from a flat pane list into the host's real workspace → session → pane tree, which both the daemon's authorizer and the viewer's sidebar read. The daemon gains its first per-connection registry, which is what makes viewer presence and a kick possible.

**Tech Stack:** Rust (tokio, vt100, portable-pty), Swift/AppKit (SwiftTerm, Core Animation layer transforms), the existing daemon frame protocol.

**Spec:** `docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md` — read it first; every task argues from it. Phase 1's spec (`2026-08-30-remote-session-control-design.md`) is the unchanged foundation.

## Global Constraints

- `PROTOCOL_VERSION` stays `1`. New message kinds are **appended, never renumbering an existing kind**: server `SessionResized = 0x8c`, `RemoteViewers = 0x8d`; client `ListViewers = 0x1a`, `DisconnectViewer = 0x1b`. Every new kind needs its `TryFrom<u8>` arm (`protocol.rs:233-275`) and its byte-identical Swift mirror (`macos/OmniAgent/SessionProtocol.swift:3-70`).
- **Remote access stays deny-by-default.** Every new kind lands in `authorize_remote`'s `other => Err(...)` arm unless this plan says otherwise, and `Resize` moves *into* the deny arm. Each change gets a `tests/remote_authz.rs` case.
- Settings rows are a snake_case JSON contract between Swift (writer) and Rust (reader): `remote_control` (projection, now v2), `remote_control_workspaces`, `relay_device_token`, and the new `remote_control_blocked` (`["<viewer_id>", …]`, written by the daemon, cleared by the app).
- Projection v2 shape, exactly: `{"version":2,"workspaces":[{"id","name","tint","order","sessions":[{"id","label","order","panes":[{"id","title","engine","kind","order"}]}]}]}`. `tint` is `"#RRGGBB"` or `null`. The **attachable id is the pane id**. A v1 row (no `version`, panes flattened into `sessions`) must still parse on both sides.
- Glyphs: host workspace rows keep `globe`; viewer rows use `desktopcomputer.and.arrow.down`; the viewer-count badge uses `display`.
- Shared working tree: stage only your own files by path (never `git add -A`, never stash), commit with `git -c core.fsmonitor=false commit`, push with `git push origin main` right after. Trailers on every commit, exactly: `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>` and `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Tests: Rust `export PATH="$HOME/.cargo/bin:$PATH"; cargo test -p omniagent-pty-daemon`, `cargo clippy -p omniagent-pty-daemon --all-targets`. Swift single class: `xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -only-testing:OmniAgentTests/<Class> 2>&1 | tail -20` (no `-derivedDataPath`); full suite `caffeinate -disu ./macos/build.sh test`. Other agents build concurrently — on a DerivedData lock error wait 30 s and retry once.
- Known pre-existing failures, not yours: `testDraggingTheSidebarDividerSticks`, daemon `server_protocol` load-flaky timeouts, hover-card/ingest flakes.
- No new Swift files may be added without registering them in `project.pbxproj`; **Task 0 registers every new file up front** so no other task touches the project file.

## File structure

**Daemon** (`crates/omniagent-pty-daemon/src/`): `protocol.rs` (new kinds + payloads), `session.rs` (session size, `SessionEvent::Resized`), `server.rs` (resize refusal, size-on-attach, projection v2 reader, connection registry, presence, kick), `connections.rs` *(new — the registry, kept out of `server.rs` which is already large)*. Tests: `tests/remote_authz.rs`, `tests/remote_presence.rs` *(new)*.

**App core** (`macos/OmniAgent/`): `RemoteControlProjection.swift` (v2 + tree builder), `SessionConnection.swift` (size push, denial classification), `RemoteMachinesModel.swift` (re-dial, refresh, tree), `TerminalSurfaceView.swift` (no remote resize, scaled render), `RemoteTerminalScaler.swift` *(new — pure fit math)*.

**App UI** (`macos/OmniAgent/`): `WorkspacesTree.swift` + `NavigationSidebar.swift` (mirrored rows, count badge), `RemoteSessionPicker.swift` *(new)*, `WorkspacesHeaderMenus.swift` (picker wiring), `PaneFilmstripItemView.swift` (viewer badge), `WorkspaceWindowController.swift` (presence state, popover, blocklist clear).

## Dependency graph

```
T0 (pbxproj registration)
 ├─ Rust:    T1 → T2 → T3
 ├─ Core:    T4 ;  T5 → T6 ; T5 → T7
 └─ UI:      T8 (needs T4) → T9 → T10 (needs T3)
Wave 1: T1, T4, T5   Wave 2: T2, T6, T7, T8   Wave 3: T3, T9   Wave 4: T10
```

Suggested models: T0, T3, T7, T8, T10 → `opus`; the rest → default.

---

### Task 0: Register the new files in the Xcode project

**Files:**
- Create (one-line stubs): `macos/OmniAgent/RemoteTerminalScaler.swift`, `macos/OmniAgent/RemoteSessionPicker.swift`, `macos/OmniAgentTests/RemoteTerminalScalerTests.swift`, `macos/OmniAgentTests/RemoteSessionPickerTests.swift`, `macos/OmniAgentTests/RemotePresenceTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the stubs.** App files: `import Foundation` plus `// Filled in by the remote-session-control phase 2 plan.` Test files: `import XCTest` plus the same comment.

- [ ] **Step 2: Register each file.** Four entries per file, mirroring `HomeViewTests.swift` (`project.pbxproj:56, 263, 530, 814`): a `PBXBuildFile`, a `PBXFileReference` (`lastKnownFileType = sourcecode.swift; path = <name>; sourceTree = "<group>";`), a child entry in the `OmniAgent` group (app files) or `OmniAgentTests` group (test files), and an entry in the matching target's `PBXSourcesBuildPhase`. Generate ids with `uuidgen | tr -d - | cut -c1-24 | tr a-f A-F`. This is what commit `df9f0a1` did for phase 1 — `git show df9f0a1 -- macos/OmniAgent.xcodeproj/project.pbxproj` is the worked example.

- [ ] **Step 3: Verify.** `./macos/build.sh build` → `** BUILD SUCCEEDED **`; `xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -only-testing:OmniAgentTests/CommandPaletteTests 2>&1 | tail -3` → `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit and push** the pbxproj plus the five stubs: `chore(macos): register remote-session-control phase 2 files up front`.

---

### Task 1: Daemon — the host owns the grid

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/protocol.rs` (MessageKind + `SessionSizePayload`), `src/session.rs` (`ManagedSession` size, `SessionEvent::Resized`), `src/server.rs` (`authorize_remote`, `Resize` arm, `Attach` arm, `send_event`)
- Test: `crates/omniagent-pty-daemon/tests/remote_authz.rs`

**Interfaces produced:**
```rust
// protocol.rs
MessageKind::SessionResized = 0x8c            // server push
pub struct SessionSizePayload { pub id: String, pub cols: u16, pub rows: u16 }
// session.rs
impl ManagedSession { pub fn size(&self) -> (u16, u16) }   // last applied cols, rows
SessionEvent::Resized { cols: u16, rows: u16 }             // new variant, follows the existing Status variant
```
Consumed by T5/T7 (the app decodes `SessionResized`).

- [ ] **Step 1: Write the failing tests** in `tests/remote_authz.rs`, copying the `remote_client` helper pattern at `:77` and the test shape at `:120-152`:

```rust
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_remote_client_may_not_resize_a_shared_session() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _ctx, _stop) = remote_client(root.path(), "cat").await;
    client
        .send(MessageKind::Resize, serde_json::json!({"id": "s1", "cols": 40, "rows": 10}))
        .await;
    let reply = client.read().await;
    assert_eq!(
        reply.header.message_kind,
        MessageKind::Error,
        "the host owns the grid: a viewer's window must never resize it"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn attaching_tells_the_client_the_session_size_before_the_snapshot() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, ctx, _stop) = remote_client(root.path(), "cat").await;
    ctx.registry.get("s1").unwrap().resize(120, 40, 0, 0).unwrap();

    client
        .send(MessageKind::Attach, serde_json::json!({"id": "s1", "after_sequence": null}))
        .await;

    let size = client.read().await;
    assert_eq!(size.header.message_kind, MessageKind::SessionResized);
    let size: SessionSizePayload = serde_json::from_slice(&size.payload).unwrap();
    assert_eq!((size.id.as_str(), size.cols, size.rows), ("s1", 120, 40));
    assert_eq!(client.read().await.header.message_kind, MessageKind::Snapshot);
}
```

Add a third test that a *local* client's resize still reaches attached clients as a push — put it in `tests/remote_authz.rs` next to the others so the helper is in scope:

```rust
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_resize_reaches_every_attached_client() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, ctx, _stop) = remote_client(root.path(), "cat").await;
    client
        .send(MessageKind::Attach, serde_json::json!({"id": "s1", "after_sequence": null}))
        .await;
    assert_eq!(client.read().await.header.message_kind, MessageKind::SessionResized);
    assert_eq!(client.read().await.header.message_kind, MessageKind::Snapshot);

    ctx.registry.get("s1").unwrap().resize(100, 30, 0, 0).unwrap();

    // The attached viewer is told, without asking.
    let pushed = loop {
        let frame = client.read().await;
        if frame.header.message_kind == MessageKind::SessionResized { break frame; }
        assert_ne!(frame.header.message_kind, MessageKind::Error);
    };
    let pushed: SessionSizePayload = serde_json::from_slice(&pushed.payload).unwrap();
    assert_eq!((pushed.cols, pushed.rows), (100, 30));
}
```

- [ ] **Step 2: Run them to verify they fail.** `cargo test -p omniagent-pty-daemon --test remote_authz` → compile error (`SessionResized` / `SessionSizePayload` unknown).

- [ ] **Step 3: Implement.**
1. `protocol.rs`: add `SessionResized = 0x8c` to the server block (with the same "appended, never renumbering" doc comment style as its neighbours), its `TryFrom<u8>` arm, and
   ```rust
   #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
   pub struct SessionSizePayload { pub id: String, pub cols: u16, pub rows: u16 }
   ```
2. `session.rs`: give `ManagedSession` a `size: Mutex<(u16, u16)>` initialised from `CreateSession { cols, rows }`; `pub fn size(&self) -> (u16, u16)` reads it; `resize(...)` writes it after the PTY and parser calls succeed, then pushes a new `SessionEvent::Resized { cols, rows }` through the same path `Status` uses (read the `Status` variant and its push site and follow it exactly, including the history/sequence bookkeeping).
3. `server.rs`: in `send_event`, map `SessionEvent::Resized { cols, rows }` to a `SessionResized` frame carrying `SessionSizePayload`. In the `Attach` arm (`:518`), immediately before `send_attach_state`, send the current size:
   ```rust
   let (cols, rows) = session.size();
   send_json(&writer, MessageKind::SessionResized, request,
             &SessionSizePayload { id: attach.id.clone(), cols, rows }).await?;
   ```
   In `authorize_remote`, remove `MessageKind::Resize` from the `Attach | Resize | Interrupt` arm so it falls into `other => Err(...)`, and say why in a comment ("the host owns the grid — spec §1").

- [ ] **Step 4: Run the tests.** `cargo test -p omniagent-pty-daemon --test remote_authz` → all pass. Then `cargo test -p omniagent-pty-daemon` (no new failures beyond the known flaky `server_protocol` timeouts) and `cargo clippy -p omniagent-pty-daemon --all-targets` (clean).

- [ ] **Step 5: Commit and push.** `feat(daemon): the host owns the terminal grid; viewers are told its size`

---

### Task 2: Daemon — read projection v2

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (`remote_session_ids`, `:71-84`)
- Test: `crates/omniagent-pty-daemon/tests/remote_authz.rs`

**Interfaces:** `remote_session_ids(&Store) -> HashSet<String>` keeps its signature; it now walks v2's `workspaces[].sessions[].panes[].id` and still accepts v1's `workspaces[].sessions[].id`. `remote_control_active` is unchanged (still "≥ 1 workspace").

- [ ] **Step 1: Write the failing test.**

```rust
const PROJECTION_V2: &str = r#"{"version":2,"workspaces":[{"id":"/a","name":"Alpha","tint":null,"order":0,
"sessions":[{"id":"g1","label":"Session 1","order":0,
"panes":[{"id":"s1","title":"claude","engine":"claude","kind":"terminal","order":0},
         {"id":"s3","title":"shell","engine":"shell","kind":"terminal","order":1}]}]}]}"#;

#[test]
fn projection_v2_shares_every_pane_and_v1_still_parses() {
    let store = brain_core::Store::open_in_memory().unwrap();
    store.set_setting("remote_control", PROJECTION_V2).unwrap();
    let ids = omniagent_pty_daemon::remote_session_ids(&store);
    assert_eq!(ids, ["s1".to_string(), "s3".to_string()].into_iter().collect(),
               "a pane is what a viewer attaches to");
    assert!(omniagent_pty_daemon::remote_control_active(&store));

    // A phase-1 row from a Mac that has not updated yet.
    store.set_setting("remote_control", PROJECTION).unwrap();
    assert_eq!(omniagent_pty_daemon::remote_session_ids(&store),
               ["s1".to_string()].into_iter().collect());
}
```

(`PROJECTION` is the existing v1 constant at the top of `tests/remote_authz.rs`.)

- [ ] **Step 2: Run it to verify it fails.** `cargo test -p omniagent-pty-daemon --test remote_authz projection_v2` → fails, the v2 ids come back empty.

- [ ] **Step 3: Implement.** In `remote_session_ids`, for each workspace's `sessions` entry collect `panes[].id` when a `panes` array is present, else the entry's own `id`. Keep it allocation-light and comment the two shapes. Do not change `remote_control_active`.

- [ ] **Step 4: Run the tests.** `cargo test -p omniagent-pty-daemon --test remote_authz --test relay_loopback` → all pass; clippy clean.

- [ ] **Step 5: Commit and push.** `feat(daemon): the projection carries the host's session tree`

---

### Task 3: Daemon — connection registry, viewer presence, kick and block

**Files:**
- Create: `crates/omniagent-pty-daemon/src/connections.rs`
- Modify: `src/protocol.rs`, `src/server.rs`, `src/lib.rs`
- Test: `crates/omniagent-pty-daemon/tests/remote_presence.rs` (new)

**Interfaces produced:**
```rust
// connections.rs
pub struct ViewerIdentity { pub viewer_id: String, pub machine_name: String }
pub struct ConnectionEntry { pub trust: ClientTrust, pub viewer: Option<ViewerIdentity>,
                             pub attached: HashSet<String>, pub writer: SharedWriter,
                             pub cancel: tokio_util::sync::CancellationToken, pub since: SystemTime }
#[derive(Clone, Default)] pub struct ConnectionRegistry { /* Arc<Mutex<HashMap<u64, ConnectionEntry>>> */ }
impl ConnectionRegistry {
    pub fn register(&self, trust: ClientTrust, writer: SharedWriter, cancel: CancellationToken) -> u64;
    pub fn remove(&self, id: u64);
    pub fn set_viewer(&self, id: u64, viewer: ViewerIdentity);
    pub fn set_attached(&self, id: u64, attached: HashSet<String>);
    pub fn viewers(&self) -> Vec<ViewerSummary>;          // remote entries only
    pub fn local_writers(&self) -> Vec<SharedWriter>;
    pub fn cancel_viewer(&self, viewer_id: &str) -> bool; // drops every connection with that viewer id
}
pub struct ViewerSummary { pub viewer_id: String, pub machine_name: String,
                           pub sessions: Vec<String>, pub since: String /* rfc3339 */ }
// protocol.rs
MessageKind::ListViewers = 0x1a;  MessageKind::DisconnectViewer = 0x1b;  MessageKind::RemoteViewers = 0x8d;
pub struct HelloPayload { pub client: String,
    #[serde(default)] pub viewer_id: Option<String>, #[serde(default)] pub machine_name: Option<String> }
pub struct RemoteViewersPayload { pub viewers: Vec<ViewerSummaryPayload> }
pub struct ViewerSummaryPayload { pub viewer_id: String, pub machine_name: String,
                                  pub sessions: Vec<String>, pub since: String }
pub struct DisconnectViewerPayload { pub viewer_id: String }
// server.rs
pub const BLOCKED_VIEWERS_KEY: &str = "remote_control_blocked";
```
`ClientContext` gains `pub connections: ConnectionRegistry`.

- [ ] **Step 1: Write the failing tests** in a new `tests/remote_presence.rs`. Copy `command_session`, `Duplex` and the server bootstrap from `tests/remote_authz.rs:25-118` (a `local_and_remote_clients(root)` helper that returns one Local `Duplex` and one Remote `Duplex` against the same `ClientContext`).

```rust
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_local_client_learns_who_is_watching_and_can_disconnect_them() {
    let root = tempfile::tempdir().unwrap();
    let (mut host, mut viewer, ctx, _stop) = local_and_remote_clients(root.path()).await;

    // The viewer names itself in Hello and attaches to a shared pane.
    viewer.send(MessageKind::Attach, serde_json::json!({"id": "s1", "after_sequence": null})).await;
    drain_until(&mut viewer, MessageKind::Snapshot).await;

    host.send(MessageKind::ListViewers, serde_json::json!({})).await;
    let roster: RemoteViewersPayload = serde_json::from_slice(&host.read().await.payload).unwrap();
    assert_eq!(roster.viewers.len(), 1);
    assert_eq!(roster.viewers[0].machine_name, "Air");
    assert_eq!(roster.viewers[0].sessions, vec!["s1".to_string()]);

    host.send(MessageKind::DisconnectViewer, serde_json::json!({"viewer_id": "v-air"})).await;
    assert_eq!(host.read().await.header.message_kind, MessageKind::Response);

    // The viewer's connection is gone, and it is blocked from coming back.
    assert!(viewer.read_eof_within(std::time::Duration::from_secs(2)).await,
            "a kicked viewer's socket is dropped");
    let blocked = ctx.settings.lock().unwrap().get_setting(BLOCKED_VIEWERS_KEY).unwrap().unwrap();
    assert!(blocked.contains("v-air"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_blocked_viewer_cannot_say_hello() {
    let root = tempfile::tempdir().unwrap();
    let (_host, _viewer, ctx, _stop) = local_and_remote_clients(root.path()).await;
    ctx.settings.lock().unwrap().set_setting(BLOCKED_VIEWERS_KEY, r#"["v-air"]"#).unwrap();

    let (client_side, server_side) = tokio::io::duplex(64 * 1024);
    tokio::spawn(serve_client(server_side, ctx.clone(), ClientTrust::Remote));
    let mut blocked = Duplex { stream: client_side, request: 0 };
    blocked.send(MessageKind::Hello, serde_json::json!({
        "client": "omniagent-native-macos", "viewer_id": "v-air", "machine_name": "Air"})).await;
    assert_eq!(blocked.read().await.header.message_kind, MessageKind::Error);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn presence_is_local_only() {
    let root = tempfile::tempdir().unwrap();
    let (_host, mut viewer, _ctx, _stop) = local_and_remote_clients(root.path()).await;
    for kind in [MessageKind::ListViewers, MessageKind::DisconnectViewer] {
        viewer.send(kind, serde_json::json!({"viewer_id": "v-air"})).await;
        assert_eq!(viewer.read().await.header.message_kind, MessageKind::Error,
                   "{kind:?} must never be reachable from a viewer");
    }
}
```

Also add to `tests/remote_authz.rs` a case asserting a viewer never receives a `RemoteViewers` push: attach, resize locally, drain frames for 500 ms and assert none is `RemoteViewers`.

- [ ] **Step 2: Run them to verify they fail.** `cargo test -p omniagent-pty-daemon --test remote_presence` → compile error.

- [ ] **Step 3: Implement.**
1. `Cargo.toml`: add `tokio-util = { version = "0.7", features = ["io", "rt"] }` if the `rt` feature (for `CancellationToken`) is not already enabled — `tokio-util` is already a dependency from phase 1.
2. `connections.rs` per the interface block above. Ids come from an `AtomicU64`.
3. `server.rs`: `ClientContext` gains `connections: ConnectionRegistry` (constructed once in `bind_with_data_dir`). `serve_client` registers itself on entry with a `CancellationToken`, removes itself on exit (use a guard so every early return cleans up), updates `set_attached` whenever `attachments` changes, and races its read loop against `cancel.cancelled()` so a kick drops the socket promptly.
4. `Hello` arm: parse the new optional fields; if `trust == Remote`, look up `BLOCKED_VIEWERS_KEY` and, when `viewer_id` is listed, `send_error` and return; otherwise `set_viewer`. After a successful local `Hello`, send the current roster as a `RemoteViewers` push so a freshly opened app is immediately correct.
5. Push on change: after any registry mutation that changes the remote set (register/remove/set_viewer/set_attached for a Remote entry), send `RemoteViewers` to every `local_writers()`. Keep this in one `notify_local_presence(&ctx)` helper so there is a single call site pattern.
6. `ListViewers` (local only) replies `Response`-style with `RemoteViewersPayload`; `DisconnectViewer` (local only) adds the id to `BLOCKED_VIEWERS_KEY` (read-modify-write the JSON array), calls `cancel_viewer`, replies `Response`, then pushes the new roster.
7. `authorize_remote`: nothing to add — both new client kinds fall into `other => Err(...)`. Add the two tests above to prove it.

- [ ] **Step 4: Run the tests.** `cargo test -p omniagent-pty-daemon` → the three new tests pass, `remote_authz`/`relay_loopback` still pass; clippy clean; `cargo build --release -p omniagent-pty-daemon` succeeds.

- [ ] **Step 5: Commit and push.** `feat(daemon): the host sees who is attached and can disconnect them`

---

### Task 4: App — projection v2 writer and tree builder

**Files:**
- Modify: `macos/OmniAgent/RemoteControlProjection.swift`
- Test: `macos/OmniAgentTests/RemoteControlProjectionTests.swift`

**Interfaces produced:**
```swift
extension RemoteControlProjection {
    struct Pane: Codable, Equatable { let id: String; let title: String; let engine: String
                                      let kind: String; let order: Int }
    struct Session: Codable, Equatable { let id: String; let label: String; let order: Int
                                         let panes: [Pane] }          // replaces the phase-1 Session
    struct Workspace: Codable, Equatable { let id: String; let name: String; let tint: String?
                                           let order: Int; let sessions: [Session] }
    struct Payload: Codable, Equatable { let version: Int; let workspaces: [Workspace] }
    static func build(panes: [PaneDescriptor], enabledWorkspaceIDs: Set<String>,
                      workspaceLabels: [String: String], tints: [String: NSColor]) -> Payload
    static func decode(_ raw: String?) -> Payload        // v1 or v2 in, always v2 out
    static func treeEntries(_ payload: Payload) -> [WorkspaceTreeEntry]   // for the sidebar and picker
}
```
`encode`, `encodeEnabled`, `decodeEnabled` keep their phase-1 signatures. `build` now takes `[PaneDescriptor]` (not `[PersistedTab]`) so it can reuse `SessionOutline.group`; T8 updates the two call sites in `WorkspaceWindowController`.

- [ ] **Step 1: Write the failing tests.**

```swift
private func pane(_ id: String, project: String, group: String, groupLabel: String? = nil,
                  label: String? = nil, engine: Engine = .shell) -> PaneDescriptor {
    PaneDescriptor(sessionID: id, group: group, groupLabel: groupLabel, project: project,
                   engine: engine, label: label)
}

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

func testOrderingAndTintSurviveTheRoundTrip() {
    let payload = RemoteControlProjection.build(
        panes: [pane("s1", project: "/b", group: "g2"), pane("s2", project: "/a", group: "g1")],
        enabledWorkspaceIDs: ["/a", "/b"], workspaceLabels: ["/a": "Alpha", "/b": "Beta"],
        tints: ["/a": NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)])
    XCTAssertEqual(payload.workspaces.map(\.order), [0, 1])
    XCTAssertEqual(payload.workspaces.first { $0.id == "/a" }?.tint, "#FF0000")
    XCTAssertEqual(RemoteControlProjection.decode(RemoteControlProjection.encode(payload)), payload)
}

func testAPhase1ProjectionStillDecodes() {
    let v1 = #"{"workspaces":[{"id":"/a","name":"Alpha","sessions":[{"id":"s1","title":"one","engine":"shell","group":null}]}]}"#
    let payload = RemoteControlProjection.decode(v1)
    XCTAssertEqual(payload.version, 2)
    XCTAssertEqual(payload.workspaces[0].sessions.map(\.label), ["one"])
    XCTAssertEqual(payload.workspaces[0].sessions[0].panes.map(\.id), ["s1"],
                   "a v1 entry becomes a one-pane session so old hosts still open")
}

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
```

- [ ] **Step 2: Run to verify they fail.** `xcodebuild test … -only-testing:OmniAgentTests/RemoteControlProjectionTests` → compile errors.

- [ ] **Step 3: Implement.** `build` groups panes with `SessionOutline.group(panes, focusedPaneID: nil)` — the same function the host sidebar uses, which is what guarantees the structures cannot drift — keeps only enabled projects, and maps `ProjectSessionsNode`/`SessionGroupNode` to `Workspace`/`Session`/`Pane`, assigning `order` by position. `tint` is `"#RRGGBB"` from the sRGB components, `nil` when absent. `decode` sniffs `version`: `2` decodes directly, anything else decodes the v1 shape and lifts each entry into a one-pane session (`label` from v1's `title`, pane `title` from the same, `kind: "terminal"`). `treeEntries` maps to `WorkspaceTreeEntry(id:label:sessions:tint:remoteControl:)` with `SessionGroupNode(id:project:name:label:cwd:paneIDs:isCurrent:)` — read both declarations and fill every field (`isCurrent: false`, `cwd: ""`, `project:` the workspace id).

- [ ] **Step 4: Run the tests.** All five pass. Then `xcodebuild test … -only-testing:OmniAgentTests/WorkspaceShellTests -only-testing:OmniAgentTests/WorkspaceContextMenuTests` — these exercise the phase-1 call sites; if they fail to compile because `build` changed shape, **stop and report**: T8 owns those call sites.

- [ ] **Step 5: Commit and push.** `feat(macos): the projection carries the host's workspace, session and pane tree`

---

### Task 5: App — SessionConnection learns session size and stops latching

**Files:**
- Modify: `macos/OmniAgent/SessionProtocol.swift` (mirror the new kinds), `macos/OmniAgent/SessionConnection.swift`
- Test: `macos/OmniAgentTests/SessionConnectionWebSocketTests.swift`

**Interfaces produced:**
```swift
// SessionProtocol.swift — byte-identical mirror of the Rust kinds
case sessionResized = 0x8c
case remoteViewers  = 0x8d
case listViewers    = 0x1a
case disconnectViewer = 0x1b
// SessionConnection.swift
var onSessionSize: ((String, UInt16, UInt16) -> Void)?      // sessionID, cols, rows
var onRemoteViewers: (([RemoteViewer]) -> Void)?
struct RemoteViewer: Codable, Equatable { let viewerID: String; let machineName: String
                                          let sessions: [String]; let since: String }
func listViewers(completion: @escaping (Result<[RemoteViewer], Error>) -> Void)
func disconnectViewer(viewerID: String, completion: ((Result<Void, Error>) -> Void)? = nil)
```
Consumed by T6 (`onRemoteViewers` is surfaced to the controller), T7 (`onSessionSize`), T10 (list/disconnect).

- [ ] **Step 1: Write the failing tests.** Extend the existing `FakeRelay` in `SessionConnectionWebSocketTests.swift` so it can push a frame after the handshake, then:

```swift
func testASessionResizedPushIsDeliveredAsASizeCallback() throws {
    // …stand up the fake relay and connect, as in testWebSocketTransportCompletesTheHelloHandshake…
    let sized = expectation(description: "size")
    connection.onSessionSize = { id, cols, rows in
        XCTAssertEqual([id, String(cols), String(rows)], ["s1", "120", "40"]); sized.fulfill()
    }
    relay.push(kind: .sessionResized, json: ["id": "s1", "cols": 120, "rows": 40])
    wait(for: [sized], timeout: 5)
}

func testOnlyA401ParksTheConnection() {
    // A 403 is "the host is not registered yet", not "your token is bad": it must keep retrying.
    XCTAssertFalse(SessionConnection.isTokenRefusal(status: 403))
    XCTAssertFalse(SessionConnection.isTokenRefusal(status: 503))
    XCTAssertTrue(SessionConnection.isTokenRefusal(status: 401))
}

func testA403KeepsReconnecting() throws {
    let relay = try FakeRelay(rejectWith: 403)
    relay.start()
    let connection = SessionConnection(transport: .webSocket(relay.url, bearer: { "t" }), callbackQueue: .main)
    let retried = expectation(description: "second attempt")
    relay.onAttempt = { if relay.attempts >= 2 { retried.fulfill() } }
    connection.connect()
    wait(for: [retried], timeout: 8)   // 250 ms then 500 ms of backoff
    connection.disconnect()
}
```

- [ ] **Step 2: Run to verify they fail.** → compile error on `onSessionSize` / `isTokenRefusal`.

- [ ] **Step 3: Implement.**
1. `SessionProtocol.swift`: add the four cases with their exact raw values, next to their neighbours.
2. `SessionConnection.swift`: add `static func isTokenRefusal(status: Int) -> Bool { status == 401 }` and use it in `webSocketFailed` (`:817-828`) — only a token refusal sets `shouldReconnect = false` and reports `.unauthorized`; every other status closes with the underlying error and keeps reconnecting with the existing backoff. Add the `onSessionSize`/`onRemoteViewers` callbacks and their `handle(_:)` arms beside `.sessionStatus` (`:923-940`), decoding `SessionSizePayload`/`RemoteViewersPayload` (declare the Swift `Codable` mirrors with `CodingKeys` mapping `viewer_id`/`machine_name` to `viewerID`/`machineName`). Add `listViewers`/`disconnectViewer` following the `getSetting`/`setSetting` request pattern.

- [ ] **Step 4: Run the tests.** New tests plus `SessionConnectionTests` and `FrameCodecTests` pass.

- [ ] **Step 5: Commit and push.** `feat(macos): SessionConnection carries session size and viewer presence`

---

### Task 6: App — a machine reappears without relaunching

**Files:**
- Modify: `macos/OmniAgent/RemoteMachinesModel.swift`
- Test: `macos/OmniAgentTests/RemoteMachinesModelTests.swift`

**Interfaces:** consumes `SessionConnection.isTokenRefusal` and `.unauthorized` (T5). Produces `RemoteMachine` unchanged in shape but with `projection` now the v2 `Payload` (T4), and a new `var onViewersChanged: (() -> Void)?` is **not** needed here — presence is host-side.

- [ ] **Step 1: Write the failing tests.**

```swift
func testAnOnlineDeviceWithNoLiveConnectionIsAlwaysRedialled() async {
    // The phase-1 rule ("re-dial only when the bearer changed") stranded a Mac until relaunch.
    let fake = FakeSessionConnection()
    fake.simulateUnauthorized()                       // one early refusal
    let model = makeModel(connection: fake, bearer: { "same-token" })
    await model.refresh()                             // device still online, same bearer
    XCTAssertEqual(fake.connectCalls, 2, "a refusal must not strand the machine forever")
}

func testATokenRefusalStillWaitsForANewToken() async {
    let fake = FakeSessionConnection()
    fake.simulateTokenRefusal()                       // a real 401
    let model = makeModel(connection: fake, bearer: { "same-token" })
    await model.refresh()
    XCTAssertEqual(fake.connectCalls, 1, "a refused token is not retried with the same token")
    XCTAssertTrue(model.didRequestTokenRefresh, "…but a fresh one is asked for immediately")
}
```

Extend the existing `FakeSessionConnection` double with `simulateUnauthorized()` / `simulateTokenRefusal()` and a `connectCalls` counter (the class already exists in this test file from phase 1).

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement.** In `apply(_:)` (`:259`), replace the bearer-comparison branch: an online device whose connection is **not currently connected** is re-`connect()`ed (the connection's own backoff prevents a dial storm); only a *token refusal* parks it, keyed on the bearer as today. On `.unauthorized`, call the existing `refreshSessionIfStale()` immediately and record `didRequestTokenRefresh` for the test. Keep the generation guard and `localDeviceID` filter exactly as they are.

- [ ] **Step 4: Run the tests.** `RemoteMachinesModelTests` all pass (21 existing + 2 new).

- [ ] **Step 5: Commit and push.** `fix(macos): a refused viewer socket no longer strands a machine until relaunch`

---

### Task 7: App — the viewer renders the host's grid scaled to fit

**Files:**
- Create: `macos/OmniAgent/RemoteTerminalScaler.swift`
- Modify: `macos/OmniAgent/TerminalSurfaceView.swift`
- Test: `macos/OmniAgentTests/RemoteTerminalScalerTests.swift`

**Interfaces produced:**
```swift
struct RemoteTerminalScaler: Equatable {
    struct Fit: Equatable { let terminalSize: CGSize; let scale: CGFloat; let origin: CGPoint }
    var zoom: CGFloat = 0          // 0 = fit; >0 overrides, clamped to 0.25...2
    static func fit(hostCols: Int, hostRows: Int, cell: CGSize, pane: CGSize, zoom: CGFloat) -> Fit
}
extension TerminalSurfaceView { var remoteGrid: (cols: UInt16, rows: UInt16)? { get set } }
```

- [ ] **Step 1: Write the failing tests.**

```swift
func testTheWholeHostScreenFitsAndIsCentred() {
    let fit = RemoteTerminalScaler.fit(hostCols: 200, hostRows: 50,
                                       cell: CGSize(width: 8, height: 18),
                                       pane: CGSize(width: 800, height: 900), zoom: 0)
    XCTAssertEqual(fit.terminalSize, CGSize(width: 1600, height: 900), "the grid keeps its true size")
    XCTAssertEqual(fit.scale, 0.5, accuracy: 0.001, "width is the binding constraint")
    XCTAssertEqual(fit.origin.y, 0, accuracy: 0.001, "…so it fills the height exactly")
    XCTAssertEqual(fit.origin.x, 0, accuracy: 0.001)
}

func testASmallerHostIsNotBlownUp() {
    let fit = RemoteTerminalScaler.fit(hostCols: 80, hostRows: 24,
                                       cell: CGSize(width: 8, height: 18),
                                       pane: CGSize(width: 1600, height: 900), zoom: 0)
    XCTAssertEqual(fit.scale, 1, "fit never magnifies; the host's screen is drawn 1:1 and centred")
    XCTAssertEqual(fit.origin.x, 480, accuracy: 0.001)
}

func testZoomOverridesFitAndIsClamped() {
    let cell = CGSize(width: 8, height: 18), pane = CGSize(width: 800, height: 900)
    XCTAssertEqual(RemoteTerminalScaler.fit(hostCols: 200, hostRows: 50, cell: cell, pane: pane, zoom: 1).scale, 1)
    XCTAssertEqual(RemoteTerminalScaler.fit(hostCols: 200, hostRows: 50, cell: cell, pane: pane, zoom: 9).scale, 2)
    XCTAssertEqual(RemoteTerminalScaler.fit(hostCols: 200, hostRows: 50, cell: cell, pane: pane, zoom: 0.01).scale, 0.25)
}

func testADegenerateGridIsSafe() {
    let fit = RemoteTerminalScaler.fit(hostCols: 0, hostRows: 0, cell: .zero,
                                       pane: CGSize(width: 800, height: 900), zoom: 0)
    XCTAssertEqual(fit.scale, 1)
    XCTAssertEqual(fit.terminalSize, CGSize(width: 800, height: 900), "never divide by zero")
}
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement `RemoteTerminalScaler`.** `terminalSize = (cols × cell.width, rows × cell.height)`; `scale = zoom > 0 ? clamp(zoom, 0.25, 2) : min(1, min(pane.width / terminalSize.width, pane.height / terminalSize.height))`; `origin` centres the scaled result in the pane, floored at zero. Guard every zero.

- [ ] **Step 4: Wire it into `TerminalSurfaceView`.**
1. `flushResize()` (`:398-407`): `guard !connection.isRemote else { return }` — a remote pane never resizes the shared grid. Comment it with the spec reference.
2. Store `remoteGrid` from `connection.onSessionSize` for this session id; when it changes, re-layout.
3. In the layout path, for a remote pane: set the terminal view's frame to `fit.terminalSize` at `fit.origin`, apply `CATransform3DMakeScale(fit.scale, fit.scale, 1)` to its layer with an anchor of `(0, 0)`, and set `terminalView.metalScaleFactorOverride = fit.scale * (window?.backingScaleFactor ?? 2)` so glyphs rasterize at true on-screen resolution. Local panes take the existing path untouched.
4. `⌘+` / `⌘−` / `⌘0` adjust `scaler.zoom` (×1.25, ÷1.25, reset to 0) for a remote pane only; wire them through the existing `validateMenuItem` so they are disabled on local panes.

- [ ] **Step 5: Run the tests.** `RemoteTerminalScalerTests` pass; `./macos/build.sh build` succeeds; `xcodebuild test … -only-testing:OmniAgentTests/RemotePanesTests` still passes.

- [ ] **Step 6: Commit and push.** `feat(macos): a remote pane renders the host's grid scaled to fit`

---

### Task 8: App — the viewer's sidebar mirrors the host

**Files:**
- Modify: `macos/OmniAgent/WorkspacesTree.swift` (`renderRemoteMachines` `:462-483`), `macos/OmniAgent/WorkspaceWindowController.swift` (the two `RemoteControlProjection.build` call sites and `remoteTreeEntries()`)
- Test: `macos/OmniAgentTests/NavigationSidebarTests.swift`

**Interfaces:** consumes `RemoteControlProjection.treeEntries` and the new `build(panes:enabledWorkspaceIDs:workspaceLabels:tints:)` (T4).

- [ ] **Step 1: Write the failing test.**

```swift
func testARemoteWorkspaceRendersLikeALocalOne() {
    let view = NavigationSidebarView()
    let payload = RemoteControlProjection.build(
        panes: [pane("s1", project: "/a", group: "g1", groupLabel: "Session 1"),
                pane("s2", project: "/a", group: "g1", groupLabel: "Session 1")],
        enabledWorkspaceIDs: ["/a"], workspaceLabels: ["/a": "Alpha"], tints: [:])
    view.reloadWorkspaces(entries: [], remoteMachines: [
        RemoteMachineTreeEntry(deviceID: "d1", name: "Studio",
                               workspaces: RemoteControlProjection.treeEntries(payload))])

    let workspaceRows = view.descendants(ofType: WorkspaceRowView.self)
    XCTAssertEqual(workspaceRows.map(\.titleText), ["Alpha"],
                   "a remote workspace uses the same row type as a local one")
    let sessionRows = view.descendants(ofType: SessionRowView.self)
    XCTAssertEqual(sessionRows.count, 1, "two panes of one session are one row, not two")
    XCTAssertEqual(sessionRows[0].paneDotCount, 2)
}
```

Add whatever tiny test-only accessors this needs (`titleText`, `paneDotCount`, `descendants(ofType:)`) next to the existing sidebar test helpers rather than exposing production state.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement.** `renderRemoteMachines` stops using `RemoteWorkspaceRowView` and its bespoke per-session row: for each machine it adds the bucket header, then for each workspace a `WorkspaceRowView(id:label:expanded:tint:remoteControl:)` — with the remote glyph rather than the globe — and then `addSessionRow(...)` exactly as the local path does, so pane dots, nesting, tint and ordering are identical. Keep `onOpenRemoteSession` routing off the session's first pane id. Delete `RemoteWorkspaceRowView` if nothing else uses it. Update `WorkspaceWindowController`'s two `RemoteControlProjection.build` call sites to the new signature (pass `localPaneDescriptors()` and the workspace tints it already has) and `remoteTreeEntries()` to use `RemoteControlProjection.treeEntries`.

- [ ] **Step 4: Run the tests.** New test plus `NavigationSidebarTests`, `WorkspaceShellTests`, `WorkspaceContextMenuTests`, `RemoteControlProjectionTests` pass; full suite has only the known failures.

- [ ] **Step 5: Commit and push.** `feat(macos): a remote machine's sidebar is structurally identical to its host's`

---

### Task 9: App — the Resume remote session picker

**Files:**
- Create: `macos/OmniAgent/RemoteSessionPicker.swift`
- Modify: `macos/OmniAgent/WorkspacesHeaderMenus.swift` (`plus(...)` `:152`), `macos/OmniAgent/WorkspaceWindowController.swift` (menu action)
- Test: `macos/OmniAgentTests/RemoteSessionPickerTests.swift`

**Interfaces produced:**
```swift
struct RemoteSessionPickerModel: Equatable {
    enum Row: Equatable { case machine(deviceID: String, name: String)
                          case workspace(name: String)
                          case session(deviceID: String, paneID: String, label: String, detail: String)
                          case empty(message: String) }
    static func rows(machines: [RemoteMachine], signedIn: Bool) -> [Row]
}
final class RemoteSessionPickerController { func present(over: NSWindow?, rows: [RemoteSessionPickerModel.Row],
                                                         onOpen: @escaping (String, String, String) -> Void) }
```

- [ ] **Step 1: Write the failing tests.**

```swift
func testRowsMirrorTheHostTreeUnderEachMachine() {
    let rows = RemoteSessionPickerModel.rows(machines: [studioWithTwoSessions()], signedIn: true)
    XCTAssertEqual(rows.first, .machine(deviceID: "d1", name: "Studio"))
    XCTAssertEqual(rows.compactMap { if case let .session(_, paneID, label, _) = $0 { return "\(paneID):\(label)" } else { return nil } },
                   ["s1:Session 1", "s3:Session 2"])
}

func testEmptyStatesSayWhatIsWrong() {
    XCTAssertEqual(RemoteSessionPickerModel.rows(machines: [], signedIn: false),
                   [.empty(message: "Signing in…")])
    XCTAssertEqual(RemoteSessionPickerModel.rows(machines: [], signedIn: true),
                   [.empty(message: "No other Macs are sharing sessions")])
}
```

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement** the model (pure) and a liquid-glass sheet controller built from `PaneAskOverlayView`'s building blocks — never `NSAlert`, per the house modal standard. Return/double-click calls `onOpen(deviceID, paneID, label)`; Escape dismisses.

- [ ] **Step 4: Wire it.** `WorkspacesHeaderMenus.plus(...)`'s `resumeRemoteSession` closure and the Session-menu item both present the picker instead of the filtered spotlight. Leave the spotlight rows from phase 1 untouched.

- [ ] **Step 5: Run the tests** (`RemoteSessionPickerTests`, `WorkspacesHeaderMenusTests`, `CommandPaletteTests`) and **commit**: `feat(macos): Resume remote session opens a picker of machines and sessions`

---

### Task 10: App — viewer presence, the count badge and Disconnect

**Files:**
- Modify: `macos/OmniAgent/WorkspacesTree.swift` (count badge on the workspace row), `macos/OmniAgent/PaneFilmstripItemView.swift` (viewer detail line), `macos/OmniAgent/WorkspaceWindowController.swift` (presence state, popover, blocklist clear)
- Test: `macos/OmniAgentTests/RemotePresenceTests.swift`

**Interfaces:** consumes `SessionConnection.onRemoteViewers`, `listViewers`, `disconnectViewer` (T5) and the daemon behaviour from T3.

- [ ] **Step 1: Write the failing tests.**

```swift
func testTheWorkspaceBadgeCountsMachinesWatchingThatWorkspace() {
    let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
    controller.applyRemoteViewers([
        .init(viewerID: "v1", machineName: "Air", sessions: ["s1"], since: "2026-08-31T10:00:00Z"),
        .init(viewerID: "v2", machineName: "MBP", sessions: ["s1"], since: "2026-08-31T10:01:00Z")])
    XCTAssertEqual(controller.remoteViewerCount(forWorkspace: "/a"), 2)
    XCTAssertEqual(controller.remoteViewerNames(forPane: "s1"), ["Air", "MBP"])
}

func testEnablingRemoteControlClearsTheBlocklist() {
    let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
    controller.toggleRemoteControl(workspaceID: "/a")      // on
    XCTAssertEqual(controller.lastWrittenSetting(SettingsKey.remoteControlBlocked), "[]",
                   "turning sharing back on is how a kicked Mac is forgiven")
}

func testDisconnectSendsTheViewerIdAndDropsItFromTheRoster() {
    let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
    controller.applyRemoteViewers([.init(viewerID: "v1", machineName: "Air", sessions: ["s1"], since: "…")])
    controller.disconnectViewer("v1")
    XCTAssertEqual(controller.connectionDouble.disconnectedViewerIDs, ["v1"])
}
```

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.**
1. `SettingsKeys.swift`: `static let remoteControlBlocked = "remote_control_blocked"`.
2. `WorkspaceWindowController`: hold `remoteViewers: [SessionConnection.RemoteViewer]` from `connection.onRemoteViewers` (and one `listViewers` call after connect); derive `remoteViewerCount(forWorkspace:)` (machines attached to any pane of that workspace) and `remoteViewerNames(forPane:)`; `disconnectViewer(_:)` calls through to the connection; `toggleRemoteControl` writes `"[]"` to `remoteControlBlocked` when switching a workspace **on**.
3. `WorkspacesTree`: a `display` glyph plus count beside the globe on host workspace rows, hidden at zero, tooltip naming the machines; clicking it calls a new `onShowViewers?(workspaceID)`.
4. `WorkspaceWindowController`: that callback opens an `NSPopover` listing machines (name, since, panes) each with a **Disconnect** button whose copy says "Blocked until you turn Remote Control off and on again".
5. `PaneFilmstripItemView`: when a pane has viewers, its `detail` line becomes `"􀫊 <machine>"` (remote glyph + name; join with ", " for several).

- [ ] **Step 4: Run the tests** (`RemotePresenceTests`, `WorkspaceShellTests`, `PaneFilmstripTests`) then the full suite — only the known failures. **Step 5: Commit and push:** `feat(macos): the host sees who is watching and can disconnect them`

---

### Task 11: Package the build

- [ ] **Step 1:** `git pull --ff-only origin main`, confirm a clean tree, then `scripts/rebuild-app.sh` (packaging rule; it bumps the build version itself — never bump by hand).
- [ ] **Step 2:** Verify the app relaunched (`pgrep -x OmniAgent`; `open -a OmniAgent` if empty) and commit the version bump the script produced.
- [ ] **Step 3:** Report the DMG path for the second Mac.

---

## Self-review

- **Spec coverage:** §1 sizing → T1 (daemon half) + T7 (viewer half); §2 projection v2 → T4 (writer) + T2 (reader) + T8 (rendering); §3 discovery → T5 (denial classification) + T6 (re-dial, refresh); §4 picker → T9; §5 presence/kick → T3 (daemon) + T5 (transport) + T10 (UI); §6 failure modes → covered by T1/T5/T6/T3 tests; §7 invariants → T1 (resize denied), T3 (local-only, blocked Hello, no viewer push), phase-1 tests unchanged; §8 out of scope respected; §9 order → the wave plan above.
- **Deviation from the spec, recorded:** the spec said "`SnapshotPayload` gains `cols` and `rows`". There is no such struct — snapshot and output share the raw `[u16 id_len][id][bytes]` payload (`protocol.rs:395`), which has no room for fields. T1 therefore sends a `SessionResized` frame immediately before the snapshot on attach, which is strictly better: one mechanism serves both the initial size and later changes, and no wire format changes.
- **Type consistency:** `SessionSizePayload{id,cols,rows}` (T1) ↔ `onSessionSize(String, UInt16, UInt16)` (T5) ↔ `remoteGrid` (T7); `ViewerSummaryPayload{viewer_id,machine_name,sessions,since}` (T3) ↔ `SessionConnection.RemoteViewer{viewerID,machineName,sessions,since}` (T5) ↔ `applyRemoteViewers` (T10); `RemoteControlProjection.Payload` v2 (T4) ↔ `remote_session_ids` walking `panes[].id` (T2) ↔ `treeEntries` (T4) used by T8 and T9; `BLOCKED_VIEWERS_KEY` (T3) ↔ `SettingsKey.remoteControlBlocked` (T10), both `"remote_control_blocked"`.

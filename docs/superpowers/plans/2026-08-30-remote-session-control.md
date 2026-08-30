# Remote Session Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user signed in on a second Mac sees the sessions of every workspace they enabled Remote Control on, and types into them with predictive local echo, through a relay on `relay.omni-agent.ai`.

**Architecture:** The daemon keeps one outbound control WebSocket to the relay and, per viewer, dials a data WebSocket over which its *existing* per-connection handler runs with a `Remote` trust level (allowlist + projection check). The relay (a second Deployment in `OmniAgent-Core`, same image) is a dumb byte pipe keyed by device; the app gets a WebSocket transport under the unchanged `SessionConnection`, a per-workspace toggle that writes the `remote_control` projection, a sidebar section per online machine, and a mosh-style predictive echo overlay. The daemon protocol does not change.

**Tech Stack:** Rust (tokio, tokio-tungstenite/rustls, tokio-util), Swift/AppKit (`URLSessionWebSocketTask`, `Network.framework` in tests), Python 3.12 (FastAPI WebSockets, SQLAlchemy async, Alembic), K3s/Kustomize, the BDN edge nginx ConfigMap.

**Spec:** `docs/superpowers/specs/2026-08-30-remote-session-control-design.md` — read it first; every task below argues from it.

## Global Constraints

- Daemon `PROTOCOL_VERSION` stays `1`; no new `MessageKind`. The MCP contract is untouched.
- Relay hostnames: production `relay.omni-agent.ai`, staging `relay.omni-agent.dev`. Relay port in-cluster `8081`.
- Settings rows (brain.db `settings` table, written by the app, read by the daemon): `remote_control` (projection), `remote_control_workspaces` (enabled ids), `relay_device_token` (`{"device_id","token","name","relay_url"}`).
- Remote allowlist (daemon): `Hello, ListSessions (filtered), Attach, Input, Resize, Interrupt, Detach, GetSetting("remote_control")`. Everything else → `Error`.
- Glyphs: host workspace rows `globe`; viewer rows and the **Resume remote session…** menu item `desktopcomputer.and.arrow.down`.
- Deviation from the spec, decided during planning: the relay Service is `ClusterIP` (the edge nginx proxies in-cluster by name), **not** a MetalLB `LoadBalancer`; no `10.1.2.8`/`.13` IPs. The relay URL travels inside the `relay_device_token` row instead of an `OMNIAGENT_RELAY_URL` env var, so the daemon needs no environment plumbing.
- Relay: single replica, in-process registry — `# ponytail: single replica, in-process registry; redis-routed splice if we ever need >1`.
- Commit trailers on every commit: `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>` and `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Use `git -c core.fsmonitor=false commit`, stage **only your own files by path** (this tree is shared with other sessions; never `git add -A`, never stash), and push after each commit.
- Tests: Rust `cargo test -p omniagent-pty-daemon` (export `PATH="$HOME/.cargo/bin:$PATH"`); macOS `caffeinate -disu ./macos/build.sh test` for the full suite, or `xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -only-testing:OmniAgentTests/<Class>` for one class (no `-derivedDataPath`); Core `cd OmniAgent-Core && .venv/bin/python -m pytest tests/test_relay.py -v`.
- Known pre-existing failures (2026-08-30, not yours): daemon `server_protocol` timeouts under load, the divider-drag test, hover-card and ingest git-cochange flakes.

## Repos and paths

| Track | Repo | Path |
|---|---|---|
| A | OmniAgent-ADE | `/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/crates/omniagent-pty-daemon` |
| B | OmniAgent-ADE | `/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos` |
| C | OmniAgent-Core | `/Users/bonando/Documents/Bruno.Digital/OmniAgent-Core` |
| D | BDN-nginx | `/Users/bonando/Documents/Bruno.Digital/BDN-nginx/BDN-nginx` (this inner dir is the git repo) |

## Dependency graph / parallelism

```
T0 (pbxproj registration)
 ├─ A1 → A2                       (Rust, sequential)
 ├─ B1 ─┐
 ├─ B2 ─┼─ B4 → B5                (Swift; B1, B2, B3 parallel; B4 after B1+B2; B5 after B4)
 ├─ B3 ─┘
 └─ C1 → C2 → D1 → D2             (Core → manifests → nginx → staging deploy)
                      └─ E1 (end-to-end on staging) → E2 (production + docs + rebuild-app)
```

Suggested subagent models: A1, A2, B1, B3, B4, C1 → default (Fable); T0, B2, B5, C2, D1, D2, E2 → `opus`.

---

## File structure

**ADE daemon (`crates/omniagent-pty-daemon/src/`)**
- `server.rs` — modify: `ClientTrust`, `ClientContext`, generic `serve_client`, remote authorizer, `settings_changed` notify, optional relay spawn.
- `relay.rs` — create: control/data WebSocket client, `run_relay`, `WsByteStream`.
- `lib.rs` — modify: `pub mod relay;` + re-exports.
- `tests/remote_authz.rs`, `tests/relay_loopback.rs` — create.

**ADE app (`macos/OmniAgent/`)**
- `SessionConnection.swift` — modify: `SessionTransport` (unix socket | WebSocket).
- `RelayClient.swift` — create: REST client for `/v1/relay/devices`.
- `RemoteControlProjection.swift` — create: pure builder/codec of the `remote_control` row.
- `RemoteMachinesModel.swift` — create: polls devices, owns one `SessionConnection` per online machine, holds projections.
- `PredictiveEchoModel.swift` — create: pure prediction/reconcile state machine.
- `PredictiveEchoOverlayView.swift` — create: draws predictions above the terminal.
- `SettingsKeys.swift`, `WorkspaceContextMenu.swift`, `WorkspacesTree.swift`, `NavigationSidebar.swift`, `WorkspaceWindowController.swift`, `WorkspacesHeaderMenus.swift`, `CommandPalette.swift`, `TerminalSurfaceView.swift`, `PaneDescriptor`-bearing file, `AppDelegate.swift` — modify.
- Tests (`macos/OmniAgentTests/`): `SessionConnectionWebSocketTests.swift`, `RelayClientTests.swift`, `RemoteControlProjectionTests.swift`, `RemoteMachinesModelTests.swift`, `PredictiveEchoModelTests.swift` — create; `CommandPaletteTests.swift` — modify.

**Core (`OmniAgent-Core/`)**
- `omniagent/api/jwt_auth.py` — modify: `decode_access_token(token) -> dict | None`.
- `omniagent/db/models.py` — modify: `RelayDevice`.
- `omniagent/db/migrations/versions/033_relay_devices.py` — create.
- `omniagent/relay/__init__.py`, `omniagent/relay/main.py` — create.
- `tests/test_relay.py` — create.
- `dockerfiles/Dockerfile.relay`, `k3s/base/relay/deployment.yaml`, `k3s/base/relay/service.yaml` — create; `k3s/base/kustomization.yaml`, `k3s/overlays/staging/kustomization.yaml`, `deploy.sh`, `Makefile` — modify.

**BDN-nginx** — `nginx-configmap.yaml` — modify: map entries + `relay` server block.

---

### Task T0: Register the new Swift files in the Xcode project up front

The project is a classic `.pbxproj` (no synchronized groups). Registering stubs first means B1–B5 never edit `project.pbxproj` concurrently (same pattern as commit `83f267c`).

**Files:**
- Create (one-line stubs): `macos/OmniAgent/RelayClient.swift`, `macos/OmniAgent/RemoteControlProjection.swift`, `macos/OmniAgent/RemoteMachinesModel.swift`, `macos/OmniAgent/PredictiveEchoModel.swift`, `macos/OmniAgent/PredictiveEchoOverlayView.swift`
- Create (one-line stubs): `macos/OmniAgentTests/SessionConnectionWebSocketTests.swift`, `macos/OmniAgentTests/RelayClientTests.swift`, `macos/OmniAgentTests/RemoteControlProjectionTests.swift`, `macos/OmniAgentTests/RemoteMachinesModelTests.swift`, `macos/OmniAgentTests/PredictiveEchoModelTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the stubs**

Each app stub: `import Foundation` + `// Filled in by the remote-session-control plan.` Each test stub: `import XCTest` + the same comment.

- [ ] **Step 2: Register each file in `project.pbxproj`**

For each file add four entries, mirroring `HomeViewTests.swift` (`project.pbxproj:56, 263, 530, 814`): a `PBXBuildFile` (`… in Sources`), a `PBXFileReference` (`lastKnownFileType = sourcecode.swift; path = <name>; sourceTree = "<group>";`), a child entry in the `OmniAgent` group (app files) or the `OmniAgentTests` group (test files), and an entry in the matching target's `PBXSourcesBuildPhase` `files` list. Generate the 24-hex ids with `uuidgen | tr -d - | cut -c1-24 | tr a-f A-F`.

- [ ] **Step 3: Verify the project still builds and the test target links**

Run: `./macos/build.sh build` — Expected: `** BUILD SUCCEEDED **`.
Run: `xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -only-testing:OmniAgentTests/CommandPaletteTests 2>&1 | tail -3` — Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit and push**

```bash
git add macos/OmniAgent.xcodeproj/project.pbxproj macos/OmniAgent/RelayClient.swift macos/OmniAgent/RemoteControlProjection.swift macos/OmniAgent/RemoteMachinesModel.swift macos/OmniAgent/PredictiveEchoModel.swift macos/OmniAgent/PredictiveEchoOverlayView.swift macos/OmniAgentTests/SessionConnectionWebSocketTests.swift macos/OmniAgentTests/RelayClientTests.swift macos/OmniAgentTests/RemoteControlProjectionTests.swift macos/OmniAgentTests/RemoteMachinesModelTests.swift macos/OmniAgentTests/PredictiveEchoModelTests.swift
git -c core.fsmonitor=false commit -m "chore(macos): register remote-session-control files up front" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task A1: Daemon — `ClientTrust`, generic `serve_client`, remote authorizer

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (accept loop 143-170, `handle_client` 207-660, helpers 826-870)
- Modify: `crates/omniagent-pty-daemon/src/lib.rs`
- Test: `crates/omniagent-pty-daemon/tests/remote_authz.rs`

**Interfaces:**
- Produces (all `pub`, re-exported from `lib.rs`):
  ```rust
  pub enum ClientTrust { Local, Remote }
  pub struct ClientContext { pub registry: SessionRegistry, pub settings: Arc<std::sync::Mutex<Store>>, pub data_dir: PathBuf, pub ingestion: IngestionState, pub settings_changed: Arc<tokio::sync::Notify> }
  impl DaemonServer { pub fn client_context(&self) -> ClientContext }
  pub async fn serve_client<S: AsyncRead + AsyncWrite + Unpin + Send + 'static>(stream: S, ctx: ClientContext, trust: ClientTrust) -> anyhow::Result<()>
  pub const REMOTE_CONTROL_KEY: &str = "remote_control";
  pub fn remote_session_ids(store: &Store) -> HashSet<String>;
  pub fn authorize_remote(frame: &Frame, allowed: &HashSet<String>) -> Result<(), String>;
  ```
- A2 consumes `serve_client`, `ClientContext`, `ClientTrust::Remote`, `settings_changed`.

- [ ] **Step 1: Write the failing tests**

`tests/remote_authz.rs` (copy the `brain_data_dir` / `command_session` helpers from `tests/server_protocol.rs:25-27,122-132`; write a small client over `tokio::io::DuplexStream` using `omniagent_pty_daemon::protocol::{read_frame, write_frame, Frame, MessageKind}`):

```rust
use std::collections::HashSet;
use omniagent_pty_daemon::{serve_client, ClientTrust, DaemonServer};
use omniagent_pty_daemon::protocol::{read_frame, write_frame, Frame, MessageKind, SessionListPayload, SettingKey};
use tokio::io::DuplexStream;
use tokio::sync::oneshot;

const PROJECTION: &str = r#"{"workspaces":[{"id":"w1","name":"w1","sessions":[{"id":"s1","title":"one","engine":"shell","group":null}]}]}"#;

struct Duplex { stream: DuplexStream, request: u64 }
impl Duplex {
    async fn hello(mut self) -> Self {
        self.send(MessageKind::Hello, serde_json::json!({"protocol_version": 1})).await;
        assert_eq!(self.read().await.header.message_kind, MessageKind::HelloAck);
        self
    }
    async fn send(&mut self, kind: MessageKind, payload: impl serde::Serialize) -> u64 {
        self.request += 1;
        let frame = Frame::new(kind, self.request, serde_json::to_vec(&payload).unwrap());
        write_frame(&mut self.stream, &frame).await.unwrap();
        self.request
    }
    async fn read(&mut self) -> Frame {
        tokio::time::timeout(std::time::Duration::from_secs(4), read_frame(&mut self.stream)).await.unwrap().unwrap()
    }
}

async fn remote_client(root: &std::path::Path) -> (Duplex, oneshot::Sender<()>) {
    let server = DaemonServer::bind_with_data_dir(root.join("runtime").join("daemon.sock"), root.join("brain-data")).await.unwrap();
    let ctx = server.client_context();
    let (stop, stopped) = oneshot::channel();
    tokio::spawn(server.run_until(stopped));
    ctx.registry.create_session(command_session("s1", "cat")).unwrap();
    ctx.registry.create_session(command_session("s2", "cat")).unwrap();
    ctx.settings.lock().unwrap().set_setting("remote_control", PROJECTION).unwrap();
    ctx.settings.lock().unwrap().set_setting("auth_signed_in", "true").unwrap();
    let (client_side, server_side) = tokio::io::duplex(64 * 1024);
    tokio::spawn(serve_client(server_side, ctx, ClientTrust::Remote));
    (Duplex { stream: client_side, request: 0 }.hello().await, stop)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn remote_clients_only_list_and_attach_projected_sessions() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _stop) = remote_client(root.path()).await;

    client.send(MessageKind::ListSessions, serde_json::json!({})).await;
    let list = client.read().await;
    assert_eq!(list.header.message_kind, MessageKind::SessionList);
    let list: SessionListPayload = serde_json::from_slice(&list.payload).unwrap();
    assert_eq!(list.sessions, vec!["s1".to_string()]);

    client.send(MessageKind::Attach, serde_json::json!({"id": "s2", "after_sequence": null})).await;
    assert_eq!(client.read().await.header.message_kind, MessageKind::Error);

    client.send(MessageKind::Attach, serde_json::json!({"id": "s1", "after_sequence": null})).await;
    assert_eq!(client.read().await.header.message_kind, MessageKind::Snapshot);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn remote_clients_cannot_kill_create_or_read_other_settings() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _stop) = remote_client(root.path()).await;
    for (kind, payload) in [
        (MessageKind::Kill, serde_json::json!({"id": "s1"})),
        (MessageKind::CreateSession, serde_json::json!(command_session("s3", "cat"))),
        (MessageKind::SetSetting, serde_json::json!({"key": "remote_control", "value": "{}"})),
        (MessageKind::GetSetting, serde_json::json!(SettingKey { key: "auth_signed_in".into() })),
        (MessageKind::BrainListProjects, serde_json::json!({})),
    ] {
        client.send(kind, payload).await;
        let reply = client.read().await;
        assert_eq!(reply.header.message_kind, MessageKind::Error, "{kind:?} must be refused remotely");
    }
    client.send(MessageKind::GetSetting, serde_json::json!(SettingKey { key: "remote_control".into() })).await;
    let reply = client.read().await;
    assert_eq!(reply.header.message_kind, MessageKind::Response);
    assert!(String::from_utf8_lossy(&reply.payload).contains("w1"));
}

#[test]
fn authorize_remote_checks_the_raw_input_session_id() {
    use omniagent_pty_daemon::protocol::encode_raw_payload;
    let allowed: HashSet<String> = ["s1".to_string()].into_iter().collect();
    let ok = Frame::new(MessageKind::Input, 1, encode_raw_payload("s1", b"x").unwrap());
    let bad = Frame::new(MessageKind::Input, 2, encode_raw_payload("s2", b"x").unwrap());
    assert!(omniagent_pty_daemon::authorize_remote(&ok, &allowed).is_ok());
    assert!(omniagent_pty_daemon::authorize_remote(&bad, &allowed).is_err());
}
```

Adapt the `Hello` payload and the `Attach` payload field names to `protocol.rs` (`HelloPayload`, `AttachPayload { id, after_sequence }`) — read them, do not guess. If `CreateSession` is not `Serialize`, send `serde_json::json!({"id":"s3","command":"cat"})` shaped like the struct.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_authz`
Expected: compile errors — `serve_client`, `ClientTrust`, `client_context` do not exist.

- [ ] **Step 3: Implement**

In `server.rs`:

```rust
use std::collections::HashSet;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::Notify;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClientTrust { Local, Remote }

#[derive(Clone)]
pub struct ClientContext {
    pub registry: SessionRegistry,
    pub settings: Arc<std::sync::Mutex<Store>>,
    pub data_dir: PathBuf,
    pub ingestion: IngestionState,
    /// Poked after every successful `SetSetting`; the relay task watches it.
    pub settings_changed: Arc<Notify>,
}

pub type SharedWriter = Arc<Mutex<Box<dyn AsyncWrite + Unpin + Send>>>;

pub const REMOTE_CONTROL_KEY: &str = "remote_control";

pub fn remote_session_ids(store: &Store) -> HashSet<String> {
    let Some(raw) = store.get_setting(REMOTE_CONTROL_KEY).ok().flatten() else { return HashSet::new() };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else { return HashSet::new() };
    value["workspaces"].as_array().into_iter().flatten()
        .flat_map(|w| w["sessions"].as_array().cloned().unwrap_or_default())
        .filter_map(|s| s["id"].as_str().map(str::to_owned))
        .collect()
}

#[derive(serde::Deserialize)]
struct SessionRef { id: String }

/// The trust boundary for relayed clients. Err(reason) means "send Error, skip dispatch".
pub fn authorize_remote(frame: &Frame, allowed: &HashSet<String>) -> Result<(), String> {
    use MessageKind::*;
    let shared = |id: &str| allowed.contains(id).then_some(()).ok_or_else(|| format!("session {id} is not shared"));
    match frame.header.message_kind {
        Hello | ListSessions | Detach => Ok(()),
        Attach | Resize | Interrupt => shared(&parse_json::<SessionRef>(&frame.payload).map_err(|e| e.to_string())?.id),
        Input => shared(decode_raw_payload(&frame.payload).map_err(|e| e.to_string())?.0),
        GetSetting => {
            let key = parse_json::<SettingKey>(&frame.payload).map_err(|e| e.to_string())?.key;
            (key == REMOTE_CONTROL_KEY).then_some(()).ok_or_else(|| format!("setting {key} is not readable remotely"))
        }
        other => Err(format!("{other:?} is not allowed for remote clients")),
    }
}
```

Then:
1. Add `settings_changed: Arc<Notify>` to `DaemonServer` (created in `bind_with_data_dir`), and `pub fn client_context(&self) -> ClientContext` cloning the five fields.
2. Accept loop: do the `peer_cred` / `peer_uid_allowed` check **there** (skip the connection on failure), then `clients.spawn(serve_client(stream, ctx.clone(), ClientTrust::Local))`.
3. Rename `handle_client` → `pub async fn serve_client<S>(stream: S, ctx: ClientContext, trust: ClientTrust) -> Result<()> where S: AsyncRead + AsyncWrite + Unpin + Send + 'static`. Replace `stream.into_split()` with `let (mut reader, writer) = tokio::io::split(stream); let writer: SharedWriter = Arc::new(Mutex::new(Box::new(writer)));`. Change every helper that takes `&Arc<Mutex<OwnedWriteHalf>>` (`send_response`, `send_error`, `send_json`, `send_frame`, `send_attach_state`, the `Attachment` forwarding task) to take `&SharedWriter`. Destructure `ctx` into the old local names so the dispatch body is untouched.
4. At the top of the read loop, after computing `request`:
   ```rust
   let allowed = (trust == ClientTrust::Remote)
       .then(|| lock_store(&settings).map(|s| remote_session_ids(&s)).unwrap_or_default());
   if let Some(allowed) = &allowed {
       if let Err(reason) = authorize_remote(&frame, allowed) {
           if send_error(&writer, request, reason).await.is_err() { break; }
           continue;
       }
   }
   ```
5. `ListSessions` arm: `let mut sessions = registry.list(); if let Some(allowed) = &allowed { sessions.retain(|id| allowed.contains(id)); }`.
6. `SetSetting` arm: after a successful `set_setting`, `settings_changed.notify_one();`.
7. `lib.rs`: `pub use server::{authorize_remote, remote_session_ids, serve_client, ClientContext, ClientTrust, SharedWriter, REMOTE_CONTROL_KEY};`.

- [ ] **Step 4: Run the tests**

Run: `cargo test -p omniagent-pty-daemon --test remote_authz` — Expected: 3 passed.
Run: `cargo test -p omniagent-pty-daemon` — Expected: everything that passed before still passes (`server_protocol` timeouts are pre-existing; compare against `git stash`-free baseline by running the same command on a clean `git worktree add /tmp/base main` if in doubt).
Run: `cargo clippy -p omniagent-pty-daemon --all-targets` — Expected: no new warnings.

- [ ] **Step 5: Commit and push**

```bash
git add crates/omniagent-pty-daemon/src/server.rs crates/omniagent-pty-daemon/src/lib.rs crates/omniagent-pty-daemon/tests/remote_authz.rs
git -c core.fsmonitor=false commit -m "feat(daemon): serve clients over any stream with a Local/Remote trust level" -m "Remote clients are confined to the remote_control projection: allowlisted kinds, session ids checked per frame, ListSessions filtered, only the projection row readable. The unix-socket path is unchanged; the peer-UID check moved into the accept loop." -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task A2: Daemon — relay client (`relay.rs`)

**Files:**
- Create: `crates/omniagent-pty-daemon/src/relay.rs`
- Modify: `crates/omniagent-pty-daemon/Cargo.toml`, `src/lib.rs`, `src/server.rs` (`serve()` spawns the relay when enabled; `run_daemon` enables it)
- Test: `crates/omniagent-pty-daemon/tests/relay_loopback.rs`

**Interfaces:**
- Consumes: `serve_client`, `ClientContext`, `ClientTrust::Remote`, `remote_session_ids`, `settings_changed` (A1).
- Produces:
  ```rust
  pub const DEVICE_TOKEN_KEY: &str = "relay_device_token";
  #[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize)]
  pub struct DeviceCredential { pub device_id: String, pub token: String, pub name: String, pub relay_url: String }
  pub fn relay_config(store: &Store) -> Option<DeviceCredential>;   // Some iff the token row parses AND remote_session_ids(store) is non-empty
  pub async fn run_relay(ctx: ClientContext);                        // never returns; drives control + data connections
  impl DaemonServer { pub fn with_relay(self) -> Self }              // run_daemon() calls it; bind_with_data_dir() does not (tests drive run_relay directly)
  ```
- Control channel: `GET {relay_url}/v1/device`, header `Authorization: Bearer <token>`, first message text `{"hostname": <name>, "daemon_version": env!("CARGO_PKG_VERSION")}`, then text messages `{"open": "<conn_id>"}` from the relay; Ping every 30 s.
- Data channel: `GET {relay_url}/v1/device/conn/{conn_id}`, same header; binary messages carry the byte stream (frames may span messages — both decoders buffer).
- `relay_url` is `https://…` in the row; convert to `wss://` (`http://` → `ws://` for tests).

- [ ] **Step 1: Add dependencies**

`Cargo.toml` `[dependencies]`: `tokio-tungstenite = { version = "0.26", features = ["rustls-tls-webpki-roots"] }`, `tokio-util = { version = "0.7", features = ["io"] }`, `futures-util = "0.3"`, `bytes = "1"`. `[dev-dependencies]`: keep `tempfile`, add `tokio-tungstenite = "0.26"` (plain, for the in-test server). Run `cargo fetch` and pin to whatever version resolves if `0.26` does not exist.

- [ ] **Step 2: Write the failing loopback test**

`tests/relay_loopback.rs`:

```rust
use futures_util::{SinkExt, StreamExt};
use omniagent_pty_daemon::protocol::{Frame, MessageKind};
use omniagent_pty_daemon::{run_relay, DaemonServer};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::{handshake::server::{Request, Response}, Message};

// brain_data_dir / command_session helpers as in tests/server_protocol.rs

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn daemon_dials_the_relay_and_serves_a_viewer_over_the_data_socket() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    let server = DaemonServer::bind_with_data_dir(root.path().join("runtime").join("daemon.sock"), root.path().join("brain-data")).await.unwrap();
    let ctx = server.client_context();
    let (_stop, stopped) = tokio::sync::oneshot::channel::<()>();
    tokio::spawn(server.run_until(stopped));
    ctx.registry.create_session(command_session("s1", "cat")).unwrap();
    {
        let store = ctx.settings.lock().unwrap();
        store.set_setting("remote_control", r#"{"workspaces":[{"id":"w","name":"w","sessions":[{"id":"s1","title":"t","engine":"shell","group":null}]}]}"#).unwrap();
        store.set_setting("relay_device_token", &format!(r#"{{"device_id":"dev1","token":"tok","name":"Test Mac","relay_url":"http://127.0.0.1:{port}"}}"#)).unwrap();
    }
    ctx.settings_changed.notify_one();
    tokio::spawn(run_relay(ctx.clone()));

    // --- play relay: control connection ---
    let (tcp, _) = listener.accept().await.unwrap();
    let mut seen_path = String::new(); let mut seen_auth = String::new();
    let mut control = tokio_tungstenite::accept_hdr_async(tcp, |req: &Request, resp: Response| {
        seen_path = req.uri().path().to_string();
        seen_auth = req.headers().get("authorization").map(|v| v.to_str().unwrap().to_string()).unwrap_or_default();
        Ok(resp)
    }).await.unwrap();
    assert_eq!(seen_path, "/v1/device");
    assert_eq!(seen_auth, "Bearer tok");
    let hello = control.next().await.unwrap().unwrap();
    assert!(hello.to_text().unwrap().contains("Test Mac"));
    control.send(Message::Text(r#"{"open":"c1"}"#.into())).await.unwrap();

    // --- play relay: data connection, then act as the viewer ---
    let (tcp, _) = listener.accept().await.unwrap();
    let mut path = String::new();
    let mut data = tokio_tungstenite::accept_hdr_async(tcp, |req: &Request, resp: Response| { path = req.uri().path().to_string(); Ok(resp) }).await.unwrap();
    assert_eq!(path, "/v1/device/conn/c1");

    let hello = Frame::new(MessageKind::Hello, 1, serde_json::to_vec(&serde_json::json!({"protocol_version": 1})).unwrap());
    data.send(Message::Binary(hello.encode().unwrap().into())).await.unwrap();
    let ack = read_frame_from_ws(&mut data).await;
    assert_eq!(ack.header.message_kind, MessageKind::HelloAck);

    let attach = Frame::new(MessageKind::Attach, 2, serde_json::to_vec(&serde_json::json!({"id": "s1", "after_sequence": null})).unwrap());
    data.send(Message::Binary(attach.encode().unwrap().into())).await.unwrap();
    assert_eq!(read_frame_from_ws(&mut data).await.header.message_kind, MessageKind::Snapshot);

    let kill = Frame::new(MessageKind::Kill, 3, serde_json::to_vec(&serde_json::json!({"id": "s1"})).unwrap());
    data.send(Message::Binary(kill.encode().unwrap().into())).await.unwrap();
    assert_eq!(read_frame_from_ws(&mut data).await.header.message_kind, MessageKind::Error);
}

/// Accumulates binary messages until one whole frame decodes (frames may span messages).
async fn read_frame_from_ws<S>(ws: &mut S) -> Frame where S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin {
    let mut buf: Vec<u8> = Vec::new();
    loop {
        if buf.len() >= 16 {
            let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
            if buf.len() >= 16 + len { let frame = Frame::decode(&buf[..16 + len]).unwrap(); buf.drain(..16 + len); return frame; }
        }
        match tokio::time::timeout(std::time::Duration::from_secs(4), ws.next()).await.unwrap().unwrap().unwrap() {
            Message::Binary(b) => buf.extend_from_slice(&b),
            Message::Ping(_) | Message::Pong(_) => {}
            other => panic!("unexpected {other:?}"),
        }
    }
}
```

Add a second test `relay_disconnects_when_the_projection_empties`: after the control handshake, set `remote_control` to `{"workspaces":[]}` + `notify_one()`, and assert `control.next().await` yields `None`/`Close` within 4 s.

- [ ] **Step 3: Run to verify it fails**

Run: `cargo test -p omniagent-pty-daemon --test relay_loopback` — Expected: compile error, `run_relay` missing.

- [ ] **Step 4: Implement `relay.rs`**

```rust
use std::time::Duration;
use anyhow::Result;
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt, TryStreamExt};
use tokio::task::JoinSet;
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, http::header::AUTHORIZATION, Error as WsError, Message};
use tokio_tungstenite::connect_async;
use brain_core::Store;
use crate::server::{remote_session_ids, serve_client, ClientContext, ClientTrust};

pub const DEVICE_TOKEN_KEY: &str = "relay_device_token";
const PING_EVERY: Duration = Duration::from_secs(30);
const MAX_BACKOFF: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize)]
pub struct DeviceCredential { pub device_id: String, pub token: String, pub name: String, pub relay_url: String }

pub fn relay_config(store: &Store) -> Option<DeviceCredential> {
    let raw = store.get_setting(DEVICE_TOKEN_KEY).ok().flatten()?;
    let cred: DeviceCredential = serde_json::from_str(&raw).ok()?;
    (!remote_session_ids(store).is_empty()).then_some(cred)
}

fn ws_url(cred: &DeviceCredential, path: &str) -> String {
    let base = cred.relay_url.trim_end_matches('/');
    let base = base.replacen("https://", "wss://", 1).replacen("http://", "ws://", 1);
    format!("{base}{path}")
}

fn request(cred: &DeviceCredential, path: &str) -> Result<tokio_tungstenite::tungstenite::http::Request<()>> {
    let mut req = ws_url(cred, path).into_client_request()?;
    req.headers_mut().insert(AUTHORIZATION, format!("Bearer {}", cred.token).parse()?);
    Ok(req)
}

enum Outcome { Unauthorized, Dropped, ConfigChanged }

fn current(ctx: &ClientContext) -> Option<DeviceCredential> {
    ctx.settings.lock().ok().and_then(|s| { let _ = s.reopen_if_replaced(); relay_config(&s) })
}

pub async fn run_relay(ctx: ClientContext) {
    let mut backoff = Duration::from_secs(1);
    loop {
        let Some(cred) = current(&ctx) else { ctx.settings_changed.notified().await; continue };
        match control_session(&ctx, &cred).await {
            Outcome::Unauthorized => { tracing::warn!("relay rejected device token; waiting for a new one"); ctx.settings_changed.notified().await; backoff = Duration::from_secs(1); }
            Outcome::ConfigChanged => backoff = Duration::from_secs(1),
            Outcome::Dropped => { tokio::time::sleep(backoff).await; backoff = (backoff * 2).min(MAX_BACKOFF); }
        }
    }
}

async fn control_session(ctx: &ClientContext, cred: &DeviceCredential) -> Outcome {
    let req = match request(cred, "/v1/device") { Ok(r) => r, Err(_) => return Outcome::Dropped };
    let (ws, _) = match connect_async(req).await {
        Ok(ok) => ok,
        Err(WsError::Http(resp)) if matches!(resp.status().as_u16(), 401 | 403) => return Outcome::Unauthorized,
        Err(e) => { tracing::debug!("relay control connect failed: {e}"); return Outcome::Dropped }
    };
    let (mut sink, mut stream) = ws.split();
    let hello = serde_json::json!({"hostname": cred.name, "daemon_version": env!("CARGO_PKG_VERSION")});
    if sink.send(Message::Text(hello.to_string().into())).await.is_err() { return Outcome::Dropped }
    let mut data = JoinSet::new();     // dropped on return → every data connection is aborted
    let mut ping = tokio::time::interval(PING_EVERY);
    ping.tick().await;
    loop {
        tokio::select! {
            _ = ping.tick() => { if sink.send(Message::Ping(Bytes::new())).await.is_err() { return Outcome::Dropped } }
            msg = stream.next() => match msg {
                Some(Ok(Message::Text(text))) => {
                    if let Some(id) = serde_json::from_str::<serde_json::Value>(&text).ok().and_then(|v| v["open"].as_str().map(str::to_owned)) {
                        data.spawn(data_connection(ctx.clone(), cred.clone(), id));
                    }
                }
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return Outcome::Dropped,
                _ => {}
            },
            _ = ctx.settings_changed.notified() => {
                if current(ctx).as_ref() != Some(cred) { let _ = sink.close().await; return Outcome::ConfigChanged }
            }
            Some(_) = data.join_next(), if !data.is_empty() => {}
        }
    }
}

async fn data_connection(ctx: ClientContext, cred: DeviceCredential, conn_id: String) {
    let Ok(req) = request(&cred, &format!("/v1/device/conn/{conn_id}")) else { return };
    let Ok((ws, _)) = connect_async(req).await else { return };
    let (sink, stream) = ws.split();
    let reader = tokio_util::io::StreamReader::new(stream.filter_map(|m| async move {
        match m {
            Ok(Message::Binary(b)) => Some(Ok::<Bytes, std::io::Error>(b)),
            Ok(Message::Close(_)) | Err(_) => Some(Err(std::io::Error::new(std::io::ErrorKind::ConnectionReset, "relay closed"))),
            _ => None,
        }
    }));
    let writer = tokio_util::io::SinkWriter::new(tokio_util::io::CopyToBytes::new(
        sink.sink_map_err(|e| std::io::Error::new(std::io::ErrorKind::BrokenPipe, e)).with(|b: Bytes| async move { Ok::<_, std::io::Error>(Message::Binary(b)) }),
    ));
    let _ = serve_client(tokio::io::join(reader, writer), ctx, ClientTrust::Remote).await;
}
```

Fix up against the real tokio-tungstenite/tokio-util APIs as you compile (`Message::Text` takes `Utf8Bytes` in 0.26; `tokio::io::join` exists in tokio ≥ 1.36). Then: `lib.rs` gets `pub mod relay; pub use relay::{relay_config, run_relay, DeviceCredential, DEVICE_TOKEN_KEY};`. In `server.rs`: add `relay_enabled: bool` to `DaemonServer` (false in `bind_with_data_dir`), `pub fn with_relay(mut self) -> Self { self.relay_enabled = true; self }`, `serve()` does `if self.relay_enabled { tokio::spawn(run_relay(self.client_context())); }` before the loop, and `run_daemon` builds with `.with_relay()`.

- [ ] **Step 5: Run the tests**

Run: `cargo test -p omniagent-pty-daemon --test relay_loopback` — Expected: 2 passed.
Run: `cargo test -p omniagent-pty-daemon && cargo clippy -p omniagent-pty-daemon --all-targets` — Expected: no regressions, no new warnings.
Run: `cargo build --release -p omniagent-pty-daemon` — Expected: builds (the universal app build embeds it).

- [ ] **Step 6: Commit and push**

```bash
git add crates/omniagent-pty-daemon/Cargo.toml Cargo.lock crates/omniagent-pty-daemon/src/relay.rs crates/omniagent-pty-daemon/src/lib.rs crates/omniagent-pty-daemon/src/server.rs crates/omniagent-pty-daemon/tests/relay_loopback.rs
git -c core.fsmonitor=false commit -m "feat(daemon): dial the relay and serve remote viewers over data WebSockets" -m "One outbound control socket while the remote_control projection is non-empty and a device token exists; each {\"open\"} spawns a data socket that runs serve_client(Remote). 401/403 stops retrying until the token row changes; empty projection closes everything." -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task B1: App — WebSocket transport in `SessionConnection`

**Files:**
- Modify: `macos/OmniAgent/SessionConnection.swift` (init 169-183, `openConnection` ~575-620, `readAvailable` 649-666, `send` 852-870, `closeConnection` ~885-895)
- Test: `macos/OmniAgentTests/SessionConnectionWebSocketTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum SessionTransport {
      case unixSocket(URL)
      case webSocket(URL, bearer: () -> String?)   // URL is wss://…/v1/viewer/<device_id>; bearer read at every (re)connect
  }
  final class SessionConnection {
      init(transport: SessionTransport, reconnectDelay: TimeInterval = 0.25, callbackQueue: DispatchQueue = .main)
      convenience init(socketURL: URL, reconnectDelay: TimeInterval = 0.25, callbackQueue: DispatchQueue = .main)  // unchanged call sites
      var isRemote: Bool { get }   // true for .webSocket
  }
  ```
- B4 consumes `SessionConnection(transport: .webSocket(…))` and `isRemote`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Network
@testable import OmniAgent

final class SessionConnectionWebSocketTests: XCTestCase {
    /// A one-shot WebSocket server that answers the first frame it receives (Hello) with HelloAck.
    private final class FakeRelay {
        let listener: NWListener
        var port: UInt16 { listener.port!.rawValue }
        var receivedAuthorization: String?
        private var connection: NWConnection?
        init() throws {
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
        }
        func start() {
            listener.newConnectionHandler = { [weak self] conn in
                self?.connection = conn
                conn.start(queue: .global())
                self?.receive(on: conn)
            }
            listener.start(queue: .global())
        }
        private func receive(on conn: NWConnection) {
            conn.receiveMessage { [weak self] data, context, _, _ in
                guard let self, let data else { return }
                if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   meta.opcode == .binary {
                    var decoder = FrameDecoder()
                    if let frame = try? decoder.append(data).first, frame.kind == .hello {
                        let ack = SessionFrame(kind: .helloAck, requestOrSequence: frame.requestOrSequence,
                                               payload: try! JSONEncoder().encode(["protocol_version": 1]))
                        let m = NWProtocolWebSocket.Metadata(opcode: .binary)
                        conn.send(content: try! ack.encoded(), contentContext: NWConnection.ContentContext(identifier: "ack", metadata: [m]), completion: .idempotent)
                    }
                }
                self.receive(on: conn)
            }
        }
    }

    func testWebSocketTransportCompletesTheHelloHandshake() throws {
        let relay = try FakeRelay()
        relay.start()
        let ready = expectation(description: "listener ready")
        relay.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        wait(for: [ready], timeout: 5)

        let url = URL(string: "ws://127.0.0.1:\(relay.port)/v1/viewer/dev1")!
        let connection = SessionConnection(transport: .webSocket(url, bearer: { "viewer-token" }), callbackQueue: .main)
        let connected = expectation(description: "connected")
        connection.onStateChange = { state in if case .connected = state { connected.fulfill() } }
        connection.connect()
        wait(for: [connected], timeout: 5)
        XCTAssertTrue(connection.isRemote)
        connection.disconnect()
    }
}
```

Adapt `.connected` to the real `ConnectionState` case that fires after `HelloAck` (read `SessionConnection.swift:100-111`). If `NWListener` needs the `Sec-WebSocket-Protocol` handshake tweaks, keep the fake minimal — it only has to accept and answer one binary message.

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -only-testing:OmniAgentTests/SessionConnectionWebSocketTests 2>&1 | grep -E "error:|TEST"` — Expected: compile error, no `init(transport:)`.

- [ ] **Step 3: Implement**

In `SessionConnection.swift`:
- Add `enum SessionTransport` (above the class). Replace `private let socketURL: URL` with `private let transport: SessionTransport`; `var isRemote: Bool { if case .webSocket = transport { return true }; return false }`.
- `init(transport:…)` stores it; `convenience init(socketURL:…)` forwards `.unixSocket(socketURL)`.
- Add `private var webSocketTask: URLSessionWebSocketTask?` and `private var pingTimer: DispatchSourceTimer?`.
- In `openConnection()`: `switch transport { case .unixSocket(let url): <existing body using url.path> case .webSocket(let url, let bearer): openWebSocket(url, bearer: bearer()) }`.
- ```swift
  private func openWebSocket(_ url: URL, bearer: String?) {
      var request = URLRequest(url: url)
      if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
      let task = URLSession.shared.webSocketTask(with: request)
      webSocketTask = task
      frameDecoder = FrameDecoder()
      task.resume()
      receiveNextMessage(task)
      let timer = DispatchSource.makeTimerSource(queue: ioQueue)
      timer.schedule(deadline: .now() + 30, repeating: 30)
      timer.setEventHandler { [weak task] in task?.sendPing { _ in } }
      timer.resume()
      pingTimer = timer
      sendHello()   // whatever the unix path calls right after connecting — reuse it verbatim
  }
  private func receiveNextMessage(_ task: URLSessionWebSocketTask) {
      task.receive { [weak self] result in
          guard let self else { return }
          self.ioQueue.async {
              guard self.webSocketTask === task else { return }
              switch result {
              case .success(.data(let data)):
                  do { for frame in try self.frameDecoder.append(data) { self.handle(frame) } }
                  catch { self.closeConnection(error: error); return }
              case .success(.string): break
              case .success: break
              case .failure(let error): self.closeConnection(error: error); return
              }
              self.receiveNextMessage(task)
          }
      }
  }
  ```
- `send(_ frame:)`: `if let task = webSocketTask { task.send(.data(try frame.encoded())) { [weak self] error in if let error { self?.ioQueue.async { self?.closeConnection(error: error) } } }; return }` before the Darwin write path.
- `closeConnection`: also `pingTimer?.cancel(); pingTimer = nil; webSocketTask?.cancel(with: .goingAway, reason: nil); webSocketTask = nil`.
- Reconnect/backoff/re-attach logic is shared and untouched.

- [ ] **Step 4: Run the tests**

Run: `xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -only-testing:OmniAgentTests/SessionConnectionWebSocketTests 2>&1 | tail -3` — Expected: `** TEST SUCCEEDED **`.
Run: `xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -only-testing:OmniAgentTests/FrameCodecTests -only-testing:OmniAgentTests/DaemonPersistenceTests 2>&1 | tail -3` — Expected: still succeeds.

- [ ] **Step 5: Commit and push**

```bash
git add macos/OmniAgent/SessionConnection.swift macos/OmniAgentTests/SessionConnectionWebSocketTests.swift
git -c core.fsmonitor=false commit -m "feat(macos): SessionConnection speaks the daemon protocol over a WebSocket transport" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task B2: App — host side: `RelayClient`, `RemoteControlProjection`, Enable Remote Control, globe glyph

**Files:**
- Create: `macos/OmniAgent/RelayClient.swift`, `macos/OmniAgent/RemoteControlProjection.swift`
- Modify: `macos/OmniAgent/SettingsKeys.swift`, `macos/OmniAgent/WorkspaceContextMenu.swift:15-42`, `macos/OmniAgent/WorkspacesTree.swift` (`WorkspaceTreeEntry` 16-30, `WorkspaceRowView` 35-98), `macos/OmniAgent/WorkspaceWindowController.swift` (`workspaceContextMenu(for:)` ~878, `persistLayout()` 4860-4867, the place `WorkspaceTreeEntry`s are built)
- Test: `macos/OmniAgentTests/RelayClientTests.swift`, `macos/OmniAgentTests/RemoteControlProjectionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  extension SettingsKey {
      static let remoteControl = "remote_control"
      static let remoteControlWorkspaces = "remote_control_workspaces"
      static let relayDeviceToken = "relay_device_token"
  }
  enum RemoteControlProjection {
      struct Session: Codable, Equatable { let id: String; let title: String; let engine: String; let group: String? }
      struct Workspace: Codable, Equatable { let id: String; let name: String; let sessions: [Session] }
      struct Payload: Codable, Equatable { let workspaces: [Workspace] }
      static func build(tabs: [PersistedTab], enabledWorkspaceIDs: Set<String>, workspaceLabels: [String: String]) -> Payload
      static func encode(_ payload: Payload) -> String
      static func decode(_ raw: String?) -> Payload          // {"workspaces":[]} on nil/garbage
      static func encodeEnabled(_ ids: Set<String>) -> String  // JSON array
      static func decodeEnabled(_ raw: String?) -> Set<String>
  }
  final class RelayClient {
      static let shared = RelayClient()
      struct Device: Codable, Equatable { let deviceID: String; let name: String; let online: Bool; let lastSeenAt: String? }
      struct Registration: Codable, Equatable { let deviceID: String; let token: String }
      let baseURL: URL   // UserDefaults "OMNIAGENT_RELAY_BASE_URL" override, default https://relay.omni-agent.ai
      init(baseURL: URL? = nil, session: URLSession = .shared, accessToken: @escaping () -> String? = { AuthClient.shared.accessToken })
      func registerDevice(name: String) async throws -> Registration      // POST /v1/relay/devices {"name"}
      func listDevices() async throws -> [Device]                          // GET  /v1/relay/devices
      func deleteDevice(id: String) async throws                           // DELETE /v1/relay/devices/{id}
      func viewerSocketURL(deviceID: String) -> URL                        // wss://<host>/v1/viewer/<id>
      func deviceTokenRow(_ r: Registration, name: String) -> String      // JSON {"device_id","token","name","relay_url": baseURL}
  }
  ```
- Workspace id = `PersistedTab.project` (the same string `WorkspaceTreeEntry.id` / `workspaceContextMenu(for:)` carry — confirm in `SessionOutline.group`). Session id = `PersistedTab.id` (== daemon session id). Title = `label ?? groupLabel ?? id`. Engine = `engine.rawValue`.
- B4 consumes `RelayClient`, `RemoteControlProjection.decode`, the settings keys.

- [ ] **Step 1: Write the failing tests**

`RemoteControlProjectionTests.swift`:
```swift
import XCTest
@testable import OmniAgent

final class RemoteControlProjectionTests: XCTestCase {
    private func tab(_ id: String, project: String, label: String? = nil, group: String? = nil) -> PersistedTab {
        var t = PersistedTab(project: project, engine: .shell, cwd: project)   // adapt to the real memberwise init
        t.id = id; t.label = label; t.group = group
        return t
    }
    func testOnlyEnabledWorkspacesAreProjected() {
        let payload = RemoteControlProjection.build(
            tabs: [tab("s1", project: "/a", label: "one"), tab("s2", project: "/b")],
            enabledWorkspaceIDs: ["/a"], workspaceLabels: ["/a": "Alpha"])
        XCTAssertEqual(payload.workspaces.map(\.id), ["/a"])
        XCTAssertEqual(payload.workspaces[0].name, "Alpha")
        XCTAssertEqual(payload.workspaces[0].sessions.map(\.id), ["s1"])
        XCTAssertEqual(payload.workspaces[0].sessions[0].title, "one")
        XCTAssertEqual(payload.workspaces[0].sessions[0].engine, "shell")
    }
    func testEncodeDecodeRoundTripsAndToleratesGarbage() {
        let payload = RemoteControlProjection.build(tabs: [tab("s1", project: "/a")], enabledWorkspaceIDs: ["/a"], workspaceLabels: [:])
        XCTAssertEqual(RemoteControlProjection.decode(RemoteControlProjection.encode(payload)), payload)
        XCTAssertEqual(RemoteControlProjection.decode("not json"), .init(workspaces: []))
        XCTAssertEqual(RemoteControlProjection.decode(nil), .init(workspaces: []))
        XCTAssertEqual(RemoteControlProjection.decodeEnabled(RemoteControlProjection.encodeEnabled(["/a", "/b"])), ["/a", "/b"])
    }
}
```

`RelayClientTests.swift` — use the same `URLProtocol` stub pattern as `AuthClientTests.swift` (read it; reuse its stub class if it is reusable, else declare a private `RelayStubProtocol`):
```swift
func testRegisterDevicePostsNameWithBearerAndDecodesRegistration() async throws {
    RelayStubProtocol.handler = { request in
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/relay/devices")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: String]
        XCTAssertEqual(body?["name"], "M4x Studio")
        return (200, #"{"device_id":"d1","token":"secret"}"#)
    }
    let client = RelayClient(baseURL: URL(string: "https://relay.test")!, session: RelayStubProtocol.session(), accessToken: { "tok" })
    let reg = try await client.registerDevice(name: "M4x Studio")
    XCTAssertEqual(reg, .init(deviceID: "d1", token: "secret"))
    XCTAssertEqual(client.viewerSocketURL(deviceID: "d1").absoluteString, "wss://relay.test/v1/viewer/d1")
    XCTAssertTrue(client.deviceTokenRow(reg, name: "M4x Studio").contains(#""relay_url":"https://relay.test""#))
}
func testListDevicesDecodesSnakeCase() async throws {
    RelayStubProtocol.handler = { _ in (200, #"[{"device_id":"d1","name":"Mac","online":true,"last_seen_at":null}]"#) }
    let client = RelayClient(baseURL: URL(string: "https://relay.test")!, session: RelayStubProtocol.session(), accessToken: { "tok" })
    XCTAssertEqual(try await client.listDevices(), [.init(deviceID: "d1", name: "Mac", online: true, lastSeenAt: nil)])
}
func testMissingAccessTokenThrowsBeforeAnyRequest() async {
    RelayStubProtocol.handler = { _ in XCTFail("no request expected"); return (500, "") }
    let client = RelayClient(baseURL: URL(string: "https://relay.test")!, session: RelayStubProtocol.session(), accessToken: { nil })
    do { _ = try await client.listDevices(); XCTFail() } catch {}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -only-testing:OmniAgentTests/RemoteControlProjectionTests -only-testing:OmniAgentTests/RelayClientTests 2>&1 | grep -E "error:|TEST"` — Expected: compile errors.

- [ ] **Step 3: Implement the two files + keys**

`RemoteControlProjection.build`: group `tabs` by `project`, keep those in `enabledWorkspaceIDs` (ordered by first appearance), map each tab with a non-nil `id` to a `Session`; `name = workspaceLabels[project] ?? SessionOutline.projectLabel(project, labels: workspaceLabels)`. `encode` uses `JSONEncoder` with `.sortedKeys`; `decode` returns `Payload(workspaces: [])` on any failure. `RelayClient` mirrors `AuthClient`'s request building (`URLRequest(url: baseURL.appendingPathComponent(path))`, JSON body, `Authorization: Bearer`, throw on non-2xx with the body in the error); `CodingKeys` map `device_id`, `last_seen_at`; `viewerSocketURL` swaps the scheme to `wss` (`ws` for `http`).

- [ ] **Step 4: Wire the host side**

- `WorkspaceContextMenu.build(...)` gains `remoteControlEnabled: Bool, toggleRemoteControl: @escaping () -> Void`; after "Customize…" insert `let remote = ShellMenuItem("Enable Remote Control", handler: toggleRemoteControl); remote.state = remoteControlEnabled ? .on : .off`.
- `WorkspaceWindowController`: `private var remoteControlWorkspaceIDs: Set<String> = []` loaded at startup with `connection.getSetting(key: SettingsKey.remoteControlWorkspaces)` → `decodeEnabled`; `private var hasRelayDeviceToken = false` loaded from `SettingsKey.relayDeviceToken != nil`.
  ```swift
  private func toggleRemoteControl(workspaceID: String) {
      if remoteControlWorkspaceIDs.contains(workspaceID) { remoteControlWorkspaceIDs.remove(workspaceID) } else { remoteControlWorkspaceIDs.insert(workspaceID) }
      write(RemoteControlProjection.encodeEnabled(remoteControlWorkspaceIDs), to: SettingsKey.remoteControlWorkspaces)
      persistRemoteControlProjection()
      if !remoteControlWorkspaceIDs.isEmpty && !hasRelayDeviceToken { registerThisMachine() }
      rebuildSidebar()   // whatever refreshes WorkspaceTreeEntry rows
  }
  private func persistRemoteControlProjection() {
      let descriptors = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
      let tabs = WorkspaceRestoration.persistedTabs(from: descriptors)
      let payload = RemoteControlProjection.build(tabs: tabs, enabledWorkspaceIDs: remoteControlWorkspaceIDs, workspaceLabels: projectLabels)
      write(RemoteControlProjection.encode(payload), to: SettingsKey.remoteControl)
  }
  private func registerThisMachine() {
      let name = Host.current().localizedName ?? "Mac"
      Task { @MainActor in
          do {
              let reg = try await RelayClient.shared.registerDevice(name: name)
              connection.setSetting(key: SettingsKey.relayDeviceToken, value: RelayClient.shared.deviceTokenRow(reg, name: name))
              hasRelayDeviceToken = true
          } catch { presentWindowAsk(...)  /* the liquid-glass ask, severity .warning: "Could not enable Remote Control", error.localizedDescription, OK */ }
      }
  }
  ```
  `persistLayout()` calls `persistRemoteControlProjection()` at its end. `workspaceContextMenu(for:)` passes `remoteControlEnabled: remoteControlWorkspaceIDs.contains(id)` and `toggleRemoteControl: { [weak self] in self?.toggleRemoteControl(workspaceID: id) }`.
- `WorkspaceTreeEntry` gains `let remoteControl: Bool` (default `false` via an init default so other call sites compile). `WorkspaceRowView` gets a trailing `NSImageView(image: NSImage(systemSymbolName: "globe", accessibilityDescription: "Remote Control on"))` (16 pt, `contentTintColor = ShellPalette.folderGlyph`), hidden unless `entry.remoteControl`, constrained `trailingAnchor -8`, with `titleField.trailingAnchor` ≤ its leading − 6.

- [ ] **Step 5: Run the tests and the full macOS suite**

Run: `xcodebuild test … -only-testing:OmniAgentTests/RemoteControlProjectionTests -only-testing:OmniAgentTests/RelayClientTests 2>&1 | tail -3` — Expected: `** TEST SUCCEEDED **`.
Run: `caffeinate -disu ./macos/build.sh test 2>&1 | grep -E "Test Suite .* (passed|failed)|error:" | tail -5` — Expected: only the known pre-existing failures.

- [ ] **Step 6: Commit and push**

```bash
git add macos/OmniAgent/RelayClient.swift macos/OmniAgent/RemoteControlProjection.swift macos/OmniAgent/SettingsKeys.swift macos/OmniAgent/WorkspaceContextMenu.swift macos/OmniAgent/WorkspacesTree.swift macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/RelayClientTests.swift macos/OmniAgentTests/RemoteControlProjectionTests.swift
git -c core.fsmonitor=false commit -m "feat(macos): Enable Remote Control per workspace writes the remote_control projection and registers the device" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task B3: App — predictive echo (model + overlay)

**Files:**
- Create: `macos/OmniAgent/PredictiveEchoModel.swift`, `macos/OmniAgent/PredictiveEchoOverlayView.swift`
- Modify: `macos/OmniAgent/TerminalSurfaceView.swift` (`init` 187, `feed` 309-330, `send(source:data:)` 411-416, layout)
- Test: `macos/OmniAgentTests/PredictiveEchoModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct PredictiveEchoModel: Equatable {
      struct Prediction: Equatable { let row: Int; let col: Int; let character: Character; let madeAt: TimeInterval }
      enum Confidence: Equatable { case unknown, confirmed }
      private(set) var confidence: Confidence = .unknown
      private(set) var pending: [Prediction] = []
      var timeout: TimeInterval = 1.0
      var drawn: [Prediction] { confidence == .confirmed ? pending : [] }
      mutating func syncCursor(row: Int, col: Int)      // call with the real cursor before predict() when pending is empty
      mutating func predict(_ bytes: [UInt8], now: TimeInterval, cols: Int)
      mutating func reconcile(now: TimeInterval, cellAt: (Int, Int) -> Character?)
  }
  final class PredictiveEchoOverlayView: NSView { func render(_ predictions: [PredictiveEchoModel.Prediction], cols: Int, rows: Int, font: NSFont, color: NSColor) }
  extension TerminalSurfaceView { var predictiveEchoEnabled: Bool }   // set true by B4 for remote panes
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import OmniAgent

final class PredictiveEchoModelTests: XCTestCase {
    func testFirstKeystrokeIsRecordedButNotDrawnUntilConfirmed() {
        var m = PredictiveEchoModel(); m.syncCursor(row: 0, col: 0)
        m.predict([UInt8(ascii: "a")], now: 0, cols: 80)
        XCTAssertEqual(m.pending.count, 1); XCTAssertTrue(m.drawn.isEmpty)
        m.reconcile(now: 0.1) { r, c in (r, c) == (0, 0) ? "a" : nil }
        XCTAssertEqual(m.confidence, .confirmed); XCTAssertTrue(m.pending.isEmpty)
        m.predict([UInt8(ascii: "b")], now: 0.2, cols: 80)
        XCTAssertEqual(m.drawn.map(\.character), ["b"]); XCTAssertEqual(m.drawn[0].col, 1)
    }
    func testMismatchClearsEverythingAndResetsConfidence() {
        var m = confirmedModel()
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80)
        m.reconcile(now: 1.1) { _, _ in "y" }
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.confidence, .unknown)
    }
    func testControlBytesAndEscapeSequencesClear() {
        var m = confirmedModel()
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80)
        m.predict([0x1b, 0x5b, 0x41], now: 1.1, cols: 80)   // arrow up
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.confidence, .unknown)
        m = confirmedModel(); m.predict([0x0d], now: 1, cols: 80)   // Enter is never predicted
        XCTAssertTrue(m.pending.isEmpty)
    }
    func testTimeoutClears() {
        var m = confirmedModel()
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80)
        m.reconcile(now: 2.5) { _, _ in nil }
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.confidence, .unknown)
    }
    func testUnechoedCellsKeepPredictionsWaiting() {
        var m = confirmedModel()
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80)
        m.reconcile(now: 1.2) { _, _ in nil }
        XCTAssertEqual(m.pending.count, 1); XCTAssertEqual(m.confidence, .confirmed)
    }
    func testBackspaceOnlyUndoesOwnPredictions() {
        var m = confirmedModel()
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80)
        m.predict([0x7f], now: 1.1, cols: 80)
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.confidence, .confirmed)
        m.predict([0x7f], now: 1.2, cols: 80)   // nothing of ours to undo → unknown
        XCTAssertEqual(m.confidence, .unknown)
    }
    func testWrapsAtLineEnd() {
        var m = confirmedModel(); m.syncCursor(row: 3, col: 79)
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80); m.predict([UInt8(ascii: "y")], now: 1, cols: 80)
        XCTAssertEqual(m.pending.map { [$0.row, $0.col] }, [[3, 79], [4, 0]])
    }
    private func confirmedModel() -> PredictiveEchoModel {
        var m = PredictiveEchoModel(); m.syncCursor(row: 0, col: 0)
        m.predict([UInt8(ascii: "a")], now: 0, cols: 80)
        m.reconcile(now: 0.1) { _, _ in "a" }
        return m
    }
}
```

- [ ] **Step 2: Run to verify they fail** — compile error, `PredictiveEchoModel` missing.

- [ ] **Step 3: Implement the model**

```swift
struct PredictiveEchoModel: Equatable {
    struct Prediction: Equatable { let row: Int; let col: Int; let character: Character; let madeAt: TimeInterval }
    enum Confidence: Equatable { case unknown, confirmed }
    private(set) var confidence: Confidence = .unknown
    private(set) var pending: [Prediction] = []
    private var cursorRow = 0, cursorCol = 0
    var timeout: TimeInterval = 1.0
    var drawn: [Prediction] { confidence == .confirmed ? pending : [] }

    mutating func syncCursor(row: Int, col: Int) { guard pending.isEmpty else { return }; cursorRow = row; cursorCol = col }

    mutating func predict(_ bytes: [UInt8], now: TimeInterval, cols: Int) {
        if bytes == [0x7f] || bytes == [0x08] {
            guard let last = pending.last, last.row == cursorRow, last.col == cursorCol - 1 || (cursorCol == 0 && last.col == cols - 1) else { reset(); return }
            pending.removeLast(); cursorRow = last.row; cursorCol = last.col
            return
        }
        guard let scalar = String(decoding: bytes, as: UTF8.self).unicodeScalars.first,
              bytes.count == String(scalar).utf8.count, bytes.count <= 4,
              scalar.value >= 0x20, scalar.value != 0x7f, !(0x80...0x9f).contains(scalar.value) else { reset(); return }
        pending.append(Prediction(row: cursorRow, col: cursorCol, character: Character(scalar), madeAt: now))
        cursorCol += 1
        if cursorCol >= cols { cursorCol = 0; cursorRow += 1 }
    }

    mutating func reconcile(now: TimeInterval, cellAt: (Int, Int) -> Character?) {
        if pending.contains(where: { now - $0.madeAt > timeout }) { reset(); return }
        while let first = pending.first {
            guard let real = cellAt(first.row, first.col), real != " " else { return }   // not echoed yet — keep waiting
            guard real == first.character else { reset(); return }
            pending.removeFirst(); confidence = .confirmed
        }
    }
    private mutating func reset() { pending.removeAll(); confidence = .unknown }
}
```

- [ ] **Step 4: Run the model tests** — Expected: 7 passed.

- [ ] **Step 5: Overlay + hookup in `TerminalSurfaceView`**

`PredictiveEchoOverlayView`: transparent, `isHidden` when no predictions; `render(...)` stores inputs and `needsDisplay = true`; `draw(_:)` computes `cellW = bounds.width / CGFloat(cols)`, `cellH = bounds.height / CGFloat(rows)`, and for each prediction draws `NSAttributedString(string: String(p.character), attributes: [.font: font, .foregroundColor: color, .underlineStyle: NSUnderlineStyle.single.rawValue])` at `(CGFloat(p.col) * cellW, bounds.height - CGFloat(p.row + 1) * cellH)` (AppKit y is flipped unless the view `isFlipped`; make the overlay `isFlipped = true` and draw at `(col*cellW, row*cellH)`). `hitTest` returns `nil` so it never eats clicks.

In `TerminalSurfaceView`: `var predictiveEchoEnabled = false { didSet { overlay.isHidden = !predictiveEchoEnabled } }`, `private var echo = PredictiveEchoModel()`, `private let overlay = PredictiveEchoOverlayView()` added above `terminalView` with the same frame (autoresizing width/height). In `send(source:data:)` after `connection.write`: 
```swift
if predictiveEchoEnabled {
    let t = terminalView.getTerminal(); let cur = t.getCursorLocation()   // SwiftTerm: (x, y) in the viewport
    echo.syncCursor(row: cur.y, col: cur.x)
    echo.predict(Array(data), now: CACurrentMediaTime(), cols: t.cols)
    overlay.render(echo.drawn, cols: t.cols, rows: t.rows, font: terminalView.font, color: .secondaryLabelColor)
}
```
In `feed(...)` after `terminalView.feed(...)`:
```swift
if predictiveEchoEnabled {
    let t = terminalView.getTerminal()
    echo.reconcile(now: CACurrentMediaTime()) { row, col in
        guard let cd = t.getCharData(col: col, row: row) else { return nil }    // viewport-relative; check SwiftTerm's signature
        return cd.getCharacter()
    }
    overlay.render(echo.drawn, cols: t.cols, rows: t.rows, font: terminalView.font, color: .secondaryLabelColor)
}
```
Verify the SwiftTerm accessor names in the checked-out package (`Terminal.getCursorLocation()`, `Terminal.getCharData(col:row:)`, `CharData.getCharacter()`); use whatever the vendored version exposes — the model does not care.

- [ ] **Step 6: Build and run the terminal tests**

Run: `./macos/build.sh build` — `** BUILD SUCCEEDED **`. Run the `PredictiveEchoModelTests` + any `TerminalSurface*` tests — succeed.

- [ ] **Step 7: Commit and push**

```bash
git add macos/OmniAgent/PredictiveEchoModel.swift macos/OmniAgent/PredictiveEchoOverlayView.swift macos/OmniAgent/TerminalSurfaceView.swift macos/OmniAgentTests/PredictiveEchoModelTests.swift
git -c core.fsmonitor=false commit -m "feat(macos): mosh-style predictive echo overlay for remote terminals" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task B4: App — viewer side: `RemoteMachinesModel`, remote panes

**Files:**
- Create: `macos/OmniAgent/RemoteMachinesModel.swift`
- Modify: the file defining `PaneDescriptor` (grep `struct PaneDescriptor`), `macos/OmniAgent/WorkspaceWindowController.swift` (pane factory 478-481, `persistLayout`, a new `openRemoteSession`), `macos/OmniAgent/AppDelegate.swift:27-33`
- Test: `macos/OmniAgentTests/RemoteMachinesModelTests.swift`

**Interfaces:**
- Consumes: `SessionConnection(transport: .webSocket(_, bearer:))`, `isRemote` (B1); `RelayClient`, `RemoteControlProjection.decode`, `SettingsKey.remoteControl` (B2); `predictiveEchoEnabled` (B3).
- Produces:
  ```swift
  struct RemoteMachine: Equatable { let deviceID: String; let name: String; let projection: RemoteControlProjection.Payload }
  final class RemoteMachinesModel {
      init(relay: RelayClient = .shared, pollInterval: TimeInterval = 30,
           makeConnection: @escaping (URL) -> SessionConnection = { SessionConnection(transport: .webSocket($0, bearer: { AuthClient.shared.accessToken })) },
           isSignedIn: @escaping () -> Bool = { AuthClient.shared.accessToken != nil })
      private(set) var machines: [RemoteMachine]           // online machines with a decoded projection, sorted by name
      var onChange: (() -> Void)?
      func start(); func stop()
      func refresh() async                                  // one poll: list → connect new online devices → drop offline ones
      func connection(for deviceID: String) -> SessionConnection?
  }
  extension PaneDescriptor { var remoteDeviceID: String? }  // nil for local panes
  extension WorkspaceWindowController { func openRemoteSession(deviceID: String, sessionID: String, title: String) }
  ```
- Rules: one `SessionConnection` per online device, created lazily on first poll that sees it online, `connect()`ed immediately, then `getSetting(key: SettingsKey.remoteControl)` → `decode` → `machines` updated → `onChange`. A device that goes offline: `disconnect()`, removed from `machines` (its open panes keep their connection object and simply show reconnecting). Remote panes are **not** persisted: `persistLayout()` filters descriptors with `remoteDeviceID != nil` before `persistedTabs(from:)`, and `persistRemoteControlProjection()` does the same.

- [ ] **Step 1: Write the failing test**

```swift
final class RemoteMachinesModelTests: XCTestCase {
    func testOnlineDevicesGetOneConnectionAndTheirProjection() async throws {
        RelayStubProtocol.handler = { _ in (200, #"[{"device_id":"d1","name":"Studio","online":true,"last_seen_at":null},{"device_id":"d2","name":"Air","online":false,"last_seen_at":null}]"#) }
        let relay = RelayClient(baseURL: URL(string: "https://relay.test")!, session: RelayStubProtocol.session(), accessToken: { "tok" })
        var made: [URL] = []
        let fake = FakeSessionConnection()   // subclass/test double exposing setSetting-free getSetting stub: returns the projection JSON for "remote_control"
        let model = RemoteMachinesModel(relay: relay, makeConnection: { url in made.append(url); return fake }, isSignedIn: { true })
        await model.refresh()
        XCTAssertEqual(made.map(\.absoluteString), ["wss://relay.test/v1/viewer/d1"])
        XCTAssertEqual(model.machines.map(\.name), ["Studio"])
        XCTAssertEqual(model.machines[0].projection.workspaces.map(\.id), ["/a"])
        XCTAssertNotNil(model.connection(for: "d1")); XCTAssertNil(model.connection(for: "d2"))
    }
    func testDeviceGoingOfflineIsDropped() async throws { /* second refresh with d1 offline → machines empty, connection(for:"d1") nil, fake.disconnectCalled == true */ }
}
```
If `SessionConnection` cannot be subclassed cleanly, give `RemoteMachinesModel` a tiny `RemoteConnection` protocol (`connect/disconnect/getSetting(key:completion:)/onStateChange`) that `SessionConnection` conforms to, and inject a fake conforming type. Keep the protocol to those four members.

- [ ] **Step 2: Run to verify it fails**, then **Step 3: implement** `RemoteMachinesModel` (a `Timer` on the main queue for polling; `refresh()` wraps `listDevices()` in `try?` — a relay outage must never surface as an error; when `isSignedIn()` is false, disconnect everything and clear).

- [ ] **Step 4: Wire panes**

- `PaneDescriptor` gains `var remoteDeviceID: String? = nil`.
- `AppDelegate`: `let remoteMachines = RemoteMachinesModel()`; pass to `WorkspaceWindowController(connection:panes:notifier:daemonPersistence:remoteMachines:)`; `remoteMachines.start()` after the auth gate resolves signed-in (hook where `authSignedIn` becomes true; `stop()` on logout via the existing logout flow).
- Pane factory: `case .terminal: let conn = descriptor.remoteDeviceID.flatMap { remoteMachines.connection(for: $0) } ?? connection; let view = TerminalSurfaceView(connection: conn, sessionID: descriptor.sessionID); view.predictiveEchoEnabled = conn.isRemote; return view`.
- `openRemoteSession(deviceID:sessionID:title:)`: if a pane with that `sessionID` + `remoteDeviceID` exists, focus it; else add a terminal pane descriptor (`remoteDeviceID` set, label `title`, project = `"remote:\(deviceID)"`) via the same path "New session" uses minus the daemon `CreateSession`, then `attach`. Remote panes hide the Kill/close-session affordances (`isRemote` check where those buttons are built) and their hover card subtitle reads `"Remote · \(machineName)"`.
- `persistLayout()` / `persistRemoteControlProjection()`: filter `descriptor.remoteDeviceID == nil`.

- [ ] **Step 5: Run tests + full suite**, **Step 6: commit and push** (`feat(macos): remote machines model and remote terminal panes`), same trailer/commands pattern as B2 with these files.

---

### Task B5: App — sidebar section, Resume remote session…, spotlight rows

**Files:**
- Modify: `macos/OmniAgent/WorkspacesTree.swift` (`WorkspacesTreeView` 192+, `WorkspaceRowView`), `macos/OmniAgent/NavigationSidebar.swift` (~1063 wiring), `macos/OmniAgent/WorkspaceWindowController.swift` (sidebar rebuild, `run(_:)`), `macos/OmniAgent/WorkspacesHeaderMenus.swift:163-165`, `macos/OmniAgent/WorkspaceWindowController.swift:744`, `macos/OmniAgent/CommandPalette.swift` (`PaletteAction`, `build(...)` 308-321)
- Test: `macos/OmniAgentTests/CommandPaletteTests.swift`

**Interfaces:**
- Consumes: `RemoteMachinesModel.machines`, `openRemoteSession` (B4).
- Produces:
  ```swift
  struct PaletteRemoteMachine: Equatable { let deviceID: String; let name: String; let workspaces: [PaletteRemoteWorkspace] }
  struct PaletteRemoteWorkspace: Equatable { let id: String; let name: String; let sessions: [(id: String, title: String)] }  // use a small struct, tuples are not Equatable
  enum PaletteAction { …existing…; case openRemoteSession(deviceID: String, sessionID: String, title: String) }
  static func build(…, remoteMachines: [PaletteRemoteMachine] = []) -> [PaletteCommand]
  ```
- Row contract (spec §4 Spotlight): `id: "remote:\(deviceID)/\(sessionID)"`, `title: session title`, `detail: "remote"`, `section: .sessions`, `symbol: "desktopcomputer.and.arrow.down"`, `subtitle: "\(machine) · \(workspace)"`, `keywords: "remote \(machine) \(workspace)"`. One row per machine too: `id: "remote-machine:\(deviceID)"`, `title: machine name`, `subtitle: "Remote machine"`, action opens its first session.

- [ ] **Step 1: Write the failing palette test**

```swift
func testRemoteSessionsAreSpotlightRowsNamedByMachineAndWorkspace() {
    let commands = CommandPaletteModel.build(
        panes: [], paneOrder: [], focusedPaneID: nil,
        remoteMachines: [PaletteRemoteMachine(deviceID: "d1", name: "Studio", workspaces: [
            PaletteRemoteWorkspace(id: "/a", name: "Alpha", sessions: [.init(id: "s1", title: "migrate")])
        ])])
    let row = try XCTUnwrap(commands.first { $0.id == "remote:d1/s1" })
    XCTAssertEqual(row.title, "migrate")
    XCTAssertEqual(row.subtitle, "Studio · Alpha")
    XCTAssertEqual(row.symbol, "desktopcomputer.and.arrow.down")
    XCTAssertEqual(row.keywords, "remote Studio Alpha")
    XCTAssertEqual(row.action, .openRemoteSession(deviceID: "d1", sessionID: "s1", title: "migrate"))
    XCTAssertNotNil(commands.first { $0.id == "remote-machine:d1" })
}
```

- [ ] **Step 2: Run to verify it fails.** **Step 3: implement** the palette rows, `run(_:)` dispatch → `openRemoteSession`, and the sidebar:
  - `WorkspacesTreeView` gets `var remoteMachines: [RemoteMachineTreeEntry] = []` (`struct RemoteMachineTreeEntry { let deviceID: String; let name: String; let workspaces: [WorkspaceTreeEntry] }`), rendered after the local buckets as a `WorkspacesBucketHeaderView` titled `"\(name) · remote"` followed by its workspace/session rows; remote rows use an `NSImageView` with `desktopcomputer.and.arrow.down` in place of the folder glyph, and clicking a session row calls `onOpenRemoteSession?(deviceID, sessionID, title)`.
  - `NavigationSidebar` forwards `remoteMachines` and `onOpenRemoteSession`; `WorkspaceWindowController` sets them from `remoteMachines.machines` inside its sidebar rebuild and subscribes `remoteMachines.onChange = { [weak self] in self?.rebuildSidebar() }`.
  - **Resume remote session…** (`WorkspacesHeaderMenus.swift:163`, `WorkspaceWindowController.swift:744`): `isEnabled = true`, `image = NSImage(systemSymbolName: "desktopcomputer.and.arrow.down", …)`, handler opens the command palette with the query `"remote"` (use the existing palette-presenting method; if it has no query parameter, add `initialQuery: String? = nil`).

- [ ] **Step 4: Run `CommandPaletteTests` + the full suite.** **Step 5: commit and push** (`feat(macos): remote machines in the sidebar, Resume remote session…, spotlight rows`).

---

### Task C1: Core — `RelayDevice`, migration, relay service, tests

**Files:**
- Modify: `omniagent/api/jwt_auth.py` (add `decode_access_token`; make `get_current_user_sub` and `get_current_user_if_present` call it)
- Modify: `omniagent/db/models.py` (after `RefreshToken`, ~634)
- Create: `omniagent/db/migrations/versions/033_relay_devices.py`, `omniagent/relay/__init__.py`, `omniagent/relay/main.py`, `tests/test_relay.py`
- Modify: `pyproject.toml` (nothing new needed — Starlette's `TestClient.websocket_connect` ships with `starlette`+`httpx`; add `websockets` only if `uvicorn[standard]` is not already pulling it)

**Interfaces:**
- Produces:
  ```python
  # jwt_auth.py
  def decode_access_token(token: str) -> dict | None   # verified payload with type=="access" and sub, else None
  # models.py
  class RelayDevice(Base): __tablename__ = "relay_devices"; id: str(36) pk; user_id: FK users.id CASCADE; name: str(255); token_hash: str(64) unique; created_at; last_seen_at: DateTime|None
  # relay/main.py
  app = FastAPI(...)   # entrypoint: uvicorn omniagent.relay.main:app --host 0.0.0.0 --port 8081
  ```
- HTTP/WS contract exactly as spec §5 (paths `/v1/relay/devices`, `/v1/device`, `/v1/viewer/{device_id}`, `/v1/device/conn/{conn_id}`, `/health`). Auth failures on WebSocket routes close the handshake with **HTTP 403** (Starlette's behaviour for `WebSocketException` before `accept()`); the daemon treats 401 and 403 alike.

- [ ] **Step 1: Write the failing tests**

`tests/test_relay.py`:
```python
import hashlib, secrets
import pytest
from starlette.testclient import TestClient
from sqlalchemy import select

from omniagent.db.models import RelayDevice, User
from omniagent.db.session import get_db
from omniagent.relay.main import app as relay_app
from tests.conftest import _override_get_db   # the in-memory override conftest installs on the API app

relay_app.dependency_overrides[get_db] = _override_get_db

@pytest.fixture
def relay():
    with TestClient(relay_app) as client:
        yield client

@pytest.fixture
async def device(db):
    user = User(email="relay@example.com", ...)   # copy the minimal User construction used by tests/test_auth*.py
    db.add(user); await db.flush()
    token = secrets.token_hex(32)
    row = RelayDevice(user_id=user.id, name="Studio", token_hash=hashlib.sha256(token.encode()).hexdigest())
    db.add(row); await db.commit()
    return user, row, token

def bearer(t): return {"authorization": f"Bearer {t}"}

def test_register_list_delete_devices(relay, viewer_jwt):
    r = relay.post("/v1/relay/devices", json={"name": "Studio"}, headers=bearer(viewer_jwt))
    assert r.status_code == 201 and set(r.json()) == {"device_id", "token"}
    devices = relay.get("/v1/relay/devices", headers=bearer(viewer_jwt)).json()
    assert devices == [{"device_id": r.json()["device_id"], "name": "Studio", "online": False, "last_seen_at": None}]
    assert relay.delete(f"/v1/relay/devices/{r.json()['device_id']}", headers=bearer(viewer_jwt)).status_code == 204
    assert relay.get("/v1/relay/devices", headers=bearer(viewer_jwt)).json() == []

def test_viewer_is_spliced_to_the_device_data_socket(relay, device, viewer_jwt):
    _, row, token = device
    with relay.websocket_connect("/v1/device", headers=bearer(token)) as control:
        control.send_json({"hostname": "Studio", "daemon_version": "0.1"})
        assert relay.get("/v1/relay/devices", headers=bearer(viewer_jwt)).json()[0]["online"] is True
        with relay.websocket_connect(f"/v1/viewer/{row.id}", headers=bearer(viewer_jwt)) as viewer:
            conn_id = control.receive_json()["open"]
            with relay.websocket_connect(f"/v1/device/conn/{conn_id}", headers=bearer(token)) as data:
                viewer.send_bytes(b"\x00\x00\x00\x02\x01\x01" + bytes(10) + b"{}")
                assert data.receive_bytes().startswith(b"\x00\x00\x00\x02")
                data.send_bytes(b"ack"); assert viewer.receive_bytes() == b"ack"

def test_other_users_cannot_view_a_device(relay, device, other_user_jwt):
    _, row, token = device
    with relay.websocket_connect("/v1/device", headers=bearer(token)):
        with pytest.raises(Exception):   # handshake denied (403)
            with relay.websocket_connect(f"/v1/viewer/{row.id}", headers=bearer(other_user_jwt)): pass

def test_offline_device_rejects_viewers(relay, device, viewer_jwt):
    _, row, _ = device
    with pytest.raises(Exception):
        with relay.websocket_connect(f"/v1/viewer/{row.id}", headers=bearer(viewer_jwt)): pass

def test_revoked_token_is_refused(relay, device, viewer_jwt):
    _, row, token = device
    relay.delete(f"/v1/relay/devices/{row.id}", headers=bearer(viewer_jwt))
    with pytest.raises(Exception):
        with relay.websocket_connect("/v1/device", headers=bearer(token)): pass

def test_unknown_conn_id_is_refused(relay, device):
    _, _, token = device
    with pytest.raises(Exception):
        with relay.websocket_connect("/v1/device/conn/nope", headers=bearer(token)): pass
```
`viewer_jwt` / `other_user_jwt` fixtures: mint with the access-token factory in `jwt_auth.py` (the function at line ~80 that `routers/auth.py` calls on login — read its name and arguments) for the fixture's user and a second user. Starlette raises `WebSocketDenialResponse`/`WebSocketDisconnect` on a denied handshake — narrow the `pytest.raises` to the actual class once you see it.

- [ ] **Step 2: Run to verify they fail** — `cd /Users/bonando/Documents/Bruno.Digital/OmniAgent-Core && .venv/bin/python -m pytest tests/test_relay.py -v` → `ModuleNotFoundError: omniagent.relay`.

- [ ] **Step 3: Implement**

`jwt_auth.py`:
```python
def decode_access_token(token: str) -> dict | None:
    """Verify a self-issued access JWT (signature, issuer, audience, type) → payload, or None."""
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM], issuer=JWT_ISSUER, audience=JWT_AUDIENCE)
    except jwt.PyJWTError:
        return None
    return payload if payload.get("sub") and payload.get("type") == "access" else None
```
and make the two existing inline decoders use it (behaviour unchanged).

`models.py` — copy `RefreshToken`'s shape: `RelayDevice` with `id` (`_uuid`), `user_id` FK `users.id` `ondelete="CASCADE"`, `name String(255)`, `token_hash String(64) unique`, `created_at server_default=func.now()`, `last_seen_at DateTime(timezone=True) nullable`, `Index("ix_relay_devices_user_id", "user_id")`.

Migration `033_relay_devices.py`: `revision = "033_relay_devices"`, `down_revision = "<id of 032_github_identity>"` (read it), `upgrade()` creates the table + index, `downgrade()` drops it. Generate with `make migrate-new` if a database is reachable, else write it by hand following `032_github_identity.py`.

`omniagent/relay/main.py`:
```python
"""OmniAgent Relay — splices remote viewers to PTY daemons. Dumb byte pipe; never parses frames."""
from __future__ import annotations
import asyncio, hashlib, secrets, uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Annotated
from fastapi import Depends, FastAPI, HTTPException, Response, WebSocket, WebSocketException, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from omniagent.api.jwt_auth import decode_access_token, get_current_user_sub
from omniagent.db.models import RelayDevice
from omniagent.db.session import get_db

app = FastAPI(title="OmniAgent Relay", docs_url=None, redoc_url=None)
OPEN_TIMEOUT = 10.0
DB = Annotated[AsyncSession, Depends(get_db)]
Sub = Annotated[str, Depends(get_current_user_sub)]

# ponytail: single replica, in-process registry; redis-routed splice if we ever need >1
_control: dict[str, WebSocket] = {}

@dataclass
class _Pending:
    device_id: str
    viewer: WebSocket
    opened: asyncio.Event = field(default_factory=asyncio.Event)
    done: asyncio.Event = field(default_factory=asyncio.Event)

_pending: dict[str, _Pending] = {}

def _hash(token: str) -> str: return hashlib.sha256(token.encode()).hexdigest()
def _now() -> datetime: return datetime.now(timezone.utc)

class DeviceIn(BaseModel): name: str
class DeviceOut(BaseModel): device_id: str; name: str; online: bool; last_seen_at: datetime | None

@app.get("/health", include_in_schema=False)
async def health() -> dict[str, str]: return {"status": "ok"}

@app.post("/v1/relay/devices", status_code=201)
async def register_device(body: DeviceIn, sub: Sub, db: DB) -> dict[str, str]:
    token = secrets.token_hex(32)
    row = RelayDevice(user_id=sub, name=body.name[:255], token_hash=_hash(token))
    db.add(row); await db.commit()
    return {"device_id": row.id, "token": token}

@app.get("/v1/relay/devices")
async def list_devices(sub: Sub, db: DB) -> list[DeviceOut]:
    rows = (await db.execute(select(RelayDevice).where(RelayDevice.user_id == sub).order_by(RelayDevice.name))).scalars().all()
    return [DeviceOut(device_id=r.id, name=r.name, online=r.id in _control, last_seen_at=r.last_seen_at) for r in rows]

@app.delete("/v1/relay/devices/{device_id}", status_code=204)
async def delete_device(device_id: str, sub: Sub, db: DB) -> Response:
    row = await db.get(RelayDevice, device_id)
    if row is None or row.user_id != sub: raise HTTPException(404)
    await db.delete(row); await db.commit()
    if (ws := _control.pop(device_id, None)) is not None:
        try: await ws.close(code=status.WS_1008_POLICY_VIOLATION)
        except Exception: pass
    return Response(status_code=204)

async def _device_from_token(ws: WebSocket, db: AsyncSession) -> RelayDevice:
    auth = ws.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "): raise WebSocketException(code=status.WS_1008_POLICY_VIOLATION)
    row = (await db.execute(select(RelayDevice).where(RelayDevice.token_hash == _hash(auth[7:].strip())))).scalar_one_or_none()
    if row is None: raise WebSocketException(code=status.WS_1008_POLICY_VIOLATION)
    return row

def _viewer_sub(ws: WebSocket) -> str:
    auth = ws.headers.get("authorization", "")
    payload = decode_access_token(auth[7:].strip()) if auth.lower().startswith("bearer ") else None
    if payload is None: raise WebSocketException(code=status.WS_1008_POLICY_VIOLATION)
    return payload["sub"]

@app.websocket("/v1/device")
async def device_control(ws: WebSocket, db: DB) -> None:
    device = await _device_from_token(ws, db)
    await ws.accept()
    await ws.receive_json()                      # hello {"hostname","daemon_version"} — informational
    device.last_seen_at = _now(); await db.commit()
    if (old := _control.pop(device.id, None)) is not None:
        try: await old.close()
        except Exception: pass
    _control[device.id] = ws
    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect": break
    finally:
        if _control.get(device.id) is ws: del _control[device.id]
        device.last_seen_at = _now()
        try: await db.commit()
        except Exception: pass

@app.websocket("/v1/viewer/{device_id}")
async def viewer(ws: WebSocket, device_id: str, db: DB) -> None:
    sub = _viewer_sub(ws)
    device = await db.get(RelayDevice, device_id)
    if device is None or device.user_id != sub: raise WebSocketException(code=status.WS_1008_POLICY_VIOLATION)
    control = _control.get(device_id)
    if control is None: raise WebSocketException(code=status.WS_1013_TRY_AGAIN_LATER)
    conn_id = uuid.uuid4().hex
    pending = _Pending(device_id=device_id, viewer=ws)
    _pending[conn_id] = pending
    await ws.accept()
    try:
        await control.send_json({"open": conn_id})
        await asyncio.wait_for(pending.opened.wait(), OPEN_TIMEOUT)
    except (asyncio.TimeoutError, RuntimeError):
        _pending.pop(conn_id, None)
        await ws.close(code=status.WS_1013_TRY_AGAIN_LATER); return
    await pending.done.wait()                   # the data handler runs the splice and closes both ends

@app.websocket("/v1/device/conn/{conn_id}")
async def device_data(ws: WebSocket, conn_id: str, db: DB) -> None:
    device = await _device_from_token(ws, db)
    pending = _pending.pop(conn_id, None)
    if pending is None or pending.device_id != device.id: raise WebSocketException(code=status.WS_1008_POLICY_VIOLATION)
    await ws.accept()
    pending.opened.set()
    try: await _splice(pending.viewer, ws)
    finally: pending.done.set()

async def _pump(src: WebSocket, dst: WebSocket) -> None:
    while True:
        msg = await src.receive()
        if msg["type"] == "websocket.disconnect": return
        if (b := msg.get("bytes")) is not None: await dst.send_bytes(b)
        elif (t := msg.get("text")) is not None: await dst.send_text(t)

async def _splice(a: WebSocket, b: WebSocket) -> None:
    tasks = {asyncio.create_task(_pump(a, b)), asyncio.create_task(_pump(b, a))}
    _, rest = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    for t in rest: t.cancel()
    for s in (a, b):
        try: await s.close()
        except Exception: pass
```

- [ ] **Step 4: Run the tests** — `.venv/bin/python -m pytest tests/test_relay.py -v` → all pass; `make test` → no regressions; `.venv/bin/ruff check omniagent/relay tests/test_relay.py` clean.

- [ ] **Step 5: Commit and push** (in OmniAgent-Core): `feat(relay): device registry and WebSocket relay splicing viewers to daemons` — files: `omniagent/api/jwt_auth.py omniagent/db/models.py omniagent/db/migrations/versions/033_relay_devices.py omniagent/relay/__init__.py omniagent/relay/main.py tests/test_relay.py`, same trailers, `git push origin main`.

---

### Task C2: Core — Dockerfile, K3s manifests, deploy wiring

**Files:**
- Create: `dockerfiles/Dockerfile.relay`, `k3s/base/relay/deployment.yaml`, `k3s/base/relay/service.yaml`
- Modify: `k3s/base/kustomization.yaml`, `k3s/overlays/staging/kustomization.yaml` (`images:` pin + `replicas`), `deploy.sh` (`SERVICES="api scheduler worker relay"`), `Makefile:2` (`SERVICES := api scheduler worker relay`), `k3s/README.md` (one row)

- [ ] **Step 1: Dockerfile** — copy `Dockerfile.api` verbatim, change `EXPOSE 8081` and `CMD ["uvicorn", "omniagent.relay.main:app", "--host", "0.0.0.0", "--port", "8081"]`.

- [ ] **Step 2: Manifests** — `deployment.yaml`: copy `k3s/base/api/deployment.yaml`, rename to `omniagent-relay`, `replicas: 1`, drop the anti-affinity and HPA, container `name: relay`, `image: registry.local:5000/omniagent-relay:latest`, port `http/8081`, probes `httpGet /health :8081`, keep `envFrom` (needs `DATABASE_URL`, `JWT_SECRET`), resources `50m/64Mi → 250m/256Mi`. `service.yaml`:
  ```yaml
  apiVersion: v1
  kind: Service
  metadata: { name: omniagent-relay, labels: { app: omniagent-relay } }
  spec:
    type: ClusterIP
    selector: { app: omniagent-relay }
    ports: [{ name: http, port: 8081, targetPort: 8081 }]
  ```
  Add both to `k3s/base/kustomization.yaml`; staging `images:` gets `registry.local:5000/omniagent-relay → newTag: latest`.

- [ ] **Step 3: Verify** — `kubectl kustomize k3s/overlays/staging | grep -A3 "name: omniagent-relay"` shows the Deployment and Service in `omniagent-staging`; `kubectl kustomize k3s/overlays/production >/dev/null`.

- [ ] **Step 4: Commit and push** (`chore(k3s): omniagent-relay deployment, ClusterIP service and build lane`).

---

### Task D1: Edge nginx — `relay.omni-agent.{ai,dev}` server block

**Files:** `BDN-nginx/BDN-nginx/nginx-configmap.yaml` (map 832-867; new server block next to the omni-agent blocks ~656-690)

- [ ] **Step 1: Map entries** — under `# production (omni-agent.ai)` add `relay.omni-agent.ai   http://omniagent-relay.omniagent.svc.cluster.local:8081;` and under staging `relay.omni-agent.dev  http://omniagent-relay.omniagent-staging.svc.cluster.local:8081;`.

- [ ] **Step 2: Dedicated server block** (the catch-all's `location /` inherits `proxy_read_timeout 300`, which would cut idle relay sockets every 5 minutes):
  ```nginx
  # relay.omni-agent.{ai,dev} — OmniAgent remote-session relay. Long-lived WebSockets:
  # hour-long timeouts, no buffering, map-driven Connection header.
  server {
      listen 443 ssl;
      server_name relay.omni-agent.ai relay.omni-agent.dev;
      # same ssl_certificate / ssl_certificate_key / ssl_* lines as the www.omni-agent.dev block above
      location / {
          if ($backend = "") { return 444; }
          proxy_pass $backend;
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_buffering off;
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;
      }
  }
  ```
  Copy the `listen`/`http2`/`ssl_*` lines exactly from the `www.omni-agent.dev` block so the cert setup matches.

- [ ] **Step 3: Apply and verify** — `export KUBECONFIG=~/.kube/k3s-lens.yaml; bash apply.sh` then `kubectl exec -n bruno-digital deployment/nginx -- nginx -t` → `syntax is ok`. Commit in the BDN-nginx repo (`feat: route relay.omni-agent.{ai,dev} to omniagent-relay with WebSocket timeouts`) and push.

---

### Task D2: Deploy Core to staging, then verify the relay end to end over the internet

- [ ] **Step 1:** `cd OmniAgent-Core && export KUBECONFIG=~/.kube/k3s-lens.yaml && ./deploy.sh staging` (rerun on Docker-proxy push timeouts) then `make migrate-staging`. Expected: `deployment "omniagent-relay" successfully rolled out`, migration job `033_relay_devices` applied.
- [ ] **Step 2:** `curl -si https://relay.omni-agent.dev/health` → `200 {"status":"ok"}`. `curl -si -H "Upgrade: websocket" -H "Connection: Upgrade" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" https://relay.omni-agent.dev/v1/device` → `403` (handshake reached the relay through Cloudflare + nginx and was refused for the missing token — that is the pass condition).
- [ ] **Step 3:** `kubectl logs -n omniagent-staging deployment/omniagent-relay --tail=20` shows the two requests.

---

### Task E1: End-to-end on staging with two Macs (Bruno drives, Claude verifies)

- [ ] **Step 1:** On both Macs, point the app at staging: `defaults write ai.omni-agent.OmniAgent OMNIAGENT_RELAY_BASE_URL https://relay.omni-agent.dev` and `OMNIAGENT_API_BASE_URL https://api.omni-agent.dev`; install the freshly built app on both (`scripts/rebuild-app.sh --no-notarize` here; copy the DMG to the second Mac).
- [ ] **Step 2:** Host Mac: right-click a workspace → **Enable Remote Control** → globe glyph appears; `sqlite3 ~/Library/Application\ Support/OmniAgent-ADE/brain/brain.db "select key from settings where key like 'remote%' or key='relay_device_token'"` lists all three rows; `curl -s -H "Authorization: Bearer <access token>" https://relay.omni-agent.dev/v1/relay/devices` shows the device `online: true`.
- [ ] **Step 3:** Viewer Mac: within 30 s the sidebar shows `<host name> · remote` with the workspace's sessions; open one → snapshot appears; type — characters appear instantly (underlined briefly), then confirm; run `ls` on both sides; press Ctrl-C from the viewer → interrupts. ⌘K → type "remote" → the session row appears.
- [ ] **Step 4:** Host: disable Remote Control → viewer section disappears and its pane shows reconnecting; re-enable → it returns. Close the host app (daemon stays up) → viewer still works.
- [ ] **Step 5:** Record what was observed in the plan's progress notes; any deviation becomes a fix task before E2.

---

### Task E2: Production rollout, docs, packaged build

- [ ] **Step 1:** `cd OmniAgent-Core && ./deploy.sh production && make migrate-production` (back up secrets first per `core-deploy-from-this-mac` memory); `curl -si https://relay.omni-agent.ai/health` → 200.
- [ ] **Step 2:** ADE docs: in `.github/copilot-instructions.md` add to §2 the relay (`crates/omniagent-pty-daemon/src/relay.rs`, `ClientTrust::Remote` allowlist, the three settings rows, `relay.omni-agent.ai` lives in `OmniAgent-Core/omniagent/relay`) and to §3 a "Remote Control" convention line (any new remote-reachable message kind must be added to `authorize_remote` deliberately, never by default). Run `./scripts/sync-instructions.sh`. Commit `docs: describe remote session control in the agent instructions`.
- [ ] **Step 3:** `defaults delete ai.omni-agent.OmniAgent OMNIAGENT_RELAY_BASE_URL` on both Macs; `scripts/rebuild-app.sh` (notarized when `OMNIAGENT_NOTARY_PROFILE` is set); verify `pgrep -x OmniAgent` after install; commit the version bump.

---

## Self-review

- **Spec coverage:** §1 topology → A2, C1, D1; §2 identity/authz/registry → A1 (allowlist, projection), B2 (device registration, projection rows), C1 (`relay_devices`, hash, revoke); §3 daemon → A1, A2; §4 app → B1 (transport), B2 (host toggle, globe), B4/B5 (viewer, sidebar, Resume remote session…, spotlight), B3 (predictive echo); §5 relay service → C1, C2, D1; §6 failure modes → A2 (backoff, 401 stop, empty projection), B4 (offline drop), C1 (splice close-both); §7 invariants → `remote_authz.rs` (1, 2, 5), `test_relay.py` (3, 4); §8 out of scope respected; §9 rollout → D2, E1, E2.
- **Deviations from the spec recorded:** ClusterIP + nginx map instead of MetalLB IPs; relay URL carried in the token row instead of an env var; WebSocket auth denial is HTTP 403 (daemon treats 401/403 alike).
- **Type consistency:** `SessionTransport.webSocket(URL, bearer:)` (B1) is what `RemoteMachinesModel.makeConnection` default uses (B4); `RemoteControlProjection.Payload` (B2) is `RemoteMachine.projection` (B4) and feeds `PaletteRemoteMachine` (B5); `RelayClient.Device.deviceID` (B2) ↔ `RemoteMachine.deviceID` (B4); daemon `DeviceCredential` fields (A2) ↔ `RelayClient.deviceTokenRow` keys (B2): `device_id, token, name, relay_url`.

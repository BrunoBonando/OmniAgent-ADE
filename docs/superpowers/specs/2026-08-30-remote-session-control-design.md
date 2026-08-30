# Remote Session Control — Design Spec

- **Date:** 2026-08-30
- **Status:** Approved (interactively, by Bruno)
- **Scope:** `OmniAgent-ADE` (PTY daemon + native macOS app) and `OmniAgent-Core` (new relay service + K3s manifests). One Cloudflare dashboard step.

## Context

A user signed in to OmniAgent on a second computer must see the sessions running on their other computers and type into them as if they were sitting there. Nothing like this exists today: the daemon only listens on a `0600` unix socket gated by peer UID, and the app only talks to that socket.

The daemon already does almost everything the feature needs: multiple clients may attach to one session, each with its own sequence cursor, snapshot-on-attach, resume-after-sequence and `ResyncRequired` backpressure (`crates/omniagent-pty-daemon/src/session.rs`, `server.rs`). The app's `SessionConnection` already reconnects, re-attaches and replays. What is missing is **transport, authorization and discovery**. This spec adds exactly those, without changing the daemon protocol.

Decisions taken interactively (2026-08-30):

| Question | Decision |
|---|---|
| How machine B reaches machine A | Relay through Core, on its own hostname `relay.omni-agent.ai` (staging `relay.omni-agent.dev`) |
| Transport | WebSocket over TCP through Cloudflare. Not UDP/QUIC: the "instant" feel comes from predictive echo, not the transport; Cloudflare proxies only TCP/WS on the current plan |
| Typing feel | Predictive local echo (mosh-style) |
| Which sessions are visible remotely | Only workspaces the user has enabled via right-click → **Enable Remote Control**. Host rows wear a `globe` glyph; viewer rows wear the remote glyph `desktopcomputer.and.arrow.down` |
| Simultaneous local + remote typing | Just merge, no lock — same person, two keyboards |
| Relay sees plaintext frames | Accepted for v1; relay stays a dumb byte pipe so E2E can be layered later |

## 1. Topology

```
 Machine A (host)                      Core (K3s)                          Machine B (viewer)
 ┌──────────────────┐   wss (outbound) ┌──────────────────┐  wss (outbound) ┌──────────────────┐
 │ omniagent-pty-   │ ───control────▶  │ omniagent-relay  │ ◀──viewer/<dev>─│ OmniAgent.app    │
 │ daemon           │ ◀─"open c1"────  │ relay.omni-      │                 │ SessionConnection│
 │                  │ ───data c1────▶  │  agent.ai        │ ◀═══splice═════▶│  over WebSocket  │
 │ handle_client    │ ◀══bytes═══════▶ │  (dumb pipe)     │                 │                  │
 └──────────────────┘                  └──────────────────┘                 └──────────────────┘
```

- **Reverse tunnel per viewer** (the chisel/ngrok pattern). While at least one workspace has Remote Control enabled, the daemon holds one outbound **control** WebSocket to the relay. When a viewer connects to `/v1/viewer/{device_id}`, the relay sends `{"open": "<conn_id>"}` down the control channel; the daemon dials a **data** WebSocket `/v1/device/conn/{conn_id}` and runs its existing per-connection handler over it. The relay copies bytes both ways and closes both ends when either drops.
- **One WebSocket binary message = one existing 16-byte-header protocol frame.** The relay never parses frames. The daemon protocol (`protocol.rs`, `PROTOCOL_VERSION` 1) does not change.
- Both hops are outbound TLS to Cloudflare → tunnel → relay pod. No inbound ports anywhere. Both sides ping every 30 s (Cloudflare drops idle WebSockets at ~100 s).
- Relay = one extra Deployment in `OmniAgent-Core` built from the same image with a different uvicorn entrypoint. **Single replica in v1** — traffic is tiny (a busy terminal is ~1 KB/s; 100 concurrent viewers ≈ 4 Mbit/s) and a second replica would need Redis-routed splicing. Marked `# ponytail: single replica, in-process registry; redis-routed splice if we ever need >1`.

## 2. Identity, authorization, registry

### Viewer authentication
The normal 15-minute access JWT (HS256, `JWT_SECRET`, `sub` = user id — `omniagent/api/jwt_auth.py`), presented as `Authorization: Bearer` at WebSocket connect and checked **once**; an established connection is not re-checked. Reconnects use whatever fresh token `AuthClient` holds.

### Host authentication — device tokens
The daemon must work with the app closed, so it cannot depend on a 15-minute token.

- On the first **Enable Remote Control** with no device token stored, the app calls `POST /v1/relay/devices` with the access token and `{name: <hostname>}`. Core inserts a row in a new table:

  ```
  relay_devices(device_id uuid pk, user_id fk, name text, token_hash text,
                created_at timestamptz, last_seen_at timestamptz null)
  ```

  and returns `{device_id, token}` **once**. `token` = 32 random bytes (hex); only its SHA-256 is stored.
- The app hands the token to the daemon via `SetSetting("relay_device_token", {device_id, token})`. It never leaves the host except as the `Authorization: Bearer` header to the relay.
- The relay validates device tokens by hash lookup. **Deleting the row revokes the machine everywhere** (`DELETE /v1/relay/devices/{device_id}`; no Settings UI for it in v1).
- Device tokens do not expire in v1.

### Per-workspace enablement and the projection
- Enabled workspace ids are stored in a settings row `remote_control_workspaces` (`[id, …]`).
- The app derives and writes a settings row `remote_control`:

  ```json
  {"workspaces":[{"id":"…","name":"…","sessions":[{"id":"…","title":"…","engine":"claude","group":"…"}]}]}
  ```

  containing **only** enabled workspaces. It is rewritten on every toggle and on every layout persist, so a session added to an enabled workspace appears remotely without anyone remembering to refresh. Nothing else on the host is ever visible remotely.
- The daemon keeps its control channel open **iff** `remote_control` lists ≥ 1 workspace **and** `relay_device_token` exists. When the projection becomes empty it closes the control channel, which drops every remote viewer immediately.
- Viewers read the same `remote_control` row over the relay to draw the machine's workspaces.

### What a remote connection may do — the trust boundary lives in the daemon
Remote connections never take the peer-UID path. Each frame passes an authorizer before the existing dispatch:

| Allowed (session id must be in the projection) | Denied → `Error` |
|---|---|
| `Hello`, `ListSessions` (filtered to projected ids), `Attach`, `Input`, `Resize`, `Interrupt`, `Detach`, `GetSetting("remote_control")` | `Kill`, `CreateSession`, `SetSetting`, `GetSetting(anything else)`, every Brain/Roots RPC |

The projection is a SQLite point read per authorization (microseconds); there is no cache to invalidate.

## 3. Daemon changes (`crates/omniagent-pty-daemon`)

- `handle_client(stream: UnixStream, …)` (`server.rs:208`) becomes generic over `AsyncRead + AsyncWrite + Unpin` and takes `ClientTrust::{Local, Remote}`. The peer-UID check moves into the unix accept loop (Local only). `Remote` wraps dispatch with the authorizer from §2. The dispatch code itself is untouched.
- New `relay.rs`: one task spawned by `serve()`.
  - Observes `remote_control` and `relay_device_token` through a `tokio::sync::watch` channel that the `SetSetting` handler pokes on write — no polling.
  - While both are present: connect `wss://$OMNIAGENT_RELAY_URL/v1/device` with the device token, send hello `{"hostname", "daemon_version"}`, ping every 30 s, reconnect with exponential backoff 1 s → 30 s; a `401` stops retrying until the token row changes.
  - On `{"open": conn_id}`: dial `/v1/device/conn/{conn_id}` with the device token, adapt the WebSocket to a byte stream (`tokio_util::io::{StreamReader, SinkWriter}` over binary messages), spawn `handle_client(stream, …, ClientTrust::Remote)`.
  - Projection empties or token removed → close control channel and all data connections.
- `OMNIAGENT_RELAY_URL` defaults to `relay.omni-agent.ai`; overridden for staging and tests.
- New dependencies: `tokio-tungstenite` (rustls + webpki roots), `tokio-util` (io feature), `futures-util`. WebSocket + TLS is not something to hand-roll.

### Tests
- `tests/remote_authz.rs` — run the handler over `tokio::io::duplex` with `ClientTrust::Remote` and a projection listing session `s1`: `Kill` → `Error`; `Attach s2` → `Error`; `Attach s1` → `Snapshot`; `GetSetting("auth_signed_in")` → `Error`; `ListSessions` returns only `s1`.
- `tests/relay_loopback.rs` — an in-test tungstenite server plays relay: control connect → `open` → data connect → `Hello`/`HelloAck` round trip over the adapted stream.

## 4. App changes (`macos/`)

### Transport seam
`SessionConnection` gains `enum Transport { unixSocket(URL), webSocket(URL, bearer: () -> String?) }`. The WebSocket transport uses `URLSessionWebSocketTask` (stdlib, no dependency); one binary message = one frame, so `FrameCodec` and everything above the transport — attachments, sequence cursors, reconnect, re-attach, resume, `ResyncRequired` handling — are unchanged. Pings via `sendPing` every 30 s.

### `RelayClient.swift`
Small `URLSession` client next to `AuthClient`: `registerDevice(name:)`, `listDevices()`, `deleteDevice(id:)`, base URL `https://relay.omni-agent.ai` (`OMNIAGENT_RELAY_URL` override). Polls `listDevices()` every 30 s while signed in.

### Host side
- `WorkspacesTree` workspace context menu gains a check-toggle **Enable Remote Control**.
- `RemoteControlProjection` (pure function + a writer): recomputes `remote_control` from the persisted layout and `remote_control_workspaces`; invoked on every toggle and from the layout-persist path.
- First enable with no stored device token → `RelayClient.registerDevice(name: hostname)` → `SetSetting("relay_device_token", …)`.
- Enabled workspace rows show a trailing `globe` glyph.

### Viewer side
- Sidebar: one section per **online** machine (its `name`), each listing that machine's projected workspaces and sessions with the remote glyph `desktopcomputer.and.arrow.down` (the same symbol the **Resume remote session…** menu item adopts).
- Opening a remote session lazily opens **one** `SessionConnection(.webSocket("…/v1/viewer/{device_id}"))` per machine, shared by every pane on that machine. The pane reads that machine's `remote_control` row for structure and attaches with the usual `Attach`.
- Remote panes hide Kill / new-session affordances; their hover card reads "Remote · <machine>".
- The disabled **Resume remote session…** menu item (`WorkspacesHeaderMenus.swift:163`, `WorkspaceWindowController.swift:744`) becomes enabled and opens the spotlight pre-filtered to remote rows.
- Machine goes offline → its panes show "offline — reconnecting"; `SessionConnection` keeps retrying; the section disappears from the sidebar when `listDevices()` reports it offline.

### Spotlight (standing rule, 2026-08-28)
Remote machines, workspaces and sessions become palette rows built off the live device list — own symbol, subtitle naming the machine, `keywords`, an action `WorkspaceWindowController.run(_:)` dispatches — with a `CommandPaletteTests` case, in the same commit as the sidebar section.

### Predictive echo
Active only for remote connections. Two parts:

- **`PredictiveEchoModel`** (pure, testable): state `.unknown | .confirmed`; pending predictions `[(row, col, char)]`; a locally advanced predicted cursor.
  - `predict(bytes)`: a single printable character or backspace (0x7f/0x08) records a prediction; any other byte or escape sequence (Enter, arrows, ctrl keys) clears all predictions and resets to `.unknown`. Enter is sent but never predicted.
  - `reconcile(cellAt: (row, col) -> Character?)`: called after every real `feed()`. Each pending prediction matching its real cell is dropped as confirmed and the state becomes `.confirmed`; any mismatch drops every prediction and resets to `.unknown`.
  - A prediction older than 1 s without confirmation drops all predictions and resets to `.unknown`.
  - `drawn` = pending predictions if state is `.confirmed`, else none. This is mosh's confidence rule: the first keystroke of a burst is recorded but not drawn until its echo confirms, so password prompts and vim normal mode never flash text; every subsequent keystroke draws instantly.
- **Overlay layer** in `TerminalSurfaceView`: draws `drawn` glyphs at their cells with a faint underline, above the SwiftTerm view. **The terminal buffer is never mutated.** Hooked at `send(source:data:)` (`TerminalSurfaceView.swift:411`) and after `feed(_:isSnapshot:sequence:)` (`:309`).

Test: `PredictiveEchoTests` on the model alone — confirm on match; mismatch clears; control byte clears; timeout clears; `.unknown` draws nothing until first confirmation; `.confirmed` draws pending.

## 5. Relay service (`OmniAgent-Core`)

`omniagent/relay/main.py` — FastAPI on uvicorn, port 8081, same image as the API (`dockerfiles/Dockerfile.api`), entrypoint `uvicorn omniagent.relay.main:app --host 0.0.0.0 --port 8081`. Roughly 150 lines.

| Endpoint | Auth | Behaviour |
|---|---|---|
| `POST /v1/relay/devices` `{name}` | access JWT (`get_current_user_sub`) | insert `relay_devices` row; return `{device_id, token}` once |
| `GET /v1/relay/devices` | access JWT | user's devices `{device_id, name, online, last_seen_at}`; `online` = control connection present in-process |
| `DELETE /v1/relay/devices/{id}` | access JWT, owner | delete row; close its control connection |
| `WS /v1/device` | device token (hash lookup) | register `{device_id: ws}`; read hello; update `last_seen_at`; keep alive; unregister on close |
| `WS /v1/viewer/{device_id}` | access JWT; `sub` must own the device; device online else 503 | `conn_id = uuid4`; send `{"open": conn_id}` on control; wait ≤ 10 s for the data socket else 504; then splice |
| `WS /v1/device/conn/{conn_id}` | device token; `conn_id` pending for that device | completes the splice |

Splice = two `asyncio` tasks copying binary messages each way; when either socket closes, close the other. `/health` for probes.

- Alembic migration for `relay_devices`.
- K3s: `k3s/base/relay/{deployment,service}.yaml`, 1 replica, `LoadBalancer` on the next free MetalLB IPs — production `10.1.2.8`, staging `10.1.2.13` (in use today: `.5 .7` / `.10 .12`; `.14` SIP). Added to the base kustomization and both overlays.
- Cloudflare dashboard: tunnel public hostnames `relay.omni-agent.ai` → `10.1.2.8:8081`, `relay.omni-agent.dev` → `10.1.2.13:8081` (both names already resolve to Cloudflare).

### Tests
pytest + Starlette's WebSocket test client: register → device control connect → viewer connect → `open` → data connect → bytes flow both ways and either close closes the other; another user's JWT → 403; offline device → 503; revoked (deleted) device token → 401; data connect with an unknown `conn_id` → 404.

## 6. Failure modes

| Event | Behaviour |
|---|---|
| Host asleep / offline | Control WS drops; relay marks the device offline; viewer connections close; viewer panes show "offline — reconnecting" and retry; **host sessions run on untouched** |
| Relay restart / Core deploy | Daemon and viewers back off and reconnect; viewers resume via `after_sequence` → `Resume`, or `ResyncRequired` → fresh snapshot. Never affects local sessions |
| Slow viewer link | Existing 64-event per-client queue → `ResyncRequired` → snapshot |
| Access JWT expires mid-connection | Nothing; checked only at connect. Reconnect uses a fresh token |
| Remote Control disabled on the last workspace | Projection empties → daemon closes control channel → viewers drop at once |
| Device row deleted | Relay closes its control connection; daemon's reconnects get 401 and stop retrying until the token row changes |
| Local and remote type at once | Interleaved into the PTY, no lock |

## 7. Security invariants (each pinned by a test)

1. The allowlist and session-id check live in the **daemon**, not the relay.
2. Remote connections never take the peer-UID path.
3. The relay checks `sub` ownership on every viewer connect and every device REST call.
4. Device tokens are stored hashed and revocable by row deletion.
5. Only the `remote_control` settings row is readable remotely.

## 8. Explicitly not in v1

Creating or killing sessions remotely · end-to-end encryption · an "also attached from …" hint on the host (needs a protocol change) · a devices list in Settings · more than one relay replica · UDP/QUIC · device-token expiry/rotation.

## 9. Rollout

1. Core: migration + relay service + manifests to **staging** (`./deploy.sh staging`); Cloudflare hostname `relay.omni-agent.dev`.
2. ADE: daemon + app pointed at staging via `OMNIAGENT_RELAY_URL`; verify with two Macs signed in to the same account: enable → appears on the other Mac → type both ways → disable → disappears.
3. Core to **production**; Cloudflare hostname `relay.omni-agent.ai`.
4. App release via `scripts/rebuild-app.sh` with the production default.

Nothing here changes `PROTOCOL_VERSION`, the MCP contract, or any existing settings row.

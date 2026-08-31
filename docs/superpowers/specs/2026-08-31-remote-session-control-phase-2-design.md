# Remote Session Control, Phase 2 — Design Spec

- **Date:** 2026-08-31
- **Status:** Approved (interactively, by Bruno)
- **Scope:** `OmniAgent-ADE` — PTY daemon and native macOS app. No relay, Core, or edge changes.
- **Builds on:** `docs/superpowers/specs/2026-08-30-remote-session-control-design.md` (phase 1, shipped). That spec's topology, trust boundary, device tokens and relay are unchanged; this one refines what the two Macs show each other.

## Context

Phase 1 shipped and works end to end: the second Mac sees the host's shared sessions and types into them. Bruno's first real two-Mac session produced five findings. Four are defects; one is a product gap.

| # | Finding | Root cause |
|---|---|---|
| 1 | The host's terminal collapses into a narrow column when the smaller Mac attaches | `Resize` from any client is applied to the shared PTY (`server.rs:565-582`); vt100 truncates rather than reflows |
| 2 | The remote sidebar does not look like the host's — wrong structure, and three panes of one session appear as "Session 1" three times | `RemoteControlProjection.build` flattens panes into "sessions", discarding the host's tree |
| 3 | A machine only appears after quitting and reopening the viewer app | A refused viewer socket latches `shouldReconnect = false` permanently (`SessionConnection.swift:817-828`) and is only retried on a bearer change |
| 4 | Nothing on the host shows that a viewer is connected, and there is no way to disconnect one | The daemon has no connection registry and can only push to attachment subscribers |
| 5 | "+ → Resume remote session…" opens a filtered spotlight, not a list of machines | Product gap; phase 1 deliberately shipped the spotlight path only |

Decisions taken interactively (2026-08-31):

| Question | Decision |
|---|---|
| Terminal sizing | Both Macs keep their own window size and neither affects the other. One grid still exists — it belongs to the host; the viewer renders it scaled to fit |
| Reflowing content to the viewer's size | Rejected as impossible for a live TUI (see §1); scaled rendering is the answer |
| Share width (host deliberately picks a remote-friendly grid) | Not in this phase |
| Disconnect UX | Popover from the viewer count next to the globe, listing machines, each with Disconnect |
| What Disconnect means | Kick **and block** that machine until Remote Control is toggled off and on again |

## 1. Terminal sizing

### Why per-client grids are impossible

A session is one program writing to one screen buffer of N columns × M rows. Its updates are absolute (`ESC[12;40H` then text), computed for the size it was told it has. Re-laying-out that grid for a different column count fails twice over:

- **The layout is already baked into cells.** A terminal grid records characters, not intent. Box-drawing borders, right-aligned status segments and column alignment have nothing that says they were right-aligned or that a `╮` belongs to a box opened forty rows earlier. Paragraph text can be re-wrapped because terminals flag wrapped rows (`vt100` `row.wrap`, how Terminal.app reflows on resize); layout cannot.
- **The program keeps painting into the old coordinates.** Even a perfectly re-laid-out frame breaks on the next update, because the program is still addressing the original grid. This fails on the first keystroke, not gradually.

The only way to obtain a genuine 100-column layout is to tell the program it has 100 columns — resizing the PTY, which is the defect in finding 1. tmux and screen reach the same conclusion; neither offers per-client grids.

### What we do instead

- **The grid belongs to the host.** `authorize_remote` moves `Resize` from the shared-session allowlist to the deny arm: a remote client may never resize a session. This also closes a phase-1 trust-boundary hole (any viewer could resize any shared session).
- **The viewer never sends `Resize`.** `TerminalSurfaceView.flushResize()` returns early when `connection.isRemote`, so a remote pane's layout changes are local-only. Defence in depth: the app does not send it, and the daemon would refuse it.
- **The viewer renders the host's grid scaled to fit.** The remote pane's terminal is pinned to the host's `cols × rows` and drawn scaled into whatever space the pane has — the whole screen visible, type proportionally smaller, layout exact.
- **The host is never affected by anything the viewer does**, which is the requirement finding 1 is really about. Each Mac resizes its own window freely.
- If the host app is closed, no local client owns the size; the grid keeps its last value and the viewer still scales. No snapping when the host reopens.

### How the viewer learns the host's size

The daemon does not track a session's size today (`ManagedSession` has no size field; `TerminalState` is `{ parser, history, sequence }`). This phase adds it:

- `ManagedSession` records the last applied `(cols, rows)`, set at `CreateSession` and updated on every accepted `Resize`.
- A new server push `SessionResized` (`0x8c`, payload `{id, cols, rows}`) carries the grid. It is **sent on attach, immediately before the snapshot**, and again whenever the size changes, so a viewer knows the grid it must lay the snapshot out on and re-pins live afterwards. Local clients ignore it (their own view drives the size); remote clients act on it.
- The size does *not* ride along inside the snapshot: there is no `SnapshotPayload` struct to add fields to — a snapshot is a raw wire format (the session's bytes), so a separate framed message is the only place a `(cols, rows)` pair can go. Both the attach copy and the change pushes are stamped with the session's sequence rather than a request id, so one message kind never means two things in the same header field.

### Rendering mechanics (viewer only)

SwiftTerm forces `terminal.resize(bounds ÷ cell)` on every `setFrameSize` (`MacTerminalView.swift:966-987`), so pinning a grid means controlling the arithmetic rather than fighting it:

1. Compute the scale that fits the host grid: `scale = min(paneWidth / (hostCols × cellW), paneHeight / (hostRows × cellH))` at the pane's normal font.
2. Give the terminal view a frame of exactly `hostCols × cellW` by `hostRows × cellH` (its natural size for that grid, so its own arithmetic yields the host's cols/rows), and apply `scale` as a layer transform on its container, centred, letterboxing the remainder in the pane background.
3. Set `metalScaleFactorOverride` to `scale × backingScaleFactor` — this SwiftTerm fork exposes it precisely so "client applications that apply their own view transforms" rasterize glyphs at true on-screen resolution. Scaled text stays crisp instead of looking like a zoomed bitmap.
4. `⌘+` / `⌘−` / `⌘0` override the scale for a remote pane: zoom in past fit and pan, or return to fit. Scale ceiling 2.0, floor is fit-to-pane.

Scaling never changes the grid, so it is invisible to the daemon and to the host.

## 2. The viewer's sidebar mirrors the host

### Projection schema v2

Phase 1's projection flattened every pane into a "session" whose title fell back to the session group's label, which is why three panes of one session render as "Session 1" three times. v2 carries the host's actual tree:

```json
{"version":2,
 "workspaces":[{"id":"…","name":"…","tint":"#RRGGBB|null","order":0,
   "sessions":[{"id":"…","label":"…","order":0,
     "panes":[{"id":"…","title":"…","engine":"claude","kind":"terminal","order":0}]}]}]}
```

- `workspaces[].order` and `sessions[].order` and `panes[].order` preserve the host's ordering exactly; the viewer sorts by them and never re-sorts.
- `sessions[].id` is the host's session-group id; `panes[].id` is the daemon session id a viewer attaches to. **The attachable id is the pane id**, as in phase 1.
- `kind` is the pane kind (`terminal`, `editor`, `browser`, …). Only `terminal` panes are attachable; others are listed for structural fidelity and are not openable remotely in this phase.
- `tint` mirrors the host's workspace tint so colours match.

Writer: `RemoteControlProjection.build` derives the tree from the same `SessionOutline.group(...)` the host sidebar uses, so the two cannot drift.

Reader (daemon): `remote_session_ids` walks `workspaces[].sessions[].panes[].id`. `remote_control_active` still answers "≥ 1 workspace" and is unchanged.

**Compatibility:** a v1 row (no `version` key, panes flattened as `sessions`) is still parsed by both sides — the daemon accepts either shape, and the viewer renders a v1 projection as one session per entry. This matters only during the window where one Mac has phase 2 and the other does not; both are Bruno's and both will update.

### Rendering

The viewer builds `WorkspaceTreeEntry` / `SessionGroupNode` values from the projection and renders them through the **same** row types and layout the local tree uses (`WorkspacesTree.renderRemoteMachines` delegates to the ordinary workspace/session rendering rather than its own row variant). The only differences from a local workspace row are the glyph (`desktopcomputer.and.arrow.down`) and that clicking a pane routes to `openRemoteSession`. Same indentation, same ordering, same session→pane nesting, same labels, same tint.

## 3. Discovery: never require a relaunch

Three changes, all in the viewer:

1. **`SessionConnectionError.unauthorized` stops being permanently fatal.** `webSocketFailed` distinguishes:
   - `401` → the bearer was refused: park, and report `.unauthorized` as today (a new token releases it).
   - `403`, `503`, and every other non-2xx → transient: keep `shouldReconnect = true` and back off as normal (1 s → 30 s).
   The phase-1 conflation is what latched a machine off after one early dial against a host whose control channel had not registered yet.
2. **A device that is online in a poll is always re-dialled.** `RemoteMachinesModel.apply` drops the "only if the bearer changed" condition for devices whose connection is not currently live: an online device with no live connection is dialled, subject to the connection's own backoff. The `unauthorized` latch is kept only for `401`.
3. **A viewer `401` forces a token refresh immediately** rather than waiting for `listDevices()` to fail (~15 minutes today). `RemoteMachinesModel` calls the same `refreshSessionIfStale()` path on a `.unauthorized` error.

Result: enabling Remote Control on the host makes the machine appear on the other Mac within one poll (≤ 30 s), with no relaunch, and a Mac that was refused once recovers by itself.

## 4. The + menu picker

**Resume remote session…** (`WorkspacesHeaderMenus`, the `+` menu, and the Session menu item) opens a picker sheet instead of the filtered spotlight:

- Liquid-glass sheet in the house modal style (`PaneAskOverlayView` building blocks; never `NSAlert`), presented over the window.
- Content: one section per online machine, its shared workspaces, sessions and terminal panes, in the host's order — the same tree §2 defines. Each row shows what it is; Return or double-click opens it via `openRemoteSession`.
- Empty states, worded plainly: "No other Macs are sharing sessions" when the device list is empty; "Signing in…" when signed out; "<name> is offline" for a known-but-offline machine.
- The spotlight rows from phase 1 remain as the fast path, unchanged.

## 5. Presence, and disconnecting a viewer

### Daemon: a connection registry

`ClientContext` gains `connections: Arc<Mutex<HashMap<ConnectionId, ConnectionEntry>>>` where `ConnectionEntry` is `{ trust, viewer: Option<ViewerIdentity>, attached: HashSet<String>, cancel: CancellationToken, since: SystemTime }`. `serve_client` registers on entry, updates `attached` on `Attach`/`Detach`, and removes on exit. This is the first per-connection state the daemon keeps; it is what makes both presence and the kick possible, and it is deliberately small.

**No writer lives in the entry, and the registry does no I/O.** The roster is published into a `watch` channel — a synchronous, non-blocking, latest-wins handoff — and each *local* connection owns a `PresenceFeed` task that writes what it finds there to its own socket. Holding a `SharedWriter` per entry would have meant writing to every client in turn from inside the registry's lock, so one client that stopped draining its socket could stall presence and the attach/detach dispatch of every other connection. With no writer reachable from the lock, a stalled client can only ever wedge its own feed task.

`ViewerIdentity` is `{ viewer_id: String, machine_name: String }`, carried in `HelloPayload` (which today holds only `client`). Both fields are added as `Option` so older clients still parse.

**Honest limitation, recorded rather than papered over:** the viewer's identity is self-reported by the viewer app. That is adequate here because both Macs belong to the same account and the relay already refuses anyone else — it is a labelling and convenience mechanism, not an authorization boundary. Making it tamper-proof means having the relay assert identity in its `{"open": …}` message; that is a later hardening, not this phase.

### Presence push

New server push `RemoteViewers` (`0x8d`), sent to **local** connections only, whenever the registry's remote entries change:

```json
{"viewers":[{"viewer_id":"…","machine_name":"…","sessions":["<pane id>", …],"since":"<rfc3339>"}]}
```

A local client also gets the current roster right after `HelloAck`, so a freshly opened app is immediately correct. New client kind `ListViewers` (`0x1a`) returns the same payload on demand; it is in `authorize_remote`'s deny arm, like everything not explicitly allowed.

### Host UI

- **Workspace row:** beside the globe, a `display` glyph with the count of machines currently attached to any pane of that workspace. Hidden at zero. Tooltip names the machines.
- **Pane tab:** a pane with a live viewer wears the remote glyph and the machine's name in the filmstrip item's detail line (`PaneFilmstripItemView`), so it is obvious which pane is being watched.
- **Popover:** clicking the count glyph opens a list of connected machines — name, how long, which panes — each with **Disconnect**.

### Disconnect = kick and block

New client kind `DisconnectViewer` (`0x1b`), local-only (deny arm for remote):

1. The daemon cancels that connection's token, which drops its data WebSocket immediately.
2. The viewer id is added to a blocklist in the settings row `remote_control_blocked` (`["<viewer_id>", …]`), and `serve_client` refuses a `Hello` from a blocked viewer id with `Error` and closes. **The daemon writes this row** (it is the enforcer, and the kick must hold even with the app closed).
3. **The app clears the whole row** — a single `SetSetting("remote_control_blocked", "[]")` — whenever Remote Control is switched *on* for any workspace. The blocklist is global rather than per-workspace: it answers "which machines may not reach this Mac", and turning sharing back on anywhere is the deliberate act that forgives them. Popover copy says so: "Blocked until you turn Remote Control off and on again." Both sides writing one small array is safe here: the two writes are a human action apart, and last-writer-wins on a list this size has no failure mode worth machinery.

The viewer sees its connection close and, being blocked, its retries close immediately; its sidebar shows the machine as unavailable rather than spinning.

## 6. Failure modes

| Event | Behaviour |
|---|---|
| Viewer window resized | Only the viewer's scale changes; no protocol traffic; host untouched |
| Host window resized | `Resize` applied as today; `SessionResized` pushed; attached viewers re-pin and re-scale |
| Remote client sends `Resize` anyway | `Error`, per `authorize_remote`; pinned by a `remote_authz` test |
| Host app closed | Grid keeps its last size; viewer keeps rendering at that size |
| Viewer refused with 403/503 | Backoff retry; recovers without relaunch |
| Viewer refused with 401 | Parks until a fresh token; a refresh is requested immediately |
| Disconnected viewer retries | `Hello` refused while blocked; sidebar marks the machine unavailable |
| Blocked viewer, host re-enables Remote Control | Blocklist entry cleared; next poll reconnects normally |
| v1 projection on the wire | Parsed by both sides; rendered as one session per entry |

## 7. Security invariants (each pinned by a test)

1. A remote client can never resize a session (`authorize_remote` deny arm).
2. `ListViewers` and `DisconnectViewer` are local-only.
3. `RemoteViewers` is pushed to local connections only — a viewer never learns about other viewers.
4. A blocked viewer id cannot complete `Hello`.
5. Phase 1's invariants are unchanged and their tests still pass.

## 8. Explicitly not in this phase

Share width (host-chosen remote-friendly grid) · relay-asserted viewer identity · opening non-terminal panes remotely · per-viewer read-only mode · reflowing scrollback for line-oriented sessions · the phase-1 follow-ups already on file (sign-out cleanup, detach-on-close, device cap, log noise).

## 9. Order of work

Sizing (§1) and sidebar mirroring (§2) first — they are what Bruno feels immediately — then discovery and the picker (§3, §4), then presence and disconnect (§5). Each lands with its tests; the phase ends with `scripts/rebuild-app.sh` per the packaging rule.

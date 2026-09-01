# Remote Environment Sharing (Remote Session Control, Phase 3) — Design Spec

- **Date:** 2026-09-01
- **Status:** Approved (interactively, by Bruno)
- **Scope:** `OmniAgent-ADE` (PTY daemon + native macOS app) and `OmniAgent-Core` (relay asserts viewer identity). No edge or Cloudflare changes.
- **Builds on and partly replaces:** `2026-08-30-remote-session-control-design.md` (phase 1) and `2026-08-31-remote-session-control-phase-2-design.md` (phase 2). The relay topology, device tokens and the daemon's per-connection handler are unchanged. The *sharing model* is replaced.

## Context

Phases 1 and 2 share **workspaces**: the host picks which ones are visible, the viewer browses a projection of them in its own sidebar and attaches to individual terminal panes. Bruno's decision (2026-09-01) is to stop sharing workspaces and start sharing the **machine**. A remote computer should not borrow a pane; it should sit down at the host — same workspaces, same Home, same gauges, same limits, same engines — and the host should know, in unmistakable terms, that someone is there.

That reframing is what makes the design small. The app is already *a client of a daemon over a `SessionConnection`*, and phase 1 already gave that connection a `Transport` enum with a WebSocket case. There is exactly one local connection, built at `AppDelegate.swift:28`. **Remote environment sharing is that one connection pointed at a different daemon**, plus a wire path for the handful of things the app computes in-process rather than asking the daemon for.

Decisions taken interactively (2026-09-01):

| Question | Decision |
|---|---|
| How the viewer "becomes" the host | Native remote client driving the host's daemon. Not a pixel stream: terminal typing would lose predictive echo and pay full relay round-trip latency, text would be a scaled bitmap, and bandwidth would jump from ~1 KB/s to megabits |
| Host app closed | Sharing works whenever the menu bar icon is there — a hidden window is still a running app. A fully quit app is simply offline |
| Simultaneous viewers | One at a time, exclusive. A second is refused with "in use by ‹machine›" |
| Activity log | Durable JSONL under the data root, live table in the takeover panel, history in Settings › Remote |
| Pane kinds openable remotely | Terminals. Editor and browser panes list but do not open — remote editing means host filesystem read/write over the relay and deserves its own phase |
| Remote "Add local folder…" | New `ListDirectory` RPC: names and is-directory flags, no file contents |
| What the viewer sees before connecting | Its own local environment, unchanged. Nothing about the host leaves the host until a connection exists and the host has been told |
| Block | Blocked until explicitly unblocked in Settings › Remote — no longer forgiven by toggling sharing |
| Host approval before connect | Auto-accept. The host is told, not asked; its controls are Terminate and Block, after the fact |
| Whose sessions a machine may see | Only the signed-in account's own. Checked independently by the relay *and* by the daemon (§9) |
| Chaining | Forbidden. One remote session per machine, in either direction (§3) |

## 1. What is deleted

This phase removes more code than it adds. Listed first because the rest of the spec assumes it is gone.

- The workspace context-menu item **Enable Remote Control**, the `globe` glyph on workspace rows, and the `remote_control_workspaces` settings row.
- `RemoteControlProjection.swift` in full, the `remote_control` settings row, its v1/v2 shapes and every compatibility shim on both sides (`remote_session_ids`, the daemon's dual-shape parser, `PaneGridTests`/projection fixtures for it).
- The viewer's mirrored sidebar tree — `WorkspacesTree.renderRemoteMachines` and the remote row variants. The viewer's sidebar shows the host's real workspaces because it is *reading the host's `layout` row over the same RPCs the host uses*, not because anything projects them.
- `RemoteTerminalScaler.swift`, `metalScaleFactorOverride`, and the remote ⌘+/⌘−/⌘0 zoom overrides (§5).
- The `SessionResized` push (`0x8c`) and its handling. Nobody needs telling the grid size once the driver owns it.
- Phase 2's per-workspace viewer-count glyph and the pane filmstrip's "watched by ‹machine›" detail line: both live in a window that is covered by the takeover panel for the entire time they would have anything to say.
- `RemoteSessionPicker.swift`'s machine/workspace/session/pane tree collapses to a machine list — there is nothing to pick below the machine any more.

## 2. Sharing is one switch

- **Settings › Remote** (new section) and the menu bar dropdown both carry **Share this environment**.
- One settings row replaces two: `remote_sharing` = `{"enabled": true|false}`. `remote_control_blocked` keeps its phase-2 name and shape (`["<viewer_id>", …]`); only when it is cleared changes — no longer on toggling sharing, only on an explicit Unblock (§7).
- The daemon holds its relay control channel iff **all three** hold:
  1. `remote_sharing.enabled`
  2. `relay_device_token` exists
  3. at least one `ClientTrust::Local` connection is in the `ConnectionRegistry`

  Condition 3 is the "icon in the menu bar" rule, and it comes free from phase 2's registry. It is applied with a **5 s grace** after the last local connection goes: an app reconnect (or a `rebuild-app.sh` restart) must not flap a live remote session. `remote_control_active` in `server.rs` becomes this three-way test.
- Menu bar icon (`MenuBarController.swift`): template as today when sharing is off; **green** when sharing and idle; **blue** while a remote connection is live. Tinting means `isTemplate = false`, so the icon stops adapting to the menu bar's appearance — deliberate, since the whole point is that it stops looking ordinary.
- Settings › Remote also holds: this machine's name and device id, the blocked list with **Unblock** per row, and **Activity** (§8).

## 3. Trust boundary: a longer allowlist, never an open door

The standing repo rule — nothing becomes remote-reachable merely by being added to the dispatch — is unchanged. `authorize_remote` stays an explicit allowlist; it grows.

| Allowed for the lease holder | Denied |
|---|---|
| `Hello`, `ListSessions`, `Attach`, `Detach`, `Input`, `Resize`, `Interrupt`, `CreateSession`, `Kill`, `ListDirectory`, all `Roots*`, `BrainListProjects`, `BrainGetContext`, `BrainSearch`, `GetSetting`/`SetSetting` on any key not in the protected set | `ListViewers`, `DisconnectViewer`, `PublishHostState`, and `GetSetting`/`SetSetting` on the protected set: `remote_sharing`, `relay_device_token`, `remote_control_blocked`, and any key matching `auth_*` |

The protected set is the whole security argument in five keys: a remote client must not be able to grant itself access, silence its own logging, unblock itself, or read the host's credentials. It is one function, `protected_setting_key(&str) -> bool`, used by both the get and the set arm.

Session-id confinement is gone with the projection: the lease holder may reach any session on the host. That is what environment sharing means.

### The lease

At most one remote connection at a time. `serve_client` takes the lease at `Hello` under the registry lock; a second remote `Hello` is answered `Error("in use by <machine>")` and the connection closes. The lease is released when the connection ends, and dropping it is what returns the grid and the UI to the host (§5, §7).

### One remote session per machine, in either direction

A machine that is being driven must never be made to reach onward to a third machine, and a machine that is driving must not simultaneously be driven. No hops, no chains.

This is enforced structurally rather than by a rule, and the enforcement is free: **the viewer swaps its single connection**, so while machine B drives machine A, B's app is no longer attached to B's own daemon. Condition 3 of §2 fails on B, its control channel closes after the grace, and any machine dialling B is refused. When B disconnects, its app reattaches locally and B's sharing resumes by itself.

On top of that structural guarantee, the UI never offers the move: **Connect to ‹machine›** is disabled in the sidebar, the picker and the palette while a remote session is live, reading "End the session with ‹machine› first". On the host it is unreachable anyway — the takeover panel covers the window that holds it.

`remote_chaining.rs` pins the structural half: with the local connection gone past the grace, a remote `Hello` is refused.

### Protocol version

`PROTOCOL_VERSION` goes to **2**. Local skew is handled by shipping together (`rebuild-app.sh` restarts the daemon), but *remote* skew is real — Mac A updated, Mac B not — and phase 1's failure mode for an unknown message kind is a 0.25 s reconnect loop with a dead keyboard. A remote `Hello` carrying version 1 is refused with `Error("update OmniAgent on <machine>")`, which the viewer shows as exactly that instead of retrying.

## 4. `HostState`: the gauges, the limits, the engines

The sidebar's CPU/memory/GPU gauges are computed in-process (`NavigationSidebar.swift:477-514` — `host_statistics`, `host_statistics64`, IOKit accelerator performance), as are the Claude limits (`ClaudeUsageLimits`, from `/usage`) and engine availability and model lists (disk and subprocess probes in `EngineLauncher`/`ClaudeModel`). A viewer's app reading its *own* disk shows the wrong machine — this is the one class of state the daemon cannot already serve.

Two new message kinds:

- `PublishHostState` (`0x1c`), local-only, app → daemon.
- `HostState` (`0x8e`), daemon → the lease holder, on attach and on every publish.

Payload is opaque JSON the daemon stores and forwards without parsing:

```json
{"metrics":{"cpu":0.34,"mem":0.61,"gpu":0.12},
 "limits":{"sessionPercent":41,"sessionResets":"…","weekPercent":63,"weekResets":"…",
           "modelName":"Opus 5","modelPercent":22},
 "engines":{"claude":{"available":true},"codex":{"available":false},"antigravity":{"available":true}},
 "host":{"name":"Bruno's Mac Studio","os":"macOS 27.0","appVersion":"1.7.22"}}
```

The host app publishes **only while the lease is held** — metrics at 1 Hz, everything else on change. Nothing is computed or written when nobody is connected.

Deliberately not a settings row: 1 Hz would mean a SQLite write and a `settings_changed` notify every second, and the daemon watches that channel to decide whether to hold the relay open.

`ListDirectory` (`0x1d`) returns, via the ordinary `Response`, `[{name, is_dir}]` for one path — no file contents, no recursion. It exists so the remote "Add local folder…" browses the host's disk instead of the viewer's, and it stops well short of remote file read.

## 5. Whoever drives owns the grid

Phase 2 gave the grid to the host and had the viewer render it scaled, because both machines were using the app at once. Under exclusive takeover only one of them is, so the rule inverts:

- While the lease is held, the **viewer** owns the PTY size and sends `Resize` normally. `Resize` moves back into the remote allowlist. Terminals reflow at the remote computer's real resolution.
- The **host** app suppresses its own resizes for the duration: `TerminalSurfaceView.flushResize()` early-returns while sharing is live — the same line phase 2 added, with the opposite condition.
- On disconnect the host reclaims by sending its own size for every visible pane.
- The host's terminals are mismatched with their views while the lease is held. This is invisible: the takeover panel covers the window (§7).

## 6. Viewer: the same window, transformed

Connecting to a machine does not open a second window and does not touch the viewer's own workspaces. It swaps `WorkspaceWindowController`'s connection from the local socket to `.webSocket(…)` and reloads.

**The connect ceremony.** A full-window liquid-glass overlay in the focus-mode treatment (`PaneAskOverlayView` building blocks; never `NSAlert`), the OmniAgent mark, and four lines that are **real milestones, not a progress animation**:

1. *Connecting to ‹machine›…* — WebSocket dial to `/v1/viewer/{device_id}`
2. *Establishing a secure line…* — relay opens the data channel, daemon dials it
3. *Confirming credentials…* — `Hello`/`HelloAck`, lease granted
4. *Loading environment…* — `layout`, `ListSessions`, first `HostState`

A step that fails shows its own failure in place ("‹machine› is in use by MacBook Pro", "update OmniAgent on ‹machine›") rather than a generic error. On success: a green check, a fade, and the host's environment is simply there.

**While connected.** The sidebar carries a **Remote live session** widget in the same liquid glass as the update and limits cards, above them: host name, elapsed time, and a red **End session** button. Everything else in the window is the host's — its workspaces, its Home, its gauges and limits from `HostState`, its engine availability.

**Connect to ‹machine›** is disabled everywhere for the duration (§3). Terminal panes attach and type as today, with predictive echo. Editor and browser panes appear in the tree and say "open on the host". Disconnecting swaps the connection back; the viewer's own environment returns untouched.

## 7. Host: the takeover panel

A screen-covering glass window above the workspace window, which stays visible and dimmed behind it — terminals keep updating there, so the host can watch the work happen. **No dismiss and no minimize:** while someone is connected, the panel is the app. ⌘Q still quits, and quitting ends sharing.

- **Header:** state line (*Setting up connection…* → *Connected*), the machine name.
- **Identity grid** (§9): account, IP ✓, country ✓, OS, app version, connected since. A small verified glyph marks the fields the relay asserted; machine name and OS are self-reported and unmarked.
- **Activity table** (§8), filling the rest.
- **Actions:** **Terminate** — kick this connection, sharing stays on, the machine may reconnect. **Block** — kick and add the viewer id to `remote_control_blocked`, refused at `Hello` until unblocked in Settings › Remote.

`DisconnectViewer` (`0x1b`, phase 2) gains a `block: bool` field; phase 2's behaviour was always-block, which is now the `true` arm. Unblocking is the app rewriting `remote_control_blocked` without that id — the row is already written by both sides a human action apart.

## 8. The activity log — daemon-witnessed only

Nothing in the log is reported by the viewer. A self-reported audit trail on a security surface is worse than none, because it looks like evidence. The daemon logs frames it actually received, from the connection that actually sent them.

Each entry `{ts, kind, summary, detail}` is appended to `‹data root›/remote-activity.jsonl` (rotated at 8 MB, one previous file kept) and pushed live to local connections as `RemoteActivity` (`0x8f`).

| Frame | Row summary | Expands to |
|---|---|---|
| connection opened | Connected from ‹machine› (‹ip›) | full identity block |
| `Attach` | Opened ‹pane title› in ‹session› · ‹workspace› | — |
| `CreateSession` | Started a ‹engine› terminal in ‹workspace› | cwd, command |
| `Input`, coalesced to CR | Sent a prompt to ‹pane› (‹engine›) | the full text typed |
| `Interrupt` | Interrupted ‹pane› | — |
| `Kill` | Closed ‹pane› | — |
| `SetSetting("layout")` | Changed the workspace layout | — |
| `Roots*` | Added / renamed / re-ingested workspace ‹name› | path |
| `ListDirectory` | Browsed ‹path› | — |
| `BrainSearch` | Searched the brain for "‹q›" | query |
| connection closed | Disconnected · ‹duration› | — |

Rows with nothing more do not expand — clicking a session is one line and no detail. Navigation that happens purely inside the viewer's own UI touches the host not at all and correctly produces no row; every row in the table is something that actually happened to this machine.

`Input` is buffered per session and flushed to one entry on CR, on `Interrupt`, or after 5 s of quiet, so a typed prompt is one row rather than one row per keystroke.

**Ceiling, recorded rather than papered over:** logged input runs through the repo's existing transcript secret redaction, but the daemon cannot tell a password prompt from a shell prompt. Typed secrets can land in the log. `# ponytail: redaction only; PTY echo-state detection if this ever bites`.

Settings › Remote › **Activity** reads the same file: past connections, newest first, each expanding to its rows.

## 9. The relay asserts who is connecting — and the daemon checks it is you (`OmniAgent-Core`)

Phase 2 recorded that `ViewerIdentity` is self-reported by the viewer app, adequate for a label and inadequate for a trust panel. The panel in §7 is a trust panel, so this phase closes it.

The relay already authenticates the viewer's JWT at `WS /v1/viewer/{device_id}`. It now includes what it knows in the control-channel message:

```json
{"open":"<conn_id>",
 "viewer":{"user_sub":"…","account_email":"…","ip":"203.0.113.7","country":"DE",
           "client":"OmniAgent/1.7.22 macOS 27.0"}}
```

- `ip` from `CF-Connecting-IP`, `country` from `CF-IPCountry` — both set by Cloudflare at the edge and not settable by the client.
- **City is omitted, not faked.** `CF-IPCity` is an Enterprise-plan header, and geolocating the IP through a third-party API would hand every viewer IP to that third party for a line of UI copy.
- The daemon stores this in `ConnectionEntry.viewer` alongside the self-reported name and surfaces both, distinguishably, to local clients.

No new endpoint, no schema change, no manifest change: one dictionary added to a message the relay already sends.

### Nobody ever sees another person's sessions

This is the invariant the whole feature rests on, so it is checked **twice, in two different processes, on two different facts**. Either check alone would be sufficient; neither is trusted to be.

**The relay (as today).** `GET /v1/relay/devices` returns only rows whose `user_id` is the caller's `sub`, and `WS /v1/viewer/{device_id}` refuses with 403 unless the caller's `sub` owns that device. A device id is therefore not a capability: knowing someone else's is useless. Device tokens are stored only as SHA-256 and identify a machine, never a person.

**The daemon (new).** The relay now asserts `account_email` **in the `open` control message, not in the client's `Hello`** — the daemon carries it from `conn_id` onto the data connection before dispatch begins, and a data connection whose `conn_id` has no asserted identity is refused outright. A check run on a value the connecting client supplies would check nothing. The daemon is already serving exactly one account's data — the `current-account` pointer names it, and the data dir is `<root>/accounts/<id>/` where `<id> = Store::account_dir_id(email)`. So the daemon hashes the asserted email with the same function and refuses the connection unless it equals the account directory it is serving:

```
account_dir_id(viewer.account_email) == the account dir this daemon started into  →  proceed
otherwise                                                                        →  Error, close
```

No new identifier, no new settings row, no new hash: the check reuses the function that decides whose files these are in the first place. A relay bug, a mis-routed splice, or a compromised relay cannot hand machine A's sessions to a different person's machine, because the daemon independently refuses anyone who is not the account it is serving.

A signed-out host has no account dir and no `auth_account_email`; it also has no device token and no control channel, so the question does not arise — but the check fails closed there too.

## 10. Spotlight (standing rule, 2026-08-28)

Rows, built off live lists so later additions appear by themselves, each with symbol, subtitle, keywords and a `WorkspaceWindowController.run(_:)` action, plus `CommandPaletteTests` cases in the same commit:

- Settings › Remote, and its items: Share this environment, Blocked machines, Activity
- **Connect to ‹machine›** per online device
- **End remote session** (present only while connected)
- **Terminate connection** / **Block this machine** (present only while the lease is held)

## 11. Failure modes

| Event | Behaviour |
|---|---|
| Host app quits while connected | Last local connection goes; after the 5 s grace the control channel closes and the remote drops with "‹machine› went offline" |
| Host app reconnects (daemon restart, rebuild) | Inside the grace: nothing happens, the remote session survives |
| Second machine tries to connect | `Error("in use by ‹machine›")` at `Hello`; the ceremony shows it at step 3 |
| Version skew between the two Macs | `Hello` refused with "update OmniAgent on ‹machine›"; no reconnect loop |
| Terminate | Connection cancelled; host reclaims the grid and the panel closes; the machine may reconnect |
| Block | Same, plus the viewer id is refused at `Hello` until unblocked in Settings |
| Sharing switched off while connected | Control channel closes; identical to Terminate, and no reconnect is possible |
| Relay restart / Core deploy | Both sides back off and reconnect; the viewer re-runs the ceremony. Host sessions run on untouched |
| Viewer link drops mid-session | Lease released on close; host panel closes; sessions keep running |
| Host is at the login window / display asleep | Unaffected — the app is running, the daemon is running, no window server work is involved |
| A different account's machine dials this one | Refused twice: 403 at the relay, and `Error` at the daemon's account check even if it somehow arrived |
| Host switches account while sharing | Switching accounts restarts the daemon; the control channel goes with it and the remote drops |
| Viewer tries to connect onward to a third machine | The action is disabled; and B's own control channel is already closed because its app is not attached locally |

## 12. Security invariants (each pinned by a test)

1. The allowlist and the protected-key set live in the **daemon**, not the relay or the app.
2. A remote client can never get or set `remote_sharing`, `relay_device_token`, `remote_control_blocked`, or any `auth_*` key.
3. `ListViewers`, `DisconnectViewer` and `PublishHostState` are local-only.
4. At most one remote connection holds the lease; the second is refused.
5. No remote connection is accepted unless a local app connection exists.
6. A blocked viewer id cannot complete `Hello`.
7. Every logged entry originates in a frame the daemon received; no log entry is ever written from viewer-supplied text describing itself.
8. `remote-activity.jsonl` is written by the daemon and is not remotely readable or writable.
9. The relay refuses a viewer whose `sub` does not own the device, and lists only that user's devices.
10. The daemon independently refuses a viewer whose asserted account does not hash to the account directory it is serving — a second check, in a second process, on a second fact.
11. A machine that is driving another cannot be driven, and a machine being driven cannot reach onward.

## 13. Tests

**Daemon** (`crates/omniagent-pty-daemon/tests/`)
- `remote_authz.rs` — rewritten for the new allowlist: `CreateSession`/`Kill`/`Resize`/`Roots*`/`ListDirectory` accepted; every protected key refused on both get and set; `ListViewers`/`DisconnectViewer`/`PublishHostState` refused.
- `remote_lease.rs` — second remote `Hello` refused while the first holds the lease; the lease is released on close; a remote `Hello` is refused when no local connection exists; the 5 s grace survives a local reconnect.
- `remote_activity.rs` — a frame sequence produces the expected rows; `Input` coalesces to one entry on CR; the file is appended and rotates; redaction runs before the write.
- `remote_account_isolation.rs` — a connection whose relay-asserted `account_email` hashes to a different account dir is refused and closes; the matching email proceeds; a connection with no asserted identity, or one whose `Hello` claims an email different from the asserted one, is refused.
- `remote_chaining.rs` — no remote `Hello` is accepted once the local connection has been gone past the grace.
- `protocol.rs` round-trip cases for `ListDirectory`, `PublishHostState`, `HostState`, `RemoteActivity`, and the version-2 `Hello` refusal.

**App** (`macos/OmniAgentTests/`)
- `RemoteSharingTests` — the three-way sharing condition; menu bar icon state for off/green/blue.
- `TakeoverPanelTests` — identity grid renders asserted and self-reported fields distinguishably; Terminate and Block send the right `DisconnectViewer`; the panel has no dismiss path.
- `ActivityTableTests` — rows with no detail do not expand; rows with detail do; the Settings history reads the file.
- `ConnectCeremonyTests` — the four steps advance on their real milestones, and a failure at each step shows that step's message.
- `RemoteChainingTests` — Connect to ‹machine› is disabled in the sidebar, picker and palette while a session is live.
- `CommandPaletteTests` — the §10 rows exist.
- Deletion coverage: the projection, scaler and mirrored-tree tests are removed with their code.

**Core** (`OmniAgent-Core`)
- pytest: the `open` message carries `viewer.ip`/`viewer.country`/`viewer.account_email`; absent CF headers omit the fields rather than inventing them.
- pytest: another user's JWT gets 403 at `/v1/viewer/{device_id}`, and `GET /v1/relay/devices` never returns a device it does not own (phase 1 cases, kept and extended to the new payload).

## 14. Order of work

1. **Sharing switch** — `remote_sharing`, Settings › Remote, menu bar toggle and colours, and every deletion in §1.
2. **Lease and allowlist** — exclusivity, the local-connection condition and its grace, protected keys, `ListDirectory`, `PROTOCOL_VERSION` 2.
3. **Identity, isolation and the panel** — the Core relay change (including `account_email`) and the daemon's account check, then the host takeover panel with Terminate, Block and the Settings unblock list.
4. **Activity log** — daemon JSONL and push, the panel's table, Settings › Remote › Activity.
5. **The environment itself** — `PublishHostState`/`HostState`, the connection swap, the connect ceremony, the sidebar Remote live session widget, grid ownership.

Step 3 precedes step 5 deliberately: the lease is not widened to a full environment before the host can see who has it and take it back.

Each step lands with its tests. The phase ends with `scripts/rebuild-app.sh` per the packaging rule.

## 15. Explicitly not in this phase

Remote editor and browser panes (host filesystem read/write is its own phase and its own security review) · a host approval prompt before a connection is accepted · more than one simultaneous viewer · city-level geolocation · end-to-end encryption · relay multi-replica · device-token rotation · read-only viewer mode.

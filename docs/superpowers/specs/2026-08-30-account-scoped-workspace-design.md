# Account-scoped workspace: mandatory sign-in, per-account data, logout tears down

Date: 2026-08-30 · Status: approved in chat by Bruno (approach A, with legacy migration) · Author: Claude session "Unused code review"

## Goal

Only the signed-in account can see its sessions and workspaces. Concretely, Bruno's words:

- "It's not allowed anymore to use the app without being logged on."
- "If the user logs out, the daemon gets destroyed, the main window closes and only the window to log in is visible."
- "If a new user logs in, it's empty and everything is new. If the old user logs in with their account, everything comes back the way they were — with new terminals."
- "The data in the top header bar [the menu bar status item] is included only after login; if the user logs out it goes away. The first line of its menu must say: logged in as {name}."
- "Do not kill the daemon on your choice. Just do it if I allow." → the app never restarts a daemon that has running sessions without asking first; the developer's live daemon is never touched during this work (`rebuild-app.sh --keep-daemon`, Preview channel for end-to-end checks).

## Non-goals

- Multi-user *concurrency* on one Mac (two accounts signed in at once). One account at a time.
- Server-side scoping. Core already keys everything by account; this is about the local data dir.
- Encrypting or hiding one account's directory from another macOS user of the same Mac account. Directory separation is the boundary.

## Approach A — per-account data directory selected by a pointer file

Every crate and the app resolve the local data directory through `brain_core::Store::default_data_dir()` (daemon, `brain` CLI, `omniagent-mcp`) and its Swift twin `DaemonPaths.resolve`. Both gain one indirection:

```
root = $OMNIAGENT_ADE_DATA_DIR  or  ~/Library/Application Support/OmniAgent-ADE   (unchanged)
if root/current-account exists and holds a non-empty id:
    data dir = root/accounts/<id>/
else:
    data dir = root                                                                  (unchanged)
```

- `<id>` = first 16 hex chars of SHA-256 of the lower-cased, trimmed account email. Stable, filesystem-safe, no PII in the path.
- Pointer absent = signed out. The daemon launchd keeps alive while nobody is signed in serves `root`, which after the one-time migration below holds no user data; nothing is on screen in that state anyway.
- `OMNIAGENT_ADE_DATA_DIR` keeps overriding the *root* exactly as today. Existing tests, which set it to a temp dir with no pointer, see no change.
- The LaunchAgent plist keeps `OMNIAGENT_ADE_DATA_DIR=<root>`; the daemon reads the pointer at startup, so a restart is what moves it between accounts. It never re-reads the pointer while running.

Because the daemon is the sole owner of `brain.db`, transcripts and the settings table, scoping the directory scopes everything: brain, ingested projects (roots), Markdown memory, transcripts, `layout`, `editor_panes_native`, `auth_persona`, closed workspaces, usage analytics — with no per-row work.

### One-time migration of the developer's existing data

At daemon startup, after resolving `data dir = root/accounts/<id>/`: if `root/accounts/` did not exist before this start **and** `root/brain.db` exists, move `root/brain.db` (+ `-wal`, `-shm`), `root/brain/` and `root/transcripts/` into the account dir before opening the store. Done in Rust (`brain_core::Store::adopt_legacy_data(root, account_dir)`), called by the daemon before `bind`, so no other process holds the files. Only the first account ever created gets this; every later account starts empty.

The app never moves files itself.

## App behaviour

### Sign-in is mandatory

- `AuthGateAction.skipLogin` and the "Continue without signing in" button are removed. The gate resolves only through a real sign-in. (Its window already has no close button; ⌘Q quits.)
- The workspace window is created at launch as today but is shown only after the gate resolves signed-in. `AppDelegate.applicationShouldHandleReopen`, the menu bar, and `WorkspaceWindowController.showWindow` paths raise the login window instead while `AuthGate.needsSignIn` is true.

### Account switch (the one new mechanism)

`WorkspaceWindowController.switchAccount(to email: String, completion:)`:

1. Compute `<id>`; write `root/current-account`.
2. If the pointer already held that id before this call (read at launch, remembered after every write) and the socket is up, the running daemon is already serving that account: skip to 5.
3. Otherwise the daemon must restart. If the workspace knows of ≥1 running session (`menuBarSummary().sessionCount > 0`, i.e. the legacy daemon on first upgrade), present the house modal (`presentWindowAsk`, `.critical`): "Move your workspace to your account? This restarts the daemon and ends N running sessions." — **Not now** / **Restart now**. *Not now*: remove the pointer again, keep working against the current daemon, complete as signed in; asked again next launch. A signed-out daemon has no sessions, so the ordinary post-logout sign-in never asks.
4. Terminate the daemon: `SessionConnection.peerProcessID()` (`getsockopt(LOCAL_PEERPID)` on the connected AF_UNIX descriptor) → `kill(pid, SIGTERM)` (the daemon's SIGTERM handler shuts every PTY down) → wait until the socket is unreachable (poll, ≤5 s). launchd `KeepAlive` brings a fresh one up; in the app-owned fallback `DaemonPersistenceController.start()` respawns it. The existing `SessionConnection` reconnect attaches to it.
5. `resetForAccountSwitch()`: drop local panes without persisting, reset every `restore…IfNeeded` once-flag, `didConnect = false`, `onboardingDispatched = false`. The next `.connected` restores that account's layout; terminal panes whose sessions are gone go through the existing `handleReattachFailure → ensureSession` path and come back as new terminals resuming their conversations. FirstRun and the persona step skip themselves when the account already answered.

### Sign-in flow

`AuthGateReducer`: `.signedIn` now moves `.login → .switching` (new phase; the card shows "Opening your workspace…"). The window controller runs `switchAccount`, then reads `auth_persona` from the (now account-scoped) daemon and sends `.accountReady(persona:)`: persona present → `.resolved` with it (no question); absent → `.personalize` as today. `markSignedIn` (the `UserDefaults` mirror) is written at `.signedIn` exactly as now.

At launch with the mirror true: pointer already on disk from the last sign-in, daemon already on that directory → `presentLaunchGate` proceeds straight in, no restart. Mirror true but no pointer (first launch of this build): run `switchAccount` with the email from the account rows; this is the case the modal exists for.

### Logout

`logOutOfAccount`:

1. If `sessionCount > 0`: house modal "Log out and end N running sessions?" — **Cancel** / **Log out**.
2. Revoke the server session (unchanged).
3. `AuthGateCoordinator.reset`: clears the mirror, `auth_gate_resolved`, `auth_signed_in` and the account identity rows (email/name/GitHub/picture). **`auth_persona` is no longer cleared** — it belongs to the account and comes back with it.
4. Terminate the daemon (step 4 above), then delete `root/current-account`.
5. `resetForAccountSwitch()`; order the workspace window and any sheets out; tear down the menu bar item.
6. Present the login gate `over: nil`, exactly like launch. Its resolution runs the sign-in flow above and shows the workspace window again.

### Menu bar

`AppDelegate` creates `MenuBarController` when the gate resolves signed-in and releases it (status item removed) on logout — via a `WorkspaceWindowController.onSignedInStateChanged: ((Bool) -> Void)?` hook. `MenuBarMenu.build` takes `accountLabel: String` and puts a disabled first item **"Logged in as {name}"** (`auth_account_name`, falling back to the email) above the existing summary.

## Files

- `crates/brain-core/src/store.rs`: `default_data_dir()` pointer resolution; `account_dir_id(email)`; `adopt_legacy_data`.
- `crates/omniagent-pty-daemon/src/server.rs`: call `adopt_legacy_data` before `bind`.
- `macos/OmniAgent/DaemonPersistence.swift`: `DaemonPaths` mirrors the pointer resolution (`accountID(for:)`, `currentAccountFileURL`, `dataDir(forAccount:)`).
- `macos/OmniAgent/SessionConnection.swift`: `peerProcessID()`.
- `macos/OmniAgent/DaemonPersistenceController.swift`: `terminateDaemon(completion:)` (kill + wait + respawn if app-owned), injectable for tests.
- `macos/OmniAgent/AuthGateState.swift`, `AuthGateView.swift`: remove skip path; `.switching` phase; `.accountReady`; window controller passes persona.
- `macos/OmniAgent/WorkspaceWindowController.swift`: `switchAccount`, `resetForAccountSwitch`, logout teardown, signed-out guards, `onSignedInStateChanged`.
- `macos/OmniAgent/AppDelegate.swift`, `MenuBarController.swift`: menu bar lifecycle + "Logged in as".
- `macos/OmniAgent/CommandPalette.swift`: no new destinations; the sign-in/out rows already exist (Spotlight rule satisfied).
- Tests: `brain-core` unit tests; `AuthGateStateTests`, `AuthGateCoordinatorTests`, `DaemonPersistenceTests`, `WorkspaceWindowControllerTests`, `MenuBarTests`.

## Testing

- Rust: `default_data_dir` with/without pointer, with env override, empty/whitespace pointer; `adopt_legacy_data` moves exactly the three artefacts once and never again; daemon boots into the account dir.
- Swift, TDD per step: reducer has no skip transition and the `.switching`/`.accountReady` transitions; `reset` keeps `auth_persona`; `switchAccount` writes the pointer, calls the injected terminator only when the pointer changed, asks first when sessions exist and honours *Not now*; logout orders the window out, terminates, clears the pointer, presents the gate; menu bar item exists only while signed in and its first item reads "Logged in as …"; reopen while signed out raises the gate, not the workspace.
- Whole suite (`caffeinate -disu ./macos/build.sh test`) and `cargo test --workspace` before each commit; known pre-existing failures per memory.
- End to end on the **Preview** channel build (own socket + data dir) — never against the developer's production daemon. Final `scripts/rebuild-app.sh --keep-daemon`; the running production daemon is left alone; the in-app modal will offer the migration when Bruno chooses.

## Risks

- Moving `brain.db` while a *stale* process still has it open: excluded by doing the move only in the daemon, only at startup, only before it opens the store — and by the app only ever terminating via SIGTERM and waiting for the socket to drop.
- A launchd restart racing the pointer write: the pointer is written before SIGTERM, so the restarted daemon always sees the new value.
- `brain` CLI / MCP invoked while signed out see `root` (empty after migration). Acceptable; they are not user-facing in the native app today.

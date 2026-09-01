
# Phase 1 — Sharing is one switch

Ships on its own: sharing stops being per-workspace and becomes one machine-wide toggle in Settings and the menu bar, with the icon showing its state. Remote viewing keeps working exactly as it does today, because the projection survives (it simply stops filtering).

### Task 1: `remote_sharing` replaces "≥1 enabled workspace" in the daemon

**Model:** sonnet
**Spec:** §2

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/server.rs:175-184` (`remote_control_active`)
- Test: `crates/omniagent-pty-daemon/tests/remote_sharing.rs` (create)

**Interfaces:**
- Consumes: `brain_core::Store::get_setting`
- Produces: `pub const REMOTE_SHARING_KEY: &str = "remote_sharing";` and `pub fn remote_control_active(store: &Store) -> bool` with new semantics — Phase 2 Task 11 extends this same function with the local-connection condition.

- [ ] **Step 1: Write the failing test**

```rust
// crates/omniagent-pty-daemon/tests/remote_sharing.rs
use omniagent_pty_daemon::server::{remote_control_active, REMOTE_SHARING_KEY};

mod support; // reuse the Store fixture helper the other integration tests use

#[test]
fn sharing_is_a_single_flag_not_a_workspace_count() {
    let store = support::temp_store();

    // Absent row: off.
    assert!(!remote_control_active(&store));

    // Explicitly off.
    store.set_setting(REMOTE_SHARING_KEY, r#"{"enabled":false}"#).unwrap();
    assert!(!remote_control_active(&store));

    // On — with no workspaces mentioned anywhere, which is the whole point.
    store.set_setting(REMOTE_SHARING_KEY, r#"{"enabled":true}"#).unwrap();
    assert!(remote_control_active(&store));

    // Garbage fails closed rather than inheriting the previous answer.
    store.set_setting(REMOTE_SHARING_KEY, "not json").unwrap();
    assert!(!remote_control_active(&store));
}
```

If `tests/support` does not exist, inline a `temp_store()` helper in this file using `tempfile::TempDir` + `Store::open`, copying the pattern from `tests/remote_authz.rs`.

- [ ] **Step 2: Run it and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_sharing`
Expected: FAIL — `REMOTE_SHARING_KEY` not found.

- [ ] **Step 3: Implement**

```rust
/// The settings row holding the machine-wide sharing switch (spec §2):
/// `{"enabled": true|false}`. It replaces the phase-1/2 pair of
/// `remote_control` (the projection) and `remote_control_workspaces` (the
/// intent) — sharing is no longer per-workspace, so there is no list.
pub const REMOTE_SHARING_KEY: &str = "remote_sharing";

/// Whether this machine is sharing its environment — the daemon's half of
/// "the tunnel should be up". Phase 3 replaces the old "the projection lists
/// ≥ 1 workspace" test with one flag; a malformed or absent row is off,
/// because a sharing switch that fails open is not a switch.
pub fn remote_control_active(store: &Store) -> bool {
    store
        .get_setting(REMOTE_SHARING_KEY)
        .ok()
        .flatten()
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
        .and_then(|value| value["enabled"].as_bool())
        .unwrap_or(false)
}
```

- [ ] **Step 4: Run the daemon suite**

Run: `cargo test -p omniagent-pty-daemon`
Expected: PASS. Existing tests that set `remote_control` to turn sharing *on* will now fail — update them to set `remote_sharing` instead. Do not weaken the new function to keep them passing.

- [ ] **Step 5: Commit**

```bash
git add crates/omniagent-pty-daemon/src/server.rs crates/omniagent-pty-daemon/tests/
git commit -m "feat(daemon): sharing is one flag, not a workspace count

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 2: The app writes `remote_sharing`; per-workspace sharing UI is deleted

**Model:** sonnet
**Spec:** §1, §2

**Files:**
- Modify: `macos/OmniAgent/SettingsKeys.swift` (add `remoteSharing`, delete `remoteControlWorkspaces`)
- Modify: `macos/OmniAgent/RemoteControlProjection.swift:109` (`build` — drop the enabled-workspace filter)
- Modify: `macos/OmniAgent/WorkspaceContextMenu.swift` (delete the **Enable Remote Control** item)
- Modify: `macos/OmniAgent/WorkspacesTree.swift` (delete the `globe` trailing glyph on workspace rows)
- Create: `macos/OmniAgent/RemoteSharingModel.swift`
- Test: `macos/OmniAgentTests/RemoteSharingModelTests.swift` (create), and update `RemoteControlProjectionTests`

**Interfaces:**
- Produces:
```swift
@MainActor final class RemoteSharingModel {
    static let shared: RemoteSharingModel
    private(set) var isSharing: Bool
    private(set) var blockedViewerIDs: [String]
    func setSharing(_ on: Bool)                 // writes remote_sharing, clears nothing else
    func unblock(_ viewerID: String)            // rewrites remote_control_blocked without that id
    var onChange: (() -> Void)?                 // menu bar + Settings redraw off this
}
```
Task 15 adds `liveConnection: RemoteConnectionInfo?` to this same type; Task 25 adds `activeRemoteSession: RemoteSessionInfo?`.

- [ ] **Step 1: Write the failing test**

```swift
// macos/OmniAgentTests/RemoteSharingModelTests.swift
@MainActor
final class RemoteSharingModelTests: XCTestCase {
    func testSetSharingWritesTheFlagRow() async throws {
        let store = FakeSettingsStore()          // the existing test double used by SettingsViewModelTests
        let model = RemoteSharingModel(store: store)

        model.setSharing(true)
        XCTAssertEqual(store.value(forKey: "remote_sharing"), #"{"enabled":true}"#)

        model.setSharing(false)
        XCTAssertEqual(store.value(forKey: "remote_sharing"), #"{"enabled":false}"#)
    }

    func testUnblockRemovesOnlyThatViewer() async throws {
        let store = FakeSettingsStore()
        store.set(#"["mac-a","mac-b"]"#, forKey: "remote_control_blocked")
        let model = RemoteSharingModel(store: store)

        model.unblock("mac-a")
        XCTAssertEqual(store.value(forKey: "remote_control_blocked"), #"["mac-b"]"#)
    }

    // The switch no longer forgives blocked machines — that was phase 2's rule.
    func testTurningSharingOnDoesNotClearTheBlockedList() async throws {
        let store = FakeSettingsStore()
        store.set(#"["mac-a"]"#, forKey: "remote_control_blocked")
        let model = RemoteSharingModel(store: store)

        model.setSharing(true)
        XCTAssertEqual(store.value(forKey: "remote_control_blocked"), #"["mac-a"]"#)
    }
}
```

If `FakeSettingsStore` does not exist under that name, find the settings double `SettingsViewModelTests` already uses and use that; do not add a second one.

- [ ] **Step 2: Run it and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test`
Expected: FAIL — `RemoteSharingModel` not found.

- [ ] **Step 3: Implement `RemoteSharingModel` and add the key**

```swift
// SettingsKeys.swift
/// The machine-wide sharing switch (2026-09-01 spec §2): `{"enabled":bool}`.
/// Replaces `remoteControlWorkspaces`, which is deleted with this change, and
/// eventually `remoteControl`, which survives until Phase 5 only because the
/// viewer's sidebar still reads it.
static let remoteSharing = "remote_sharing"
```

`RemoteSharingModel` reads and writes exactly those two rows through the existing settings client, publishes `onChange`, and does nothing else. Note in its doc comment that **turning sharing on no longer clears `remote_control_blocked`** — spec §2 and §7 — since that is a behaviour change a reader would otherwise assume was a bug.

- [ ] **Step 4: Delete the per-workspace surfaces**

- `WorkspaceContextMenu`: remove the **Enable Remote Control** item and its handler.
- `WorkspacesTree`: remove the `globe` trailing glyph and the enabled-workspace lookup that fed it.
- `SettingsKeys.remoteControlWorkspaces`: delete the constant and every reference.
- `RemoteControlProjection.build`: delete the `enabledWorkspaceIDs` parameter and the filter; it now projects **every** workspace. Keep everything else — the v2 tree shape is unchanged, and the viewer still reads it until Phase 5.
- Update `RemoteControlProjectionTests` for the dropped parameter: the case that asserted a disabled workspace is excluded becomes a case asserting every workspace is included.

- [ ] **Step 5: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`
Expected: PASS.

```bash
git add macos/
git commit -m "feat(macos): one sharing switch; per-workspace remote control deleted

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 3: Settings › Remote

**Model:** sonnet
**Spec:** §2, §10

**Files:**
- Create: `macos/OmniAgent/SettingsRemoteView.swift`
- Modify: `macos/OmniAgent/SettingsView.swift` (register the section)
- Modify: `macos/OmniAgent/CommandPalette.swift:392` (`CommandPaletteModel.build`)
- Test: `macos/OmniAgentTests/CommandPaletteTests.swift`

**Interfaces:**
- Consumes: `RemoteSharingModel.shared` (Task 2)
- Produces: a `SettingsSection` case `remote` that Task 16 (blocked list) and Task 20 (activity history) extend rather than replace.

- [ ] **Step 1: Write the failing palette test**

```swift
func testRemoteSettingsRowsExist() {
    let rows = CommandPaletteModel.build(/* the existing fixture arguments */)
    let titles = rows.map(\.title)
    XCTAssertTrue(titles.contains("Settings › Remote"))
    XCTAssertTrue(titles.contains("Share this environment"))
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/CommandPaletteTests`
Expected: FAIL — rows missing.

- [ ] **Step 3: Build the section**

`SettingsRemoteView` — SwiftUI, matching the existing Settings sections' visual language exactly (do not invent a new one). Contents in this task:
- **Share this environment** — a toggle bound to `RemoteSharingModel.shared.isSharing`, with one line of explanatory copy: "Anyone signed in to your account on another Mac can use this computer as if they were sitting at it. You will see who is connected and everything they do."
- **This machine** — the device name and device id from the existing `RelayClient` device registration, read-only.

Blocked list and Activity are added by later tasks; do not stub them — leave them out entirely rather than shipping empty sections.

- [ ] **Step 4: Add the palette rows**

Build them off the `SettingsSection` enum's `allCases` so later items appear without anyone remembering, per the standing rule. Symbol `antenna.radiowaves.left.and.right`, subtitle "Settings", keywords `["remote","share","sharing","screen","access","connect"]`.

- [ ] **Step 5: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): Settings > Remote, with the sharing switch

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 4: The menu bar icon says what is happening

**Model:** sonnet
**Spec:** §2

**Files:**
- Modify: `macos/OmniAgent/MenuBarController.swift` (init, `menuNeedsUpdate`, `MenuBarMenu.build`)
- Test: `macos/OmniAgentTests/MenuBarMenuTests.swift`

**Interfaces:**
- Produces: `enum MenuBarShareState { case off, sharing, connected }` and `static func shareIcon(_ state: MenuBarShareState) -> NSImage` — Task 16 drives `.connected` from the live lease.

- [ ] **Step 1: Write the failing test**

```swift
func testShareIconIsTemplateOnlyWhenSharingIsOff() {
    XCTAssertTrue(MenuBarMenu.shareIcon(.off).isTemplate)
    XCTAssertFalse(MenuBarMenu.shareIcon(.sharing).isTemplate)
    XCTAssertFalse(MenuBarMenu.shareIcon(.connected).isTemplate)
}

func testSharingToggleItemReflectsState() {
    let menu = NSMenu()
    MenuBarMenu.build(into: menu, summary: .init(), accountLabel: "Bruno",
                      shareState: .sharing, /* existing closures */)
    let item = menu.items.first { $0.title == "Share this environment" }
    XCTAssertEqual(item?.state, .on)
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/MenuBarMenuTests`
Expected: FAIL — `shareIcon` not found.

- [ ] **Step 3: Implement the icon states**

```swift
/// The status icon's three states (spec §2). Green means the machine is
/// reachable; blue means someone is on it right now. Tinting requires
/// `isTemplate = false`, so the icon stops adapting to the menu bar's
/// appearance — deliberate: the whole point is that it stops looking ordinary.
enum MenuBarShareState { case off, sharing, connected }

static func shareIcon(_ state: MenuBarShareState) -> NSImage {
    let base = NSImage(named: "OmniAgentMark") ?? NSImage()
    let size = NSSize(width: 18, height: 18)
    guard let tint: NSColor = {
        switch state {
        case .off: return nil
        case .sharing: return .systemGreen
        case .connected: return .systemBlue
        }
    }() else {
        let image = base.copy() as! NSImage
        image.size = size
        image.isTemplate = true
        return image
    }
    let image = NSImage(size: size, flipped: false) { rect in
        base.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    image.isTemplate = false
    return image
}
```

- [ ] **Step 4: Add the toggle item**

In `MenuBarMenu.build`, above **Settings…**: a checkmarked **Share this environment** item calling a new `toggleSharing` closure, with `state` = `.on` when sharing. `MenuBarController.menuNeedsUpdate` passes `RemoteSharingModel.shared.isSharing`, and subscribes to `onChange` to refresh `statusItem.button?.image`.

- [ ] **Step 5: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): menu bar shares the environment, and says so in colour

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

# Phase 2 — The lease and the widened allowlist

Ships on its own: a single remote client may drive the whole daemon, but only while a local app is attached, only one at a time, and never near the keys that would let it grant itself more.

**Do not run `rebuild-app.sh --keep-daemon` after Task 8.** The protocol version bump makes a surviving old daemon produce a reconnect loop with a dead keyboard.

### Task 5: Protected settings keys

**Model:** opus
**Spec:** §3

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (near `authorize_remote`)
- Test: `crates/omniagent-pty-daemon/tests/remote_authz.rs`

**Interfaces:**
- Produces: `pub fn protected_setting_key(key: &str) -> bool` — Task 6 calls it from both the `GetSetting` and `SetSetting` arms.

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn protected_keys_are_the_ones_that_would_grant_more_access() {
    for key in [
        "remote_sharing",
        "relay_device_token",
        "remote_control_blocked",
        "auth_signed_in",
        "auth_account_email",
        "auth_anything_added_later",
    ] {
        assert!(protected_setting_key(key), "{key} must be protected");
    }
    for key in ["layout", "editor_panes_native", "roots", "persona"] {
        assert!(!protected_setting_key(key), "{key} must stay reachable");
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_authz protected_keys`
Expected: FAIL — not found.

- [ ] **Step 3: Implement**

```rust
/// Settings rows a remote client may neither read nor write (spec §3).
///
/// This is the whole security argument in five keys: a remote client must not
/// be able to grant itself access (`remote_sharing`, `relay_device_token`),
/// unblock itself (`remote_control_blocked`), or read the host's credentials
/// (`auth_*`). The `auth_` case is a **prefix** on purpose — a row added to
/// that family next month is protected the day it is added, without anyone
/// remembering this function exists.
pub fn protected_setting_key(key: &str) -> bool {
    matches!(
        key,
        REMOTE_SHARING_KEY | RELAY_DEVICE_TOKEN_KEY | BLOCKED_VIEWERS_KEY
    ) || key.starts_with("auth_")
}
```

- [ ] **Step 4: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): the settings keys a remote client may never touch

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 6: Widen the allowlist to the whole environment

**Model:** opus
**Spec:** §3

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/server.rs:201` (`authorize_remote`)
- Modify: `crates/omniagent-pty-daemon/tests/remote_authz.rs` (rewrite)

**Interfaces:**
- Consumes: `protected_setting_key` (Task 5)
- Produces: `pub fn authorize_remote(frame: &Frame) -> Result<(), String>` — **the `allowed: &HashSet<String>` parameter is deleted**. Session-id confinement went with the projection; a lease holder may reach any session. Every call site loses its `remote_session_ids(store)` argument.

- [ ] **Step 1: Rewrite the test first**

```rust
#[test]
fn a_lease_holder_may_drive_the_whole_environment() {
    for kind in [
        MessageKind::Hello, MessageKind::ListSessions, MessageKind::Attach,
        MessageKind::Detach, MessageKind::Input, MessageKind::Resize,
        MessageKind::Interrupt, MessageKind::CreateSession, MessageKind::Kill,
        MessageKind::ListDirectory, MessageKind::RootsList,
        MessageKind::RootsAddProject, MessageKind::BrainSearch,
    ] {
        assert!(authorize_remote(&frame(kind, b"{}")).is_ok(), "{kind:?} must be allowed");
    }
}

#[test]
fn the_local_only_kinds_stay_local() {
    for kind in [
        MessageKind::ListViewers,
        MessageKind::DisconnectViewer,
        MessageKind::PublishHostState,
    ] {
        assert!(authorize_remote(&frame(kind, b"{}")).is_err(), "{kind:?} must be denied");
    }
}

#[test]
fn protected_rows_are_refused_on_both_get_and_set() {
    for key in ["remote_sharing", "relay_device_token", "remote_control_blocked", "auth_account_email"] {
        let get = frame(MessageKind::GetSetting, format!(r#"{{"key":"{key}"}}"#).as_bytes());
        let set = frame(MessageKind::SetSetting, format!(r#"{{"key":"{key}","value":"x"}}"#).as_bytes());
        assert!(authorize_remote(&get).is_err(), "get {key}");
        assert!(authorize_remote(&set).is_err(), "set {key}");
    }
    assert!(authorize_remote(&frame(MessageKind::SetSetting, br#"{"key":"layout","value":"{}"}"#)).is_ok());
}

// The standing rule, pinned: adding a kind to the dispatch must not make it
// remotely reachable. This test fails when someone adds a MessageKind and
// forgets to decide.
#[test]
fn every_message_kind_is_deliberately_classified() {
    for kind in MessageKind::ALL {
        let _ = authorize_remote(&frame(kind, b"{}")); // must not panic
    }
}
```

Delete the old cases that asserted session-id confinement (`Attach s2` refused, `ListSessions` filtered) and the ones asserting `Kill`/`CreateSession`/`Resize` are denied — those behaviours are gone on purpose. Keep `authorize_remote_checks_the_raw_input_session_id` only if it still expresses something true; if not, delete it with a note in the commit message.

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_authz`
Expected: FAIL — signature mismatch and denied kinds.

- [ ] **Step 3: Implement**

```rust
/// The trust boundary for relayed clients (spec §3).
///
/// Still an **explicit allowlist**, and it must stay one: the standing repo
/// rule is that nothing becomes remote-reachable merely by being added to the
/// dispatch. What changed in phase 3 is its length and the loss of session-id
/// confinement — the lease holder is driving the whole machine, so confining
/// it to a projection would be confining it to nothing.
pub fn authorize_remote(frame: &Frame) -> Result<(), String> {
    use MessageKind::*;
    match frame.header.message_kind {
        Hello | ListSessions | Attach | Detach | Input | Resize | Interrupt
        | CreateSession | Kill | ListDirectory
        | RootsStartIngest | RootsIngestionStatus | RootsList | RootsBiggestProject
        | RootsAddProject | RootsRenameProject | RootsPausedProjects | RootsSetPaused
        | RootsStaleness | RootsReingestProject | RootsRebuild
        | BrainListProjects | BrainGetContext | BrainSearch => Ok(()),

        GetSetting | SetSetting => {
            let key = parse_json::<SettingKey>(&frame.payload)
                .map_err(|error| error.to_string())?
                .key;
            (!protected_setting_key(&key))
                .then_some(())
                .ok_or_else(|| format!("setting {key} is not reachable remotely"))
        }

        other => Err(format!("{other:?} is not allowed for remote clients")),
    }
}
```

`SettingKey` must deserialize a `SetSetting` payload too — if `SetSetting`'s payload type differs, give `SettingKey` `#[serde(default)]` fields so one struct reads both, rather than branching.

- [ ] **Step 4: Fix the call sites**

Remove the `remote_session_ids(store)` argument everywhere `authorize_remote` is called, and delete the now-unused `ListSessions` filtering in the dispatch arm — a lease holder sees every session.

**Do not delete `remote_session_ids` yet**; Task 29 removes it with the projection.

- [ ] **Step 5: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): a lease holder drives the environment, not a projection

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 7: One remote connection at a time — the lease

**Model:** opus
**Spec:** §3

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/connections.rs` (`ConnectionRegistry`)
- Modify: `crates/omniagent-pty-daemon/src/server.rs:486` (`serve_client`, the `Hello` arm)
- Test: `crates/omniagent-pty-daemon/tests/remote_lease.rs` (create)

**Interfaces:**
- Produces on `ConnectionRegistry`:
```rust
/// `Ok(())` if this connection now holds the lease; `Err(machine_name)` if
/// another remote connection already does.
pub fn take_lease(&self, id: ConnectionId, machine: &str) -> Result<(), String>;
pub fn release_lease(&self, id: ConnectionId);
pub fn lease_holder(&self) -> Option<ViewerIdentity>;
```
Task 15 reads `lease_holder()` for the panel; Task 21 reads it to decide where to forward `HostState`.

- [ ] **Step 1: Write the failing test**

```rust
#[tokio::test]
async fn a_second_viewer_is_refused_while_the_first_holds_the_lease() {
    let harness = support::daemon_with_local_client().await;

    let first = harness.connect_remote("MacBook Pro").await;
    assert!(matches!(first.hello().await, HelloResult::Ack(_)));

    let second = harness.connect_remote("Mac mini").await;
    match second.hello().await {
        HelloResult::Error(message) => assert!(message.contains("in use by MacBook Pro"), "{message}"),
        other => panic!("expected refusal, got {other:?}"),
    }
}

#[tokio::test]
async fn the_lease_is_released_when_the_connection_ends() {
    let harness = support::daemon_with_local_client().await;
    {
        let first = harness.connect_remote("MacBook Pro").await;
        assert!(matches!(first.hello().await, HelloResult::Ack(_)));
    } // dropped

    harness.wait_for_no_lease().await;
    let second = harness.connect_remote("Mac mini").await;
    assert!(matches!(second.hello().await, HelloResult::Ack(_)));
}
```

Build `support::daemon_with_local_client()` on `tokio::io::duplex`, the same way `tests/remote_authz.rs` drives `serve_client`. It must attach one `ClientTrust::Local` connection first, because Task 10 makes that a precondition.

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_lease`
Expected: FAIL — `take_lease` not found.

- [ ] **Step 3: Implement**

Add `lease: Mutex<Option<(ConnectionId, ViewerIdentity)>>` to `ConnectionRegistry`. `take_lease` sets it if empty, otherwise returns the current holder's machine name. `release_lease` clears it only if the id matches — a late release from a dead connection must not evict a live one.

In `serve_client`'s `Hello` arm, for `ClientTrust::Remote` only: call `take_lease`; on `Err(machine)` answer `Error("in use by {machine}")` and return. Release in the same place the connection is unregistered, so every exit path covers it.

- [ ] **Step 4: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): one remote connection at a time

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 8: `PROTOCOL_VERSION` 2, and a skewed peer is told, not looped

**Model:** sonnet
**Spec:** §3

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/protocol.rs:6`
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (`Hello` arm)
- Modify: `macos/OmniAgent/SessionConnection.swift` (surface the refusal instead of retrying)
- Test: `crates/omniagent-pty-daemon/tests/remote_lease.rs`

- [ ] **Step 1: Write the failing test**

```rust
#[tokio::test]
async fn a_remote_peer_on_the_old_protocol_is_told_to_update() {
    let harness = support::daemon_with_local_client().await;
    let old = harness.connect_remote_with_version("MacBook Pro", 1).await;
    match old.hello().await {
        HelloResult::Error(message) => assert!(message.contains("update OmniAgent on MacBook Pro"), "{message}"),
        other => panic!("expected refusal, got {other:?}"),
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_lease old_protocol`
Expected: FAIL.

- [ ] **Step 3: Implement**

`pub const PROTOCOL_VERSION: u8 = 2;`. In the `Hello` arm, when `trust == Remote` and the peer's version is not 2, answer `Error("update OmniAgent on {machine}")` and close — **before** taking the lease, so a skewed peer cannot hold it.

App side: `SessionConnection` treats an `Error` reply to `Hello` as terminal for that dial (park, do not back off into a loop) and surfaces the message. Task 24's ceremony shows it at step 3; until then a log line is enough.

- [ ] **Step 4: Run everything and commit**

Run: `cargo test -p omniagent-pty-daemon && caffeinate -disu ./macos/build.sh test`

```bash
git add crates/ macos/
git commit -m "feat(daemon): protocol 2; a skewed peer is told to update, not looped

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 9: `ListDirectory`

**Model:** sonnet
**Spec:** §4

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/protocol.rs` (kind `0x1d`, payload types)
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (dispatch arm)
- Test: `crates/omniagent-pty-daemon/tests/list_directory.rs` (create)

**Interfaces:**
- Produces: request `{"path":"/Users/bonando"}`, reply via the ordinary `Response` with `{"entries":[{"name":"Documents","is_dir":true}, …]}`, sorted directories-first then case-insensitively by name. Task 28's folder browser consumes exactly this.

- [ ] **Step 1: Write the failing test**

```rust
#[tokio::test]
async fn list_directory_returns_names_and_kinds_only() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("sub")).unwrap();
    std::fs::write(dir.path().join("a.txt"), b"secret contents").unwrap();

    let reply = support::request(MessageKind::ListDirectory,
        &json!({"path": dir.path()})).await;

    let entries = reply["entries"].as_array().unwrap();
    assert_eq!(entries[0]["name"], "sub");
    assert_eq!(entries[0]["is_dir"], true);
    assert_eq!(entries[1]["name"], "a.txt");
    assert_eq!(entries[1]["is_dir"], false);
    // No contents, no size, no mode: this RPC exists so a remote can pick a
    // folder, and stops well short of remote file read.
    assert!(reply.to_string().find("secret contents").is_none());
}

#[tokio::test]
async fn an_unreadable_path_is_an_error_not_a_panic() {
    let reply = support::request_raw(MessageKind::ListDirectory,
        &json!({"path": "/definitely/not/here"})).await;
    assert!(reply.is_error());
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test list_directory`
Expected: FAIL — kind not found.

- [ ] **Step 3: Implement**

Add the kind, a `ListDirectoryPayload { path: String }`, and a dispatch arm using `std::fs::read_dir`. Skip entries whose name starts with `.` unless the request sets `"show_hidden": true`. Return `Error` for anything `read_dir` rejects. No recursion, no symlink following beyond what `is_dir()` already does.

- [ ] **Step 4: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): ListDirectory, so a remote can pick a host folder

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 10: No remote connection without a local app — and therefore no chaining

**Model:** opus
**Spec:** §2, §3

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (`remote_control_active`, the `Hello` arm)
- Modify: `crates/omniagent-pty-daemon/src/relay.rs` (the watch that decides whether to hold the control channel)
- Test: `crates/omniagent-pty-daemon/tests/remote_chaining.rs` (create)

**Interfaces:**
- Produces: `pub fn sharing_should_be_live(store: &Store, connections: &ConnectionRegistry) -> bool` — the three-way test. `relay.rs` polls it through its existing `Notify`, plus a 5 s timer so the grace can expire without another event.

- [ ] **Step 1: Write the failing test**

```rust
#[tokio::test]
async fn no_remote_connection_is_accepted_without_a_local_app() {
    let harness = support::daemon_without_local_client().await;   // sharing on, token present
    let viewer = harness.connect_remote("MacBook Pro").await;
    match viewer.hello().await {
        HelloResult::Error(message) => assert!(message.contains("not available"), "{message}"),
        other => panic!("expected refusal, got {other:?}"),
    }
}

// The grace: an app reconnect (or a rebuild) must not flap a live session.
#[tokio::test]
async fn a_local_reconnect_inside_the_grace_does_not_drop_the_remote() {
    let harness = support::daemon_with_local_client().await;
    let viewer = harness.connect_remote("MacBook Pro").await;
    assert!(matches!(viewer.hello().await, HelloResult::Ack(_)));

    harness.drop_local_client();
    harness.advance(Duration::from_secs(2)).await;
    assert!(harness.sharing_is_live());

    harness.reconnect_local_client().await;
    harness.advance(Duration::from_secs(10)).await;
    assert!(harness.sharing_is_live());
    assert!(viewer.is_open());
}

#[tokio::test]
async fn sharing_goes_down_once_the_grace_expires() {
    let harness = support::daemon_with_local_client().await;
    harness.drop_local_client();
    harness.advance(Duration::from_secs(6)).await;
    assert!(!harness.sharing_is_live());
}
```

Use `tokio::time::pause()`/`advance` rather than real sleeps.

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_chaining`
Expected: FAIL.

- [ ] **Step 3: Implement**

```rust
/// How long sharing survives the last local connection going away (spec §2).
/// An app reconnect — or a `rebuild-app.sh` restart — must not flap a live
/// remote session, and five seconds is far longer than either takes.
const LOCAL_ABSENCE_GRACE: Duration = Duration::from_secs(5);

/// Sharing is live only when all three hold (spec §2): the switch is on, a
/// device token exists, and a local app is attached. That third condition is
/// the "icon in the menu bar" rule — and it is also what makes chaining
/// impossible for free: a Mac that is driving another has swapped its single
/// connection away from its own daemon, so it fails this test and refuses
/// everyone inbound.
pub fn sharing_should_be_live(
    store: &Store,
    connections: &ConnectionRegistry,
    last_local_seen: Option<Instant>,
    now: Instant,
) -> bool {
    if !remote_control_active(store) {
        return false;
    }
    if store.get_setting(RELAY_DEVICE_TOKEN_KEY).ok().flatten().is_none() {
        return false;
    }
    if connections.has_local() {
        return true;
    }
    last_local_seen.is_some_and(|seen| now.duration_since(seen) < LOCAL_ABSENCE_GRACE)
}
```

`relay.rs` closes the control channel when it goes false, which drops the remote immediately. The `Hello` arm refuses with "‹machine name› is not available" when it is false at connect time.

- [ ] **Step 4: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): sharing needs a local app, which is also why chaining cannot happen

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

# Phase 3 — Who is connecting, and the host's takeover panel

Ships on its own: the relay says who the viewer is, the daemon independently refuses anyone who is not the account it serves, and the host gets a glass panel it cannot dismiss showing the connection and offering Terminate and Block.

### Task 11: The relay asserts the viewer's identity (`OmniAgent-Core`)

**Model:** sonnet
**Spec:** §9

**Files:**
- Modify: `../OmniAgent-Core/omniagent/relay/main.py` (`WS /v1/viewer/{device_id}`)
- Test: `../OmniAgent-Core/tests/test_relay.py`

**Interfaces:**
- Produces the control-channel message consumed by Task 12:
```json
{"open":"<conn_id>",
 "viewer":{"user_sub":"…","account_email":"…","ip":"203.0.113.7","country":"DE",
           "client":"OmniAgent/1.7.22 macOS 27.0"}}
```

- [ ] **Step 1: Write the failing test**

```python
def test_open_message_carries_the_edge_asserted_identity(relay_app, device, viewer_token):
    with relay_app.websocket_connect("/v1/device", headers=device.auth) as control:
        control.receive_json()  # registration ack
        with relay_app.websocket_connect(
            f"/v1/viewer/{device.id}",
            headers={**viewer_token.auth,
                     "CF-Connecting-IP": "203.0.113.7",
                     "CF-IPCountry": "DE"},
        ):
            message = control.receive_json()
            assert message["viewer"]["ip"] == "203.0.113.7"
            assert message["viewer"]["country"] == "DE"
            assert message["viewer"]["account_email"] == device.owner_email
            assert message["viewer"]["user_sub"] == device.owner_sub


def test_absent_edge_headers_omit_the_fields_rather_than_inventing_them(relay_app, device, viewer_token):
    with relay_app.websocket_connect("/v1/device", headers=device.auth) as control:
        control.receive_json()
        with relay_app.websocket_connect(f"/v1/viewer/{device.id}", headers=viewer_token.auth):
            viewer = control.receive_json()["viewer"]
            assert "ip" not in viewer and "country" not in viewer
            assert viewer["account_email"] == device.owner_email
```

Keep the existing phase-1 isolation cases (another user's JWT → 403; `GET /v1/relay/devices` never returns a device it does not own) and extend them to assert the new payload does not leak across users.

- [ ] **Step 2: Run and watch it fail**

Run (in `../OmniAgent-Core`): `pytest tests/test_relay.py -k identity -v`
Expected: FAIL — no `viewer` key.

- [ ] **Step 3: Implement**

In the viewer connect handler, after the existing ownership check, look up the owner's email from the users table (the `sub` is already in hand) and build the `viewer` dict. `ip` from `CF-Connecting-IP`, `country` from `CF-IPCountry`, `client` from `User-Agent`. **Omit a field entirely when its header is absent** — a placeholder in a trust panel is worse than a gap.

Add a comment saying city is deliberately absent: `CF-IPCity` is Enterprise-only, and geolocating through a third-party API would hand them every viewer IP for one line of UI copy.

- [ ] **Step 4: Deploy to staging**

```bash
cd ../OmniAgent-Core
KUBECONFIG=~/.kube/k3s-lens.yaml ./deploy.sh staging
```

Docker proxy push timeouts happen — just rerun. Do **not** run the production secret patch here; it clobbers `JINA` with `CHANGE_ME`.

- [ ] **Step 5: Commit and push (in `../OmniAgent-Core`)**

```bash
git add omniagent/relay/main.py tests/test_relay.py
git commit -m "feat(relay): assert the viewer's identity to the host

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 12: The daemon carries the asserted identity onto the data connection

**Model:** opus
**Spec:** §9

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/relay.rs:243-272` (parse `viewer`, pass to `data_connection`)
- Modify: `crates/omniagent-pty-daemon/src/connections.rs` (`ViewerIdentity`)
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (`serve_client` takes the identity)
- Test: `crates/omniagent-pty-daemon/tests/relay_loopback.rs`

**Interfaces:**
- Produces:
```rust
pub struct ViewerIdentity {
    pub viewer_id: String,          // self-reported (phase 2)
    pub machine_name: String,       // self-reported
    pub user_sub: Option<String>,   // relay-asserted
    pub account_email: Option<String>, // relay-asserted
    pub ip: Option<String>,         // relay-asserted
    pub country: Option<String>,    // relay-asserted
    pub client: Option<String>,     // relay-asserted
}
```
`ClientTrust::Remote` gains a payload: `Remote(Box<AssertedIdentity>)`, where `AssertedIdentity` is the relay-asserted half. Task 13 checks it; Task 15 displays it.

**This changes a variant Tasks 7 and 10 already match on.** Update those match sites to `ClientTrust::Remote(_)` as part of this task — the compiler will find them all, but the tests are yours to keep passing.

- [ ] **Step 1: Write the failing test**

```rust
#[tokio::test]
async fn the_asserted_identity_reaches_the_connection() {
    let relay = support::fake_relay().await;
    relay.send_open("c1", json!({"user_sub":"u1","account_email":"a@b.c","ip":"203.0.113.7","country":"DE"})).await;

    let connection = relay.accept_data("c1").await;
    assert_eq!(connection.asserted().account_email.as_deref(), Some("a@b.c"));
    assert_eq!(connection.asserted().ip.as_deref(), Some("203.0.113.7"));
}

// A data connection the relay never described is refused: the account check in
// Task 13 has nothing to check, and a check that can be skipped is not a check.
#[tokio::test]
async fn a_data_connection_with_no_asserted_identity_is_refused() {
    let relay = support::fake_relay().await;
    relay.send_open("c1", json!(null)).await;
    assert!(relay.accept_data("c1").await.is_closed());
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test relay_loopback asserted`
Expected: FAIL.

- [ ] **Step 3: Implement**

At `relay.rs:243`, parse `viewer` alongside `open` and pass it into `data_connection(ctx, cred, conn_id, asserted)`, which hands it to `serve_client` inside `ClientTrust::Remote(...)`. A missing or null `viewer` object closes the data connection without dispatching.

Document at the struct why the split matters: `viewer_id`/`machine_name` are what the connecting app says about itself and are a label; `user_sub`/`account_email`/`ip`/`country` are what Cloudflare and the relay observed and are the only fields any decision may rest on.

- [ ] **Step 4: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): carry the relay-asserted identity onto the connection

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 13: Nobody ever sees another person's sessions

**Model:** opus
**Spec:** §9, §12 invariants 9-10

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (connection setup, before dispatch)
- Test: `crates/omniagent-pty-daemon/tests/remote_account_isolation.rs` (create)

**Interfaces:**
- Consumes: `brain_core::Store::account_dir_id` (`crates/brain-core/src/store.rs:357`), `AssertedIdentity` (Task 12)
- Produces: the refusal path. Nothing later depends on it beyond its existence.

- [ ] **Step 1: Write the failing test**

```rust
#[tokio::test]
async fn a_viewer_from_a_different_account_is_refused() {
    // The daemon is serving bruno@bonando.com's account directory.
    let harness = support::daemon_for_account("bruno@bonando.com").await;

    let stranger = harness.connect_remote_asserting("someone@else.com").await;
    assert!(stranger.is_closed_with_error());

    let owner = harness.connect_remote_asserting("bruno@bonando.com").await;
    assert!(matches!(owner.hello().await, HelloResult::Ack(_)));
}

#[tokio::test]
async fn the_check_is_case_and_whitespace_insensitive_like_the_account_dir() {
    let harness = support::daemon_for_account("bruno@bonando.com").await;
    let owner = harness.connect_remote_asserting("  Bruno@Bonando.COM ").await;
    assert!(matches!(owner.hello().await, HelloResult::Ack(_)));
}

// The check must not read anything the client controls.
#[tokio::test]
async fn a_hello_claiming_a_different_email_cannot_override_the_assertion() {
    let harness = support::daemon_for_account("bruno@bonando.com").await;
    let liar = harness
        .connect_remote_asserting("someone@else.com")
        .claiming_in_hello("bruno@bonando.com")
        .await;
    assert!(liar.is_closed_with_error());
}

#[tokio::test]
async fn a_missing_assertion_is_refused_rather_than_waved_through() {
    let harness = support::daemon_for_account("bruno@bonando.com").await;
    assert!(harness.connect_remote_asserting_nothing().await.is_closed_with_error());
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_account_isolation`
Expected: FAIL.

- [ ] **Step 3: Implement**

```rust
/// The second of two independent checks that nobody ever sees another
/// person's sessions (spec §9). The relay already refuses a viewer whose
/// `sub` does not own the device; this one does not trust that.
///
/// The daemon serves exactly one account: `current-account` names it and the
/// data dir is `<root>/accounts/<id>/`. So hash the **relay-asserted** email
/// with the same function that chose that directory and require equality. No
/// new identifier, no new row, no new hash — the check reuses the function
/// that decides whose files these are in the first place.
///
/// It reads the assertion, never the client's `Hello`: a check run on a value
/// the connecting client supplies checks nothing.
fn viewer_owns_this_account(asserted: &AssertedIdentity, data_dir: &Path) -> bool {
    let Some(email) = asserted.account_email.as_deref() else { return false };
    // The data dir is `<root>/accounts/<id>/` while signed in; its last
    // component *is* the account id. Signed out there is no `accounts/`
    // segment and no account to match, so this fails closed.
    let Some(serving) = data_dir.file_name().and_then(|name| name.to_str()) else { return false };
    data_dir.parent().is_some_and(|p| p.ends_with("accounts")) && Store::account_dir_id(email) == serving
}
```

Run it once, at connection setup, before any frame is dispatched. Failure closes the connection with `Error` and logs at `warn` with the asserted email and IP — this is the line someone reads after an incident.

A signed-out host has no account directory: fail closed there too.

- [ ] **Step 4: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): refuse any viewer that is not the account we serve

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 14: Terminate and Block become two different things

**Model:** sonnet
**Spec:** §7

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/protocol.rs` (`DisconnectViewer` payload)
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (its dispatch arm)
- Test: `crates/omniagent-pty-daemon/tests/remote_lease.rs`

**Interfaces:**
- Produces: `DisconnectViewer` payload `{"viewer_id":"…","block":true|false}`. `block: false` kicks only; `block: true` kicks and appends to `remote_control_blocked`, which is phase 2's behaviour.

- [ ] **Step 1: Write the failing test**

```rust
#[tokio::test]
async fn terminate_kicks_without_blocking() {
    let harness = support::daemon_with_local_client().await;
    let viewer = harness.connect_remote("MacBook Pro").await;
    viewer.hello().await;

    harness.local().disconnect_viewer("MacBook Pro", false).await;
    assert!(viewer.is_closed());
    assert!(harness.blocked_ids().is_empty());

    // It may come straight back.
    let again = harness.connect_remote("MacBook Pro").await;
    assert!(matches!(again.hello().await, HelloResult::Ack(_)));
}

#[tokio::test]
async fn block_kicks_and_keeps_it_out() {
    let harness = support::daemon_with_local_client().await;
    let viewer = harness.connect_remote("MacBook Pro").await;
    viewer.hello().await;

    harness.local().disconnect_viewer("MacBook Pro", true).await;
    assert_eq!(harness.blocked_ids(), vec!["MacBook Pro"]);

    let again = harness.connect_remote("MacBook Pro").await;
    assert!(matches!(again.hello().await, HelloResult::Error(_)));
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_lease disconnect`
Expected: FAIL — no `block` field.

- [ ] **Step 3: Implement**

Add `#[serde(default = "default_true")] block: bool` so an omitted field keeps phase 2's meaning, and branch on it around the existing `block_viewer` call. Cancel the connection either way.

- [ ] **Step 4: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): terminate and block are two different verbs

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 15: The takeover panel

**Model:** sonnet
**Spec:** §7

**Files:**
- Create: `macos/OmniAgent/RemoteTakeoverPanel.swift`
- Modify: `macos/OmniAgent/RemoteSharingModel.swift` (add `liveConnection`)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (present and dismiss it)
- Test: `macos/OmniAgentTests/RemoteTakeoverPanelTests.swift` (create)

**Interfaces:**
- Consumes: `RemoteViewers` (`0x8d`, phase 2) now carrying the asserted fields from Task 12.
- Produces:
```swift
struct RemoteConnectionInfo: Equatable {
    let machineName: String        // self-reported
    let accountEmail: String?      // asserted
    let ip: String?                // asserted
    let country: String?           // asserted
    let client: String?            // asserted
    let since: Date
}
extension RemoteSharingModel { var liveConnection: RemoteConnectionInfo? { get } }
```
Task 20 adds the activity table into this same panel.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
final class RemoteTakeoverPanelTests: XCTestCase {
    func testAssertedFieldsAreMarkedAndSelfReportedOnesAreNot() {
        let panel = RemoteTakeoverPanel(info: .fixture(ip: "203.0.113.7", country: "DE"), connection: SpySessionConnection())
        XCTAssertTrue(panel.row(for: .ip).isVerified)
        XCTAssertTrue(panel.row(for: .country).isVerified)
        XCTAssertFalse(panel.row(for: .machineName).isVerified)
        XCTAssertFalse(panel.row(for: .os).isVerified)
    }

    func testAbsentAssertedFieldsAreOmittedNotShownEmpty() {
        let panel = RemoteTakeoverPanel(info: .fixture(ip: nil, country: nil), connection: SpySessionConnection())
        XCTAssertNil(panel.row(for: .ip))
        XCTAssertNil(panel.row(for: .country))
    }

    func testThePanelHasNoDismissPath() {
        let panel = RemoteTakeoverPanel(info: .fixture(), connection: SpySessionConnection())
        XCTAssertFalse(panel.window.isMovable)
        XCTAssertFalse(panel.window.styleMask.contains(.closable))
        XCTAssertFalse(panel.window.styleMask.contains(.miniaturizable))
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/RemoteTakeoverPanelTests`
Expected: FAIL — type not found.

- [ ] **Step 3: Build the panel**

A borderless screen-covering window at `.modalPanel` level over the workspace window, which stays visible and dimmed behind it so the host can watch terminals update. Liquid glass via `PaneAskOverlayView` building blocks — **never `NSAlert`**.

- Header: state line (*Setting up connection…* → *Connected*) and the machine name.
- Identity grid: account, IP, country, OS, app version, connected since. Rows whose value is `nil` are omitted entirely. Asserted rows carry a small `checkmark.seal.fill` with the tooltip "Verified by the relay"; self-reported rows carry nothing.
- Space reserved below for the activity table (Phase 4). Leave it empty rather than stubbing a placeholder.

Present it from `WorkspaceWindowController` whenever `liveConnection` becomes non-nil; tear it down when it becomes nil. Verify by offscreen render (`macos/.build-*` PNG from a test) rather than by eye — screen capture cannot see this app's windows on this machine.

- [ ] **Step 4: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): the takeover panel — who is here, and no way to ignore it

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 16: Terminate, Block, and the blue icon

**Model:** sonnet
**Spec:** §2, §7, §10

**Files:**
- Modify: `macos/OmniAgent/RemoteTakeoverPanel.swift` (the two buttons)
- Modify: `macos/OmniAgent/MenuBarController.swift` (`.connected` state)
- Modify: `macos/OmniAgent/SettingsRemoteView.swift` (blocked list + Unblock)
- Modify: `macos/OmniAgent/CommandPalette.swift`
- Test: `macos/OmniAgentTests/RemoteTakeoverPanelTests.swift`, `CommandPaletteTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testTerminateSendsDisconnectWithoutBlocking() {
    let sent = SpySessionConnection()
    let panel = RemoteTakeoverPanel(info: .fixture(machineName: "MacBook Pro"), connection: sent)
    panel.terminate()
    XCTAssertEqual(sent.lastDisconnect, .init(viewerID: "MacBook Pro", block: false))
}

func testBlockSendsDisconnectWithBlocking() {
    let sent = SpySessionConnection()
    let panel = RemoteTakeoverPanel(info: .fixture(machineName: "MacBook Pro"), connection: sent)
    panel.block()
    XCTAssertEqual(sent.lastDisconnect, .init(viewerID: "MacBook Pro", block: true))
}

func testBlockedMachinesRowsExist() {
    let rows = CommandPaletteModel.build(/* fixture */)
    XCTAssertTrue(rows.map(\.title).contains("Blocked machines"))
    XCTAssertTrue(rows.map(\.title).contains("Terminate connection"))
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/RemoteTakeoverPanelTests`

- [ ] **Step 3: Implement**

Two buttons in the panel footer: **Terminate** (secondary) and **Block** (destructive tint). Copy under Block: "‹machine› will not be able to connect again until you unblock it in Settings › Remote." — say what it means, since it no longer expires by itself.

Settings › Remote gains **Blocked machines**: one row per id in `remote_control_blocked` with an **Unblock** button calling `RemoteSharingModel.unblock(_:)`. Empty state: "No machines are blocked."

Menu bar: `.connected` whenever `liveConnection != nil`, so the icon goes blue for exactly as long as the panel is up.

Palette rows: **Blocked machines**, plus **Terminate connection** and **Block this machine** present only while `liveConnection != nil`.

- [ ] **Step 4: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): terminate, block, unblock — and the icon goes blue

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

# Phase 4 — The activity log

Ships on its own: everything a remote client does to this machine appears as a row the host can read, and survives on disk.

### Task 17: Frames become rows

**Model:** opus
**Spec:** §8

**Files:**
- Create: `crates/omniagent-pty-daemon/src/activity.rs`
- Modify: `crates/omniagent-pty-daemon/src/lib.rs` (declare the module)
- Test: `crates/omniagent-pty-daemon/tests/remote_activity.rs` (create)

**Interfaces:**
- Produces:
```rust
pub struct ActivityEntry {
    pub ts: SystemTime,
    pub kind: &'static str,   // "attach", "create_session", "input", …
    pub summary: String,      // one line, human, no ids
    pub detail: Option<String>, // shown when the row is expanded
}
pub struct ActivityLog {
    /// Half-typed input per session id, flushed on CR, Interrupt, or quiet.
    pending: HashMap<String, (String, Instant)>,
}
impl ActivityLog {
    pub fn record(&mut self, frame: &Frame, ctx: &ActivityContext) -> Option<ActivityEntry>;
    pub fn flush_input(&mut self, session: &str) -> Option<ActivityEntry>;
    pub fn tick(&mut self, now: Instant) -> Vec<ActivityEntry>; // 5 s quiet flush
}
```
Task 18 persists these; Task 19 pushes them; Task 20 renders them.

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn a_typed_prompt_is_one_row_not_one_row_per_keystroke() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();          // knows pane titles, engines, workspaces

    for byte in b"hello there" {
        assert!(log.record(&input_frame("pane-1", &[*byte]), &ctx).is_none());
    }
    let entry = log.record(&input_frame("pane-1", b"\r"), &ctx).expect("flushed on CR");

    assert_eq!(entry.kind, "input");
    assert_eq!(entry.summary, "Sent a prompt to Terminal 1 (claude)");
    assert_eq!(entry.detail.as_deref(), Some("hello there"));
}

#[test]
fn input_flushes_after_five_seconds_of_quiet_even_without_a_return() {
    let mut log = ActivityLog::default();
    log.record(&input_frame("pane-1", b"partial"), &ActivityContext::fixture());
    let entries = log.tick(Instant::now() + Duration::from_secs(6));
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].detail.as_deref(), Some("partial"));
}

#[test]
fn rows_that_say_everything_have_no_detail_to_expand() {
    let mut log = ActivityLog::default();
    let entry = log.record(&attach_frame("pane-1"), &ActivityContext::fixture()).unwrap();
    assert_eq!(entry.summary, "Opened Terminal 1 in Session 1 · OmniAgent-ADE");
    assert_eq!(entry.detail, None);
}

#[test]
fn secrets_are_redacted_before_they_are_ever_written() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    log.record(&input_frame("pane-1", b"export TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwxyz"), &ctx);
    let entry = log.record(&input_frame("pane-1", b"\r"), &ctx).unwrap();
    assert!(!entry.detail.as_deref().unwrap().contains("ghp_0123456789"));
}

#[test]
fn interrupt_flushes_whatever_was_half_typed() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    log.record(&input_frame("pane-1", b"half"), &ctx);
    let entries: Vec<_> = [log.record(&interrupt_frame("pane-1"), &ctx)].into_iter().flatten().collect();
    assert!(entries.iter().any(|e| e.detail.as_deref() == Some("half")));
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_activity`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the mapping**

`ActivityContext` resolves ids into words by reading the **`layout` settings row** — the daemon already holds it, so a pane id becomes "Terminal 1 in Session 1 · OmniAgent-ADE" without the app being asked. Re-read it lazily per connection and cache for the connection's life; a `SetSetting("layout")` frame invalidates the cache. When a pane id is not in the layout, fall back to the raw id rather than dropping the row — an unattributable action is exactly the one worth logging.

One `match` on `MessageKind`, producing exactly the table in spec §8. `Input` is buffered per session id and flushed on CR, on `Interrupt`, or after 5 s of quiet. Reuse the repo's existing transcript secret-redaction function on the flushed text — do not write a second redactor.

Add the ceiling comment verbatim:

```rust
// ponytail: redaction only; PTY echo-state detection if this ever bites.
// The daemon cannot tell a password prompt from a shell prompt, so a typed
// secret can reach this log. Recorded rather than papered over (spec §8).
```

- [ ] **Step 4: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): remote frames become readable activity rows

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 18: The log survives the connection

**Model:** sonnet
**Spec:** §8

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/activity.rs`
- Test: `crates/omniagent-pty-daemon/tests/remote_activity.rs`

**Interfaces:**
- Produces: `pub fn append(entry: &ActivityEntry, data_dir: &Path) -> io::Result<()>` writing one JSON object per line to `<data_dir>/remote-activity.jsonl`, rotating to `remote-activity.1.jsonl` past 8 MB and keeping exactly one previous file. Task 20 reads this file.

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn entries_append_one_json_object_per_line() {
    let dir = tempfile::tempdir().unwrap();
    append(&entry("attach", "Opened Terminal 1"), dir.path()).unwrap();
    append(&entry("input", "Sent a prompt"), dir.path()).unwrap();

    let text = std::fs::read_to_string(dir.path().join("remote-activity.jsonl")).unwrap();
    let lines: Vec<_> = text.lines().collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(serde_json::from_str::<serde_json::Value>(lines[0]).unwrap()["kind"], "attach");
}

#[test]
fn the_file_rotates_once_and_keeps_exactly_one_previous() {
    let dir = tempfile::tempdir().unwrap();
    for _ in 0..40_000 { append(&entry("input", &"x".repeat(256)), dir.path()).unwrap(); }
    assert!(dir.path().join("remote-activity.jsonl").exists());
    assert!(dir.path().join("remote-activity.1.jsonl").exists());
    assert!(!dir.path().join("remote-activity.2.jsonl").exists());
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_activity append`

- [ ] **Step 3: Implement**

Open with `OpenOptions::new().create(true).append(true)`. Check length before writing; past 8 MB, rename to `.1.jsonl` (replacing any existing one) and start fresh. Write failures are logged at `warn` and swallowed — a full disk must not drop a remote session.

Spec invariant 8 (the log is not remotely readable or writable) holds because **no file-read RPC exists**: `ListDirectory` returns names and is-dir flags only, pinned by Task 9's "no contents" assertion. Do not add a file-read RPC to this plan.

- [ ] **Step 4: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): the activity log outlives the connection

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 19: `RemoteActivity` reaches the host app

**Model:** sonnet
**Spec:** §8

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/protocol.rs` (`RemoteActivity = 0x8f`)
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (record on every remote frame; push to local connections)
- Create: `macos/OmniAgent/RemoteActivityLog.swift`
- Test: `crates/omniagent-pty-daemon/tests/remote_activity.rs`, `macos/OmniAgentTests/RemoteActivityLogTests.swift`

**Interfaces:**
- Produces the push payload `{"entries":[{"ts":"<rfc3339>","kind":"…","summary":"…","detail":"…"|null}]}`, and:
```swift
@MainActor final class RemoteActivityLog: ObservableObject {
    @Published private(set) var entries: [Entry]      // live, newest last
    struct Entry: Identifiable, Equatable { let id: UUID; let ts: Date; let kind: String; let summary: String; let detail: String? }
    static func history(from url: URL, limit: Int) -> [Entry]   // reads the JSONL for Task 20
}
```

- [ ] **Step 1: Write the failing tests**

```rust
#[tokio::test]
async fn activity_is_pushed_to_local_clients_and_never_to_the_remote_one() {
    let harness = support::daemon_with_local_client().await;
    let viewer = harness.connect_remote("MacBook Pro").await;
    viewer.hello().await;
    viewer.attach("pane-1").await;

    let pushed = harness.local().next_activity().await;
    assert_eq!(pushed.entries[0].kind, "attach");
    assert!(viewer.received_no_activity_push());
}
```

```swift
func testHistoryReadsNewestFirstAndTolerantOfGarbageLines() throws {
    let url = try writeTempJSONL([
        #"{"ts":"2026-09-01T10:00:00Z","kind":"attach","summary":"Opened Terminal 1","detail":null}"#,
        "not json at all",
        #"{"ts":"2026-09-01T10:01:00Z","kind":"input","summary":"Sent a prompt","detail":"hello"}"#,
    ])
    let entries = RemoteActivityLog.history(from: url, limit: 10)
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries.first?.summary, "Sent a prompt")
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `cargo test -p omniagent-pty-daemon --test remote_activity pushed` then `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/RemoteActivityLogTests`

- [ ] **Step 3: Implement**

Record in `serve_client`'s remote path, right after `authorize_remote` succeeds — an authorized frame is one that happened. Publish through the same `watch`-channel + per-connection feed mechanism phase 2 built for `RemoteViewers`; **never hold a writer inside the registry lock**. `RemoteActivity` is local-only, so add it to `authorize_remote`'s deny arm by simply not listing it.

- [ ] **Step 4: Run everything and commit**

Run: `cargo test -p omniagent-pty-daemon && caffeinate -disu ./macos/build.sh test`

```bash
git add crates/ macos/
git commit -m "feat: push remote activity to the host, and only to the host

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 20: The table, and the history

**Model:** sonnet
**Spec:** §7, §8

**Files:**
- Modify: `macos/OmniAgent/RemoteTakeoverPanel.swift` (the table)
- Modify: `macos/OmniAgent/SettingsRemoteView.swift` (Activity)
- Modify: `macos/OmniAgent/CommandPalette.swift`
- Test: `macos/OmniAgentTests/RemoteActivityLogTests.swift`, `CommandPaletteTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testOnlyRowsWithDetailAreExpandable() {
    let table = RemoteActivityTable(entries: [
        .init(id: .init(), ts: .now, kind: "attach", summary: "Opened Terminal 1", detail: nil),
        .init(id: .init(), ts: .now, kind: "input", summary: "Sent a prompt to Terminal 1", detail: "hello there"),
    ])
    XCTAssertFalse(table.isExpandable(at: 0))
    XCTAssertTrue(table.isExpandable(at: 1))
}

func testActivityPaletteRowExists() {
    XCTAssertTrue(CommandPaletteModel.build(/* fixture */).map(\.title).contains("Remote activity"))
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/RemoteActivityLogTests`

- [ ] **Step 3: Implement**

Panel table: newest at the bottom, auto-scrolling while it is at the bottom and holding position when the host has scrolled up. One row = time, symbol for `kind`, summary. A row with a `detail` gets a disclosure chevron and reveals the detail in a monospaced block; a row without one has no chevron and does not respond to clicks.

Settings › Remote › **Activity**: `RemoteActivityLog.history(from:limit:)` over `<data root>/remote-activity.jsonl`, grouped by connection (a `"connected"` row starts a group), newest group first, each collapsible. Cap at the most recent 2 000 rows. Empty state: "No remote sessions yet."

Palette row **Remote activity**.

- [ ] **Step 4: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): the activity table, live and after the fact

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

# Phase 5 — The environment itself

The phase that makes a remote computer *be* the host. Everything before it was the safety around this.

### Task 21: `PublishHostState` and `HostState`

**Model:** sonnet
**Spec:** §4

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/protocol.rs` (`PublishHostState = 0x1c`, `HostState = 0x8e`)
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (store latest; forward to the lease holder)
- Test: `crates/omniagent-pty-daemon/tests/host_state.rs` (create)

**Interfaces:**
- Consumes: `ConnectionRegistry::lease_holder()` (Task 7)
- Produces: the daemon holds `Option<String>` (the last published JSON, opaque) and sends `HostState` to the lease holder on attach and on every publish. Tasks 22 and 26 are the two ends.

- [ ] **Step 1: Write the failing test**

```rust
#[tokio::test]
async fn host_state_reaches_the_lease_holder_on_connect_and_on_change() {
    let harness = support::daemon_with_local_client().await;
    harness.local().publish_host_state(r#"{"metrics":{"cpu":0.5}}"#).await;

    let viewer = harness.connect_remote("MacBook Pro").await;
    viewer.hello().await;
    assert_eq!(viewer.next_host_state().await["metrics"]["cpu"], 0.5);

    harness.local().publish_host_state(r#"{"metrics":{"cpu":0.9}}"#).await;
    assert_eq!(viewer.next_host_state().await["metrics"]["cpu"], 0.9);
}

#[tokio::test]
async fn a_remote_client_may_not_publish_host_state() {
    let harness = support::daemon_with_local_client().await;
    let viewer = harness.connect_remote("MacBook Pro").await;
    viewer.hello().await;
    assert!(viewer.publish_host_state("{}").await.is_error());
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `cargo test -p omniagent-pty-daemon --test host_state`

- [ ] **Step 3: Implement**

The daemon stores the string and forwards it; it never parses the payload. `PublishHostState` is absent from `authorize_remote`'s allowlist, which is what denies it.

- [ ] **Step 4: Run and commit**

Run: `cargo test -p omniagent-pty-daemon`

```bash
git add crates/omniagent-pty-daemon/
git commit -m "feat(daemon): forward the host's own state to the lease holder

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 22: The host publishes what only it knows

**Model:** sonnet
**Spec:** §4

**Files:**
- Create: `macos/OmniAgent/HostStatePublisher.swift`
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (start/stop with the lease)
- Test: `macos/OmniAgentTests/HostStatePublisherTests.swift` (create)

**Interfaces:**
- Consumes: the gauge sources in `NavigationSidebar.swift:477-514`, `ClaudeUsageLimits`, engine availability from `EngineLauncher`
- Produces: `HostStatePublisher.payload()` → the exact JSON in spec §4, and `start()`/`stop()`.

- [ ] **Step 1: Write the failing test**

```swift
func testPayloadCarriesEverythingAViewerCannotComputeItself() throws {
    let json = try JSONSerialization.jsonObject(
        with: HostStatePublisher(sources: .fixture()).payload()) as! [String: Any]

    XCTAssertNotNil((json["metrics"] as? [String: Any])?["cpu"])
    XCTAssertNotNil((json["metrics"] as? [String: Any])?["gpu"])
    XCTAssertNotNil((json["limits"] as? [String: Any])?["weekPercent"])
    XCTAssertEqual(((json["engines"] as? [String: Any])?["claude"] as? [String: Any])?["available"] as? Bool, true)
    XCTAssertEqual((json["host"] as? [String: Any])?["name"] as? String, "Test Mac")
}

func testNothingIsComputedWhileNobodyIsConnected() {
    let sources = SpyHostStateSources()
    let publisher = HostStatePublisher(sources: sources)
    publisher.stop()
    XCTAssertEqual(sources.metricsReads, 0)
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/HostStatePublisherTests`

- [ ] **Step 3: Implement**

Extract the gauge computation from `NavigationSidebar` into a small `HostMetrics` source both the sidebar and the publisher use — do not duplicate the `host_statistics` calls. Metrics at 1 Hz, limits and engines on change. `start()` only when the lease is taken; `stop()` when it is released. Nothing runs when nobody is connected.

- [ ] **Step 4: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): publish the gauges, limits and engines to the lease holder

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 23: The connection swap

**Model:** opus
**Spec:** §1, §6

**Files:**
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (the connection becomes swappable)
- Modify: `macos/OmniAgent/AppDelegate.swift:28`
- Modify: `macos/OmniAgent/RemoteMachinesModel.swift:161`
- Test: `macos/OmniAgentTests/ConnectionSwapTests.swift` (create)

This is the riskiest change in the plan: everything that captured the connection must tolerate it being re-pointed. Read every subscriber before editing.

**Interfaces:**
- Produces:
```swift
extension WorkspaceWindowController {
    /// Points the whole window at another daemon. Local state is not destroyed —
    /// `disconnectRemote()` restores it exactly.
    func connectRemote(to machine: RemoteMachine) async throws
    func disconnectRemote()
    var isDrivingRemote: Bool { get }
}
```

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
func testSwappingRestoresLocalStateExactly() async throws {
    let controller = try makeController(connection: FakeConnection.local)
    let localWorkspaces = controller.workspaceIDs

    try await controller.connectRemote(to: .fixture(connection: FakeConnection.remote))
    XCTAssertTrue(controller.isDrivingRemote)
    XCTAssertNotEqual(controller.workspaceIDs, localWorkspaces)

    controller.disconnectRemote()
    XCTAssertFalse(controller.isDrivingRemote)
    XCTAssertEqual(controller.workspaceIDs, localWorkspaces)
}

@MainActor
func testEverySubscriberFollowsTheSwap() async throws {
    let controller = try makeController(connection: FakeConnection.local)
    try await controller.connectRemote(to: .fixture(connection: FakeConnection.remote))
    // No subscriber may still be holding the local connection.
    XCTAssertTrue(FakeConnection.local.subscribers.isEmpty)
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/ConnectionSwapTests`

- [ ] **Step 3: Implement**

Make the controller's connection a single stored property with a `didSet` that tears down every subscription and re-establishes it against the new connection. Subscribers must resolve the connection through the controller rather than capturing it at init — find each capture and change it. `disconnectRemote()` swaps back to the local socket connection, which was kept alive but idle.

Note in the doc comment that the local connection being dropped is exactly what makes chaining impossible (spec §3), so nobody later "fixes" it by keeping both attached.

- [ ] **Step 4: Run the whole suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): the window can be pointed at another daemon

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 24: The connect ceremony

**Model:** sonnet
**Spec:** §6

**Files:**
- Create: `macos/OmniAgent/RemoteConnectCeremony.swift`
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (drive it from `connectRemote`)
- Test: `macos/OmniAgentTests/RemoteConnectCeremonyTests.swift` (create)

**Interfaces:**
- Produces: `enum ConnectStep { case dialling, securing, confirming, loading, done }` and a view driven by it. Each step advances on a real milestone; there is no timer.

- [ ] **Step 1: Write the failing test**

```swift
func testEachStepAdvancesOnItsRealMilestone() {
    let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
    XCTAssertEqual(ceremony.step, .dialling)
    ceremony.webSocketOpened();  XCTAssertEqual(ceremony.step, .securing)
    ceremony.dataChannelOpened(); XCTAssertEqual(ceremony.step, .confirming)
    ceremony.helloAcknowledged(); XCTAssertEqual(ceremony.step, .loading)
    ceremony.environmentLoaded(); XCTAssertEqual(ceremony.step, .done)
}

func testAFailureShowsThatStepsOwnMessage() {
    let ceremony = RemoteConnectCeremony(machineName: "Mac Studio")
    ceremony.webSocketOpened()
    ceremony.dataChannelOpened()
    ceremony.failed(.init(message: "in use by MacBook Pro"))
    XCTAssertEqual(ceremony.failure?.step, .confirming)
    XCTAssertEqual(ceremony.failure?.message, "in use by MacBook Pro")
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/RemoteConnectCeremonyTests`

- [ ] **Step 3: Implement**

Full-window liquid glass in the focus-mode treatment, the OmniAgent mark, and the four lines from spec §6: *Connecting to ‹machine›…*, *Establishing a secure line…*, *Confirming credentials…*, *Loading environment…*. Completed steps get a check; the current one animates. On `.done`: a green check, then fade out over ~400 ms into the loaded environment. On failure: the failing step turns red and shows the daemon's own message, with **Try again** and **Cancel**.

Never fake progress — a step that has not happened has not happened.

- [ ] **Step 4: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): the connect ceremony, one line per real milestone

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 25: The Remote live session widget, and no chaining in the UI

**Model:** sonnet
**Spec:** §3, §6

**Files:**
- Create: `macos/OmniAgent/SidebarRemoteSessionWidget.swift`
- Modify: `macos/OmniAgent/NavigationSidebar.swift:1004-1008` (mount it above the update widget)
- Modify: `macos/OmniAgent/RemoteSessionPicker.swift`, `WorkspacesHeaderMenus.swift`, `CommandPalette.swift` (disable Connect while driving)
- Test: `macos/OmniAgentTests/RemoteChainingTests.swift` (create)

- [ ] **Step 1: Write the failing test**

```swift
func testConnectIsDisabledEverywhereWhileASessionIsLive() {
    let model = RemoteSharingModel.fixture(activeRemoteSession: .init(machineName: "Mac Studio", since: .now))

    XCTAssertFalse(RemoteSessionPicker.canConnect(model: model))
    XCTAssertEqual(RemoteSessionPicker.disabledReason(model: model),
                   "End the session with Mac Studio first")

    let rows = CommandPaletteModel.build(/* fixture with model */)
    let connect = rows.first { $0.title.hasPrefix("Connect to") }
    XCTAssertEqual(connect?.isEnabled, false)
    XCTAssertTrue(rows.map(\.title).contains("End remote session"))
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/RemoteChainingTests`

- [ ] **Step 3: Implement**

The widget: same liquid glass as `SidebarUpdateWidgetView`, mounted **above** it (so the order down the column is remote session → update → session/week limits). Host name, elapsed time counting up locally, and a red **End session** button calling `disconnectRemote()`.

Disable **Connect to ‹machine›** in the picker, the `+` menu and the palette whenever `activeRemoteSession != nil`, with the reason as the disabled subtitle. Add the **End remote session** palette row, present only while a session is live.

This is belt-and-braces: the daemon already refuses chained connections structurally (Task 10). Say so in a comment so nobody deletes one thinking the other covers it.

- [ ] **Step 4: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): the live-session widget, and Connect is off while driving

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 26: The viewer shows the host's gauges, limits and engines

**Model:** sonnet
**Spec:** §4, §6

**Files:**
- Modify: `macos/OmniAgent/NavigationSidebar.swift` (gauges read `HostState` when driving)
- Modify: `macos/OmniAgent/SidebarClaudeLimitsView.swift` (same)
- Modify: `macos/OmniAgent/EngineLauncher.swift` / the engine picker (availability from `HostState`)
- Test: `macos/OmniAgentTests/HostStateConsumerTests.swift` (create)

- [ ] **Step 1: Write the failing test**

```swift
func testGaugesAndLimitsFollowTheHostWhileDriving() {
    let model = HostStateModel()
    model.apply(#"{"metrics":{"cpu":0.9,"mem":0.5,"gpu":0.2},"limits":{"weekPercent":63},"engines":{"codex":{"available":false}}}"#)

    XCTAssertEqual(model.metrics?.cpu, 0.9)
    XCTAssertEqual(model.limits?.weekPercent, 63)
    XCTAssertEqual(model.engineAvailability["codex"], false)
}

func testAnEngineMissingOnTheHostIsShownUnavailableEvenIfInstalledLocally() {
    let picker = EnginePickerModel(hostState: .fixture(engines: ["codex": false]), isDrivingRemote: true)
    XCTAssertFalse(picker.isAvailable(.codex))
    XCTAssertEqual(picker.unavailableReason(.codex), "Not installed on Mac Studio")
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/HostStateConsumerTests`

- [ ] **Step 3: Implement**

One `HostStateModel` parses the payload; the three surfaces read from it when `isDrivingRemote`, and from their existing local sources otherwise. A missing key keeps the last value rather than blanking, the same rule `ClaudeUsageLimits.merged(onto:)` already follows for the same reason.

- [ ] **Step 4: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): the sidebar reads the host's machine, not this one

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 27: Whoever drives owns the grid

**Model:** sonnet
**Spec:** §5, §1

**Files:**
- Modify: `macos/OmniAgent/TerminalSurfaceView.swift:436` (`flushResize`)
- Delete: `macos/OmniAgent/RemoteTerminalScaler.swift` and its tests
- Modify: `crates/omniagent-pty-daemon/src/protocol.rs` (delete `SessionResized = 0x8c`)
- Test: `macos/OmniAgentTests/GridOwnershipTests.swift` (create)

- [ ] **Step 1: Write the failing test**

```swift
func testTheViewerResizesAndTheSharedHostDoesNot() {
    let viewer = TerminalSurfaceView.fixture(isDrivingRemote: true, sharingIsLive: false)
    viewer.flushResize()
    XCTAssertNotNil(viewer.sentResize)

    let host = TerminalSurfaceView.fixture(isDrivingRemote: false, sharingIsLive: true)
    host.flushResize()
    XCTAssertNil(host.sentResize)
}

func testTheHostReclaimsTheGridWhenTheSessionEnds() {
    let host = TerminalSurfaceView.fixture(isDrivingRemote: false, sharingIsLive: true)
    host.flushResize()
    XCTAssertNil(host.sentResize)

    host.sharingWentIdle()
    XCTAssertNotNil(host.sentResize)
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/GridOwnershipTests`

- [ ] **Step 3: Implement**

Invert the phase-2 gate: `flushResize()` early-returns while **sharing is live on this machine**, not while the connection is remote. On the lease being released, re-send the size for every visible pane.

Delete `RemoteTerminalScaler.swift`, the `metalScaleFactorOverride` usage, the remote ⌘+/⌘−/⌘0 overrides and their tests. Delete `SessionResized` from the protocol and both handlers.

Comment at `flushResize` explaining the inversion, so a future reader does not "restore" phase 2's rule: the host's terminals do look mismatched behind the panel, and that is invisible because the panel covers them.

- [ ] **Step 4: Run everything and commit**

Run: `cargo test -p omniagent-pty-daemon && caffeinate -disu ./macos/build.sh test`

```bash
git add crates/ macos/
git commit -m "feat: whoever drives owns the grid; the scaler is gone

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 28: Adding a workspace from the other Mac

**Model:** sonnet
**Spec:** §4, §6

**Files:**
- Create: `macos/OmniAgent/RemoteFolderBrowser.swift`
- Modify: the "Add local folder…" path in `WorkspacesHeaderMenus.swift` / `WorkspaceWindowController.openWorkspaceFolder`
- Test: `macos/OmniAgentTests/RemoteFolderBrowserTests.swift` (create)

- [ ] **Step 1: Write the failing test**

```swift
func testAddFolderBrowsesTheHostNotThisMacWhileDriving() async throws {
    let connection = FakeConnection.remote
    connection.stub(.listDirectory, with: #"{"entries":[{"name":"Documents","is_dir":true},{"name":"notes.md","is_dir":false}]}"#)

    let browser = RemoteFolderBrowser(connection: connection)
    let entries = try await browser.list("/Users/bonando")

    XCTAssertEqual(entries.map(\.name), ["Documents", "notes.md"])
    XCTAssertTrue(browser.canChoose(entries[0]))   // a directory
    XCTAssertFalse(browser.canChoose(entries[1]))  // a file
}

func testTheLocalPanelIsUsedWhenNotDriving() {
    XCTAssertTrue(WorkspaceWindowController.usesNativeOpenPanel(isDrivingRemote: false))
    XCTAssertFalse(WorkspaceWindowController.usesNativeOpenPanel(isDrivingRemote: true))
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/RemoteFolderBrowserTests`

- [ ] **Step 3: Implement**

A liquid-glass sheet listing one directory at a time via `ListDirectory` (Task 9), with a path bar, up-navigation, directories selectable and files not, and **Add** calling `RootsAddProject`. `NSOpenPanel` is used only when not driving — it would show the wrong machine's disk otherwise.

- [ ] **Step 4: Run the suite and commit**

Run: `caffeinate -disu ./macos/build.sh test`

```bash
git add macos/
git commit -m "feat(macos): add a workspace from the other Mac, browsing the host's disk

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 29: Delete the projection and the mirrored tree

**Model:** sonnet
**Spec:** §1

**Files:**
- Delete: `macos/OmniAgent/RemoteControlProjection.swift` and `RemoteControlProjectionTests.swift`
- Modify: `macos/OmniAgent/SettingsKeys.swift` (delete `remoteControl`)
- Modify: `macos/OmniAgent/WorkspacesTree.swift` (delete `renderRemoteMachines` and the remote row variants)
- Modify: `macos/OmniAgent/RemoteSessionPicker.swift` (collapse to a machine list)
- Modify: `crates/omniagent-pty-daemon/src/server.rs` (delete `remote_session_ids`, `REMOTE_CONTROL_KEY`)
- Modify: `macos/OmniAgent/CommandPalette.swift` (remote rows become one per machine)
- Test: update `CommandPaletteTests`; delete the projection fixtures

- [ ] **Step 1: Write the failing test**

```swift
func testTheRemotePaletteRowsAreOneMachineEachNotOnePaneEach() {
    let rows = CommandPaletteModel.build(/* two online machines, several panes each */)
    let remote = rows.filter { $0.title.hasPrefix("Connect to") }
    XCTAssertEqual(remote.count, 2)
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `caffeinate -disu ./macos/build.sh test -only-testing:OmniAgentTests/CommandPaletteTests`

- [ ] **Step 3: Delete**

Remove every file and symbol listed above. `RemoteSessionPicker` becomes a list of online machines with **Connect**, plus the three empty states from phase 2 §4, reworded for machines: "No other Macs are sharing", "Signing in…", "‹name› is offline".

Grep for `remote_control` across both `crates/` and `macos/` afterwards; the only survivor must be `remote_control_blocked`.

- [ ] **Step 4: Run everything and commit**

Run: `cargo test -p omniagent-pty-daemon && caffeinate -disu ./macos/build.sh test`

```bash
git add -A crates/ macos/
git commit -m "refactor: delete the projection and the mirrored tree

Nothing about the host leaves it until a connection exists and the host has
been told. The viewer's sidebar shows the host's workspaces because it is
reading the host's layout row over the same RPCs the host uses.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 30: Two Macs, and the release

**Model:** opus
**Spec:** §11, §14

**Files:** none — this task verifies and ships.

- [ ] **Step 1: Deploy the relay to production**

```bash
cd ../OmniAgent-Core
KUBECONFIG=~/.kube/k3s-lens.yaml ./deploy.sh production
```

Pin the **short-sha** image tag; `make migrate-production` pins `:latest`, which serves a stale image. Back up the prod secret before any patch — the patch clobbers `JINA` with `CHANGE_ME`.

- [ ] **Step 2: Full suites, both repos**

```bash
cd ../OmniAgent-ADE
cargo test --workspace
caffeinate -disu ./macos/build.sh test
cargo fmt --all && cargo clippy --all-targets --all-features
```

Known-failing before this work: the daemon `server_protocol` timeouts and the divider-drag test. Anything else failing is yours.

- [ ] **Step 3: Build and install**

```bash
./scripts/bump-build-version.sh --minor
./scripts/rebuild-app.sh
```

Do **not** pass `--keep-daemon`: the protocol version changed. Verify the app actually relaunched (`pgrep -f OmniAgent`; `open -a OmniAgent` if empty).

- [ ] **Step 4: Verify on two Macs**

Walk the whole story and check each against the spec:

1. Sharing off → the other Mac sees the machine offline. Icon is template.
2. Turn sharing on in Settings, then off and on from the menu bar → icon green.
3. Connect from the second Mac → ceremony runs its four real steps → the host's workspaces, Home, gauges, limits and engines appear. Host icon goes blue and the takeover panel appears with IP and country marked verified.
4. On the viewer: open a terminal, type a prompt, create a session, add a workspace by browsing the host's disk, resize the window and confirm the terminal reflows at the viewer's resolution.
5. On the host: every one of those appears in the activity table, the prompt expanding to its text.
6. **Connect to ‹machine›** is disabled on the viewer while connected.
7. Terminate → host reclaims, panel closes, icon green, viewer returns to its own environment; reconnect works.
8. Block → viewer is refused; Settings › Remote lists it; Unblock restores it.
9. Quit the host app → the machine goes offline for the viewer. Relaunch → it comes back.
10. Settings › Remote › Activity shows the finished session.

- [ ] **Step 5: Publish**

```bash
./scripts/publish-release.sh    # foreground shell only; notary profile is `bonando-notary`
```

- [ ] **Step 6: Commit the version bump**

```bash
git add macos/OmniAgent.xcodeproj/project.pbxproj
git commit -m "release: remote environment sharing

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

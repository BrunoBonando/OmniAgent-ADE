import Foundation

/// The machine-wide sharing switch (2026-09-01 remote environment sharing
/// spec §2): Settings › Remote and the menu bar dropdown both read and
/// write through this. Replaces the per-workspace **Enable Remote Control**
/// toggle `WorkspaceWindowController` used to own — sharing is now one
/// switch for the whole Mac, not a set of enabled workspaces
/// (`WorkspaceContextMenu`/`WorkspacesTree`'s globe are deleted with it).
///
/// Two rows, restored once `configure(store:)`/`init(store:)` supplies a
/// store, kept live from there:
/// - `remote_sharing` = `{"enabled":bool}` (`SettingsKey.remoteSharing`) —
///   this Mac's own intent. Decoded the same way the daemon decodes it
///   (Task 1's `remote_control_active`,
///   `crates/omniagent-pty-daemon/src/server.rs`): absent row, unparseable
///   JSON, or a missing/non-bool `enabled` all read as `false` — fails
///   closed, never open. `setSharing` writes the row byte for byte
///   (`"{\"enabled\":true}"`/`"{\"enabled\":false}"`, no encoder involved,
///   because a mismatch here silently disables remote sharing on the
///   daemon's side).
/// - `remote_control_blocked` (`SettingsKey.remoteControlBlocked`) — viewer
///   ids this Mac refuses, `["<viewer_id>", …]` (`RemoteControlProjection`'s
///   `encodeEnabled`/`decodeEnabled` shape — the same sorted-JSON-array
///   convention, reused rather than re-implemented). The daemon only ever
///   *adds* to this row (a kick has to hold with the app closed); the app
///   only ever removes from it, and only through `unblock(_:)`.
///
/// **Turning sharing on no longer clears the blocked list.** Phase 2's
/// design forgave every kicked machine the moment Remote Control was
/// switched back on for any workspace —
/// `WorkspaceWindowController.toggleRemoteControl` used to write `"[]"` to
/// `remote_control_blocked` on every enable. The 2026-09-01 spec
/// deliberately drops that (§2 "only when it is cleared changes — no longer
/// on toggling sharing, only on an explicit Unblock", §7 "Block ·
/// Unblocking is the app rewriting `remote_control_blocked` without that
/// id"): a blocked machine now stays blocked until someone explicitly
/// unblocks it in Settings › Remote. This is a deliberate behavior change,
/// not a bug — `testTurningSharingOnDoesNotClearTheBlockedList` pins it so
/// nobody "fixes" `setSharing` back to clearing the list.
///
/// **Writes are never optimistic.** `isSharing`/`blockedViewerIDs` change
/// only after the daemon confirms the write; a failure leaves the previous
/// value standing and calls `onWriteFailed` instead. A control bound to
/// this (Settings › Remote's switch, Task 3) must never show a state that
/// is not actually on disk — the review round that added this doc comment
/// caught an earlier version of this file mutating both properties
/// *before* the write, with no rollback on failure.
@MainActor
final class RemoteSharingModel {
    /// Configured once, by `AppDelegate`, with the app's own real
    /// connection — `SettingsStore(client: connection)` wraps the exact
    /// `SessionConnection` `AppDelegate.swift` builds and
    /// `WorkspaceWindowController.start()` connects, the same object every
    /// other settings row in this app reads and writes through
    /// (`WorkspaceWindowController.init`'s own `SettingsStore(client:
    /// settingsClient ?? connection)`). `.shared` previously built its
    /// *own*, never-`connect()`ed `SessionConnection` here, so every read
    /// and write failed with `.disconnected` forever — that bug is what
    /// `configure(store:)` exists to fix: reuse the connection the app
    /// already dials rather than mint a second, dead one.
    static let shared = RemoteSharingModel()

    private(set) var isSharing = false
    private(set) var blockedViewerIDs: [String] = []
    /// The machine driving this Mac right now, or `nil` when nobody is —
    /// the fact the takeover panel (spec §7), the blue menu bar icon (§2)
    /// and the Terminate/Block palette rows (§10) are all one reading of.
    ///
    /// Derived from the daemon's presence roster (`RemoteViewers`, phase 2
    /// `0x8d`), which since Task 15 carries the relay-asserted half of the
    /// identity beside the self-reported half. It is *not* a second source of
    /// truth: the daemon admits at most one remote connection at a time (spec
    /// §3 "The lease"), so the roster is the lease, and this is the roster's
    /// first entry.
    private(set) var liveConnection: RemoteConnectionInfo?
    /// Fires whenever either row actually changes — the menu bar icon and
    /// Settings › Remote both redraw off this rather than polling.
    var onChange: (() -> Void)?
    /// Fires when `setSharing`/`unblock`'s write fails — the daemon
    /// unreachable, the socket down, or (for `.shared` specifically) asked
    /// before `configure(store:)` has run. Whoever binds a control to this
    /// model listens here to say so, rather than trusting a state change
    /// that never reached disk.
    var onWriteFailed: ((Error) -> Void)?

    /// `nil` until `configure(store:)` (`.shared`'s path) or `init(store:)`
    /// (every other path, tests included) supplies one. Every operation
    /// below fails closed — same as an unreachable daemon — while it is.
    private var store: SettingsStore?
    private var restoreDispatched = false
    /// Whether a restore has ever finished — both rows read, not just
    /// dispatched. `connectionDidComeUp()` is what re-arms a restore that
    /// never did, and this is how it tells "already restored" from "tried
    /// once and failed".
    private var restoreCompleted = false

    /// The test / explicit-construction path: a store is already known, so
    /// this restores immediately (synchronously, against the fakes every
    /// test in this file uses).
    init(store: SettingsStore) {
        self.store = store
        restore()
    }

    /// `.shared`'s own path: no store yet, nothing to restore.
    /// `configure(store:)` supplies one once the app's real connection
    /// exists.
    private init() {}

    /// Called once, by `AppDelegate`, only once the app's real connection is
    /// actually up (`WorkspaceWindowController.runWhenConnected` — see
    /// `AppDelegate.swift`). Restores immediately, and re-arms in case this
    /// is a second call (defensive — production calls this exactly once,
    /// but nothing here assumes that).
    ///
    /// This used to run unconditionally at launch, before
    /// `workspace.start()` even called `connect()` — a race `restore()`
    /// covered with its own bounded 5×1s retry timer, which still stranded
    /// `.shared` at its defaults forever whenever the daemon took longer
    /// than 5s to spawn (nothing ever called `configure` a second time).
    /// `runWhenConnected` replaces that guess with the actual readiness
    /// signal: this is never called until the socket is up, so the very
    /// first `restore()` here no longer needs a retry to win the race.
    func configure(store: SettingsStore) {
        self.store = store
        restoreDispatched = false
        restore()
    }

    /// Turns sharing on or off. Writes only `remote_sharing` — the blocked
    /// list is untouched (see the type's own doc comment above). `isSharing`
    /// changes only once the write actually lands; a failure leaves it
    /// exactly as it was and calls `onWriteFailed` instead of guessing.
    func setSharing(_ on: Bool) {
        guard let store else {
            onWriteFailed?(RemoteSharingModelError.notConfigured)
            return
        }
        // Switching sharing **off** is always allowed — a host with no
        // account row must still be able to stop sharing, and the daemon
        // must always be told so.
        guard on else {
            write(sharing: false, through: store)
            return
        }
        // Switching it **on** requires an `auth_account_email` row, checked
        // here rather than only in whatever UI happens to be on screen.
        //
        // The daemon refuses every viewer whose relay-asserted account does
        // not match the `auth_account_email` row inside the account
        // directory it is serving (spec §9, `viewer_owns_this_account`), and
        // a *missing* row fails closed there like any other mismatch. So a
        // host with no row could switch sharing on, watch the menu bar go
        // green, and have every single connection refused — for a reason
        // stated nowhere near the switch. Making the switch itself refuse is
        // the only place that answer can be given before the fact.
        //
        // Re-read at write time rather than trusted from a cached restore:
        // signing in writes the row, and a stale "no" would outlive it.
        store.get(SettingsKey.authAccountEmail) { [weak self] result in
            guard let self else { return }
            let email = (try? result.get())??.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let email, !email.isEmpty else {
                onWriteFailed?(RemoteSharingModelError.signedOut)
                return
            }
            write(sharing: true, through: store)
        }
    }

    /// The write half of `setSharing`, once the decision is made.
    private func write(sharing on: Bool, through store: SettingsStore) {
        store.set(SettingsKey.remoteSharing, Self.encodeSharing(on)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                isSharing = on
                onChange?()
            case let .failure(error):
                onWriteFailed?(error)
            }
        }
    }

    /// The roster the daemon pushes (`RemoteViewers`), turned into the one
    /// reading of "somebody is driving this Mac right now".
    ///
    /// The daemon allows one remote connection at a time (spec §3), so the
    /// list is either empty or one entry; a longer one (a reconnect blip the
    /// registry has not reaped yet) takes the first, which is the oldest —
    /// `roster_of` sorts by connection time.
    ///
    /// Fires `onChange` only when the answer actually changed, so a roster
    /// push that reshuffles nothing does not re-present the panel.
    func applyRemoteViewers(_ viewers: [RemoteViewer]) {
        let live = viewers.first.map(RemoteConnectionInfo.init(viewer:))
        guard live != liveConnection else { return }
        liveConnection = live
        onChange?()
    }

    /// Re-reads `remote_control_blocked`. The daemon writes that row itself
    /// whenever a host presses **Block** (`DisconnectViewer(block: true)`),
    /// so the app's copy is stale the moment a block lands and Settings ›
    /// Remote would keep showing the old list until the next launch.
    func refreshBlockedList() {
        guard let store else { return }
        store.get(SettingsKey.remoteControlBlocked) { [weak self] result in
            guard let self, case let .success(raw) = result else { return }
            let ids = RemoteControlProjection.decodeEnabled(raw).sorted()
            guard ids != blockedViewerIDs else { return }
            blockedViewerIDs = ids
            onChange?()
        }
    }

    /// The production re-arm for a restore that failed.
    ///
    /// `configure(store:)` runs once, off `runWhenConnected`, so before this
    /// existed a single failed read after connect stranded `.shared` at its
    /// fail-closed defaults for the life of the process: sharing would read
    /// as off with no way back short of relaunching, and `restoreDispatched
    /// = false` in `restore()`'s failure arm had no trigger to re-arm *for*.
    /// `WorkspaceWindowController` now calls this on every `.connected`,
    /// which is exactly when a retry can succeed.
    ///
    /// A no-op once a restore has actually completed — a reconnect does not
    /// re-read rows this model already holds, and cannot race a write in
    /// flight.
    func connectionDidComeUp() {
        guard !restoreCompleted else { return }
        restoreDispatched = false
        restore()
    }

    /// Rewrites `remote_control_blocked` without `viewerID` — the only way
    /// the app ever removes an entry from it. A no-op, with no write and no
    /// `onChange`, when the id was not blocked to begin with.
    /// `blockedViewerIDs` changes only once the write actually lands; a
    /// failure leaves it exactly as it was and calls `onWriteFailed`.
    func unblock(_ viewerID: String) {
        guard blockedViewerIDs.contains(viewerID) else { return }
        guard let store else {
            onWriteFailed?(RemoteSharingModelError.notConfigured)
            return
        }
        var ids = Set(blockedViewerIDs)
        ids.remove(viewerID)
        let sorted = ids.sorted()
        store.set(SettingsKey.remoteControlBlocked, RemoteControlProjection.encodeEnabled(ids)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                blockedViewerIDs = sorted
                onChange?()
            case let .failure(error):
                onWriteFailed?(error)
            }
        }
    }

    /// Reads both rows, `remoteSharing` first then `remoteControlBlocked` —
    /// nested, `restoreRemoteControlIfNeeded`'s exact shape
    /// (`WorkspaceWindowController.swift`), so either failing re-arms the
    /// whole pair rather than leaving one half silently stale.
    ///
    /// No retry timer here (deleted 2026-09-01 — see `configure(store:)`'s
    /// doc comment): `configure(store:)` is only ever called once the
    /// connection is actually up, so the race a timer used to paper over no
    /// longer exists at the call site. A read that still fails resets
    /// `restoreDispatched` — `restoreRemoteControlIfNeeded`'s own re-arm,
    /// not a scheduled retry — so a future `configure(store:)`/`init(store:)`
    /// call can try again; nothing here retries on its own.
    private func restore() {
        guard let store, !restoreDispatched else { return }
        restoreDispatched = true
        store.get(SettingsKey.remoteSharing) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                isSharing = Self.decodeSharing(raw)
                onChange?()
                store.get(SettingsKey.remoteControlBlocked) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .success(raw):
                        blockedViewerIDs = RemoteControlProjection.decodeEnabled(raw).sorted()
                        restoreCompleted = true
                        onChange?()
                    case .failure:
                        restoreDispatched = false
                    }
                }
            case .failure:
                restoreDispatched = false
            }
        }
    }

    /// `{"enabled":true|false}`, exactly — no `JSONEncoder`, because the
    /// daemon's `remote_control_active` reads this row's bytes and the two
    /// sides must never drift over whitespace or key order neither one has
    /// a reason to introduce.
    private static func encodeSharing(_ enabled: Bool) -> String {
        "{\"enabled\":\(enabled)}"
    }

    /// The daemon's own decode, mirrored: absent, unreadable, or missing
    /// `enabled` all read as `false`. Fails closed, never open.
    private static func decodeSharing(_ raw: String?) -> Bool {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let enabled = object["enabled"] as? Bool
        else {
            return false
        }
        return enabled
    }
}

/// `setSharing`/`unblock` called before `.shared` has been
/// `configure(store:)`d — a real possibility only if something reaches for
/// `.shared` before `AppDelegate.applicationDidFinishLaunching` runs, which
/// nothing in this app currently does. Every other path (`init(store:)`)
/// always has a store.
enum RemoteSharingModelError: Error, LocalizedError {
    case notConfigured
    /// `setSharing(true)` with no `auth_account_email` row. Its message is
    /// the whole point of the case: the daemon's own refusal names the
    /// account check, which is nowhere near where the host would look.
    case signedOut

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OmniAgent is not connected to its daemon yet."
        case .signedOut:
            return "Sign in to OmniAgent before sharing this environment — "
                + "sharing lets other Macs signed in to your account use this one, "
                + "so there has to be an account first."
        }
    }
}

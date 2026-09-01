import Foundation

/// The machine-wide sharing switch (2026-09-01 remote environment sharing
/// spec §2): Settings › Remote and the menu bar dropdown both read and
/// write through this. Replaces the per-workspace **Enable Remote Control**
/// toggle `WorkspaceWindowController` used to own — sharing is now one
/// switch for the whole Mac, not a set of enabled workspaces
/// (`WorkspaceContextMenu`/`WorkspacesTree`'s globe are deleted with it).
///
/// Two rows, read once at construction and kept live from there:
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
@MainActor
final class RemoteSharingModel {
    /// `.shared`'s own connection, resolved to the same socket
    /// `AppDelegate` dials — but **not started**: nothing here calls
    /// `connect()`. `AppDelegate` owns the app's one real connection and its
    /// lifecycle (`docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`,
    /// "There is exactly one local connection"); wiring `.shared` into that
    /// lifecycle — or replacing this with the app's own connection object —
    /// is later work. Until then this fails closed exactly like an absent
    /// row would: an unconnected socket answers every read with a failure,
    /// which leaves `isSharing`/`blockedViewerIDs` at their safe defaults.
    static let shared = RemoteSharingModel(
        store: SettingsStore(
            client: SessionConnection(
                socketURL: DaemonPaths.resolve(
                    channel: DaemonBuildChannel.resolve(bundleIdentifier: Bundle.main.bundleIdentifier)
                ).socketURL
            )
        )
    )

    private(set) var isSharing = false
    private(set) var blockedViewerIDs: [String] = []
    /// Fires whenever either row changes — the menu bar icon and Settings ›
    /// Remote both redraw off this rather than polling.
    var onChange: (() -> Void)?

    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
        restore()
    }

    /// Turns sharing on or off. Writes only `remote_sharing` — the blocked
    /// list is untouched (see the type's own doc comment above).
    func setSharing(_ on: Bool) {
        isSharing = on
        store.set(SettingsKey.remoteSharing, Self.encodeSharing(on))
        onChange?()
    }

    /// Rewrites `remote_control_blocked` without `viewerID` — the only way
    /// the app ever removes an entry from it. A no-op, with no write and no
    /// `onChange`, when the id was not blocked to begin with.
    func unblock(_ viewerID: String) {
        var ids = Set(blockedViewerIDs)
        guard ids.remove(viewerID) != nil else { return }
        blockedViewerIDs = ids.sorted()
        store.set(SettingsKey.remoteControlBlocked, RemoteControlProjection.encodeEnabled(ids))
        onChange?()
    }

    private func restore() {
        store.get(SettingsKey.remoteSharing) { [weak self] result in
            guard let self, case let .success(raw) = result else { return }
            isSharing = Self.decodeSharing(raw)
            onChange?()
        }
        store.get(SettingsKey.remoteControlBlocked) { [weak self] result in
            guard let self, case let .success(raw) = result else { return }
            blockedViewerIDs = RemoteControlProjection.decodeEnabled(raw).sorted()
            onChange?()
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

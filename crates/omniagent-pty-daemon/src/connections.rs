//! The daemon's per-connection registry — its first per-connection state
//! (`docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md`
//! §5 "Presence, and disconnecting a viewer").
//!
//! Bruno's finding 4: when his second Mac connects, nothing on the host shows
//! it and there is no way to end the connection. The daemon could not tell
//! anyone, because every push it made went through a *per-attachment* writer
//! cloned into `forward_events` — nothing anywhere knew that a connection
//! existed, let alone who was on the other end of it. This module is the
//! smallest thing that fixes that: one entry per live connection, holding who
//! it says it is, what it is attached to, the writer to reach it, and the
//! token that ends it.
//!
//! It is deliberately small, and deliberately not an authorization boundary —
//! `authorize_remote` in `server.rs` remains the trust gate. What lives here
//! is presence (who is watching) and the kick (stop watching, now).

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::SystemTime;

use tokio_util::sync::CancellationToken;

use crate::protocol::{
    write_frame, Frame, MessageKind, RemoteViewersPayload, ViewerSummaryPayload,
};
use crate::server::{ClientTrust, SharedWriter};

/// What a viewer calls itself in `Hello` (spec §5).
///
/// **Self-reported, on purpose.** Both Macs belong to the same account and the
/// relay already refuses anyone else, so this is a labelling and convenience
/// mechanism, not an authorization boundary. Making it tamper-proof means
/// having the relay assert identity in its `{"open": …}` message; that is a
/// later hardening, recorded rather than papered over.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ViewerIdentity {
    pub viewer_id: String,
    pub machine_name: String,
}

/// One live client connection.
pub struct ConnectionEntry {
    pub trust: ClientTrust,
    pub viewer: Option<ViewerIdentity>,
    /// The session ids this connection is attached to right now.
    pub attached: HashSet<String>,
    pub writer: SharedWriter,
    /// Cancelled by [`ConnectionRegistry::cancel_viewer`]; `serve_client`
    /// races its read loop against it, so a kick drops the socket at once
    /// rather than at the viewer's next frame.
    pub cancel: CancellationToken,
    pub since: SystemTime,
}

impl ConnectionEntry {
    /// Whether this connection appears in the roster a host is shown.
    ///
    /// A remote connection that never named itself is deliberately *not*
    /// listed: it can only come from a viewer app older than phase 2, and
    /// every roster entry carries a Disconnect that has to hold — which means
    /// blocking a stable viewer id, which such a client does not have.
    fn is_listed_viewer(&self) -> bool {
        self.trust == ClientTrust::Remote && self.viewer.is_some()
    }
}

/// Every live connection, by id. Cloned into each [`crate::ClientContext`].
#[derive(Clone, Default)]
pub struct ConnectionRegistry {
    entries: Arc<Mutex<HashMap<u64, ConnectionEntry>>>,
    next_id: Arc<AtomicU64>,
    /// Serializes roster pushes against each other.
    ///
    /// Without it two connections changing presence at the same instant can
    /// each snapshot a roster and then interleave their writes, leaving a host
    /// holding the *older* of the two until the next change — a stale roster
    /// that nothing corrects. Held across the whole push, so the last snapshot
    /// taken is also the last one written.
    broadcast: Arc<tokio::sync::Mutex<()>>,
}

impl ConnectionRegistry {
    /// A poisoned lock still holds the truth about who is connected; a panic
    /// while mutating this map would otherwise take out presence for the life
    /// of the daemon, and the map's invariants are just "these entries exist".
    fn entries(&self) -> MutexGuard<'_, HashMap<u64, ConnectionEntry>> {
        self.entries
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn register(
        &self,
        trust: ClientTrust,
        writer: SharedWriter,
        cancel: CancellationToken,
    ) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.entries().insert(
            id,
            ConnectionEntry {
                trust,
                viewer: None,
                attached: HashSet::new(),
                writer,
                cancel,
                since: SystemTime::now(),
            },
        );
        id
    }

    /// Returns whether this removed a connection a host could see — i.e.
    /// whether the roster just changed. Removing an id twice is harmless.
    pub fn remove(&self, id: u64) -> bool {
        self.entries()
            .remove(&id)
            .is_some_and(|entry| entry.is_listed_viewer())
    }

    /// Returns whether the roster changed.
    pub fn set_viewer(&self, id: u64, viewer: ViewerIdentity) -> bool {
        let mut entries = self.entries();
        let Some(entry) = entries.get_mut(&id) else {
            return false;
        };
        entry.viewer = Some(viewer);
        entry.is_listed_viewer()
    }

    /// Returns whether the roster changed — `false` when the set is the same
    /// as before, so the common case (a frame that attaches nothing) costs no
    /// push.
    pub fn set_attached(&self, id: u64, attached: HashSet<String>) -> bool {
        let mut entries = self.entries();
        let Some(entry) = entries.get_mut(&id) else {
            return false;
        };
        if entry.attached == attached {
            return false;
        }
        entry.attached = attached;
        entry.is_listed_viewer()
    }

    /// The roster: one entry per **machine**, ordered oldest first.
    ///
    /// Grouped by viewer id rather than by connection, because a machine can
    /// briefly hold two — the relay opens a fresh data socket when a viewer
    /// re-dials, and the old one is not reaped until its read fails. Listing
    /// that twice would show Bruno "Air" and "Air", each with half the panes,
    /// and two Disconnect buttons for one machine that
    /// [`Self::cancel_viewer`] already treats as one. The panes are unioned
    /// and the earliest connection time wins.
    ///
    /// Sorted, and the sessions with it, rather than left in `HashMap`/
    /// `HashSet` order — successive pushes would otherwise reshuffle the
    /// host's list under the pointer.
    pub fn viewers(&self) -> Vec<ViewerSummaryPayload> {
        let mut machines: HashMap<String, (String, SystemTime, BTreeSet<String>)> = HashMap::new();
        for entry in self.entries().values() {
            let Some(viewer) = entry.viewer.as_ref().filter(|_| entry.is_listed_viewer()) else {
                continue;
            };
            let machine = machines
                .entry(viewer.viewer_id.clone())
                .or_insert_with(|| (viewer.machine_name.clone(), entry.since, BTreeSet::new()));
            machine.1 = machine.1.min(entry.since);
            machine.2.extend(entry.attached.iter().cloned());
        }
        let mut viewers: Vec<_> = machines
            .into_iter()
            .map(
                |(viewer_id, (machine_name, since, sessions))| ViewerSummaryPayload {
                    viewer_id,
                    machine_name,
                    sessions: sessions.into_iter().collect(),
                    since: rfc3339(since),
                },
            )
            .collect();
        viewers.sort_by(|a, b| {
            a.since
                .cmp(&b.since)
                .then_with(|| a.viewer_id.cmp(&b.viewer_id))
        });
        viewers
    }

    /// The writers of every **local** connection — the only ones a roster is
    /// ever sent to (spec §7 invariant 3).
    pub fn local_writers(&self) -> Vec<SharedWriter> {
        self.entries()
            .values()
            .filter(|entry| entry.trust == ClientTrust::Local)
            .map(|entry| Arc::clone(&entry.writer))
            .collect()
    }

    /// Drops every connection with this viewer id, returning whether there was
    /// one. The entries go here, not when each `serve_client` notices its
    /// token — so the roster pushed straight after a kick is already correct.
    pub fn cancel_viewer(&self, viewer_id: &str) -> bool {
        let mut entries = self.entries();
        let kicked: Vec<u64> = entries
            .iter()
            .filter(|(_, entry)| {
                entry
                    .viewer
                    .as_ref()
                    .is_some_and(|viewer| viewer.viewer_id == viewer_id)
            })
            .map(|(id, _)| *id)
            .collect();
        for id in &kicked {
            if let Some(entry) = entries.remove(id) {
                entry.cancel.cancel();
            }
        }
        !kicked.is_empty()
    }

    /// Sends the current roster to every local connection.
    ///
    /// The one place `RemoteViewers` is written, so "local connections only"
    /// is a property of a single function rather than of every call site. A
    /// write that fails is ignored: that connection is going away, and its
    /// own dispatch loop is what notices.
    pub async fn broadcast_presence(&self) {
        let _serialize = self.broadcast.lock().await;
        let (viewers, writers) = (self.viewers(), self.local_writers());
        if writers.is_empty() {
            return;
        }
        let Ok(payload) = serde_json::to_vec(&RemoteViewersPayload { viewers }) else {
            return;
        };
        // A push, so the header carries a sequence rather than a request id,
        // and there is no request this answers.
        let frame = Frame::new(MessageKind::RemoteViewers, 0, payload);
        for writer in writers {
            let _ = write_frame(&mut *writer.lock().await, &frame).await;
        }
    }
}

fn rfc3339(at: SystemTime) -> String {
    chrono::DateTime::<chrono::Utc>::from(at).to_rfc3339()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn writer() -> SharedWriter {
        Arc::new(tokio::sync::Mutex::new(Box::new(tokio::io::sink())))
    }

    fn viewer(id: &str, name: &str) -> ViewerIdentity {
        ViewerIdentity {
            viewer_id: id.into(),
            machine_name: name.into(),
        }
    }

    fn attached(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|id| (*id).to_string()).collect()
    }

    /// Who is listed, and who is not: local connections are hosts rather than
    /// viewers, and a remote connection that never named itself cannot be
    /// offered a Disconnect that holds, so neither appears.
    #[test]
    fn only_remote_connections_that_named_themselves_are_listed() {
        let registry = ConnectionRegistry::default();
        let host = registry.register(ClientTrust::Local, writer(), CancellationToken::new());
        let anonymous = registry.register(ClientTrust::Remote, writer(), CancellationToken::new());
        let air = registry.register(ClientTrust::Remote, writer(), CancellationToken::new());

        // A local connection may carry an identity; it is still not a viewer.
        assert!(!registry.set_viewer(host, viewer("v-host", "Studio")));
        assert!(registry.set_viewer(air, viewer("v-air", "Air")));
        registry.set_attached(anonymous, attached(&["s9"]));

        let viewers = registry.viewers();
        assert_eq!(viewers.len(), 1);
        assert_eq!(viewers[0].viewer_id, "v-air");
        assert_eq!(registry.local_writers().len(), 1);
    }

    /// One machine, two sockets — the relay opens a fresh data connection when
    /// a viewer re-dials, and the old one lives until its read fails.
    #[test]
    fn two_connections_from_one_machine_are_one_roster_entry() {
        let registry = ConnectionRegistry::default();
        let old = registry.register(ClientTrust::Remote, writer(), CancellationToken::new());
        let new = registry.register(ClientTrust::Remote, writer(), CancellationToken::new());
        registry.set_viewer(old, viewer("v-air", "Air"));
        registry.set_viewer(new, viewer("v-air", "Air"));
        registry.set_attached(old, attached(&["s2"]));
        registry.set_attached(new, attached(&["s1"]));

        let viewers = registry.viewers();
        assert_eq!(viewers.len(), 1, "one machine is one row");
        assert_eq!(viewers[0].sessions, ["s1".to_string(), "s2".to_string()]);

        // And one Disconnect ends both, which is why they are one row.
        assert!(registry.cancel_viewer("v-air"));
        assert!(registry.viewers().is_empty());
        assert!(!registry.cancel_viewer("v-air"), "nothing left to kick");
    }

    /// The push-on-change rule: only a change a host can see is worth a frame.
    #[test]
    fn only_changes_a_host_can_see_report_true() {
        let registry = ConnectionRegistry::default();
        let air = registry.register(ClientTrust::Remote, writer(), CancellationToken::new());
        registry.set_viewer(air, viewer("v-air", "Air"));

        assert!(registry.set_attached(air, attached(&["s1"])));
        assert!(
            !registry.set_attached(air, attached(&["s1"])),
            "the same set again is not a change"
        );
        assert!(registry.set_attached(air, attached(&[])));
        assert!(registry.remove(air));
        assert!(!registry.remove(air), "removing twice is harmless");
        assert!(
            !registry.set_attached(air, attached(&["s1"])),
            "a connection that is gone cannot change anything"
        );
    }
}

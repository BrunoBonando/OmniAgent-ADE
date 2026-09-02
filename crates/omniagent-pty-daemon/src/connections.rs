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
//! it says it is, what it is attached to, and the token that ends it.
//!
//! **The registry holds no writers and does no I/O.** The roster is published
//! into a `watch` channel — a synchronous, non-blocking, latest-wins handoff —
//! and each *local* connection owns a [`PresenceFeed`] task that writes what it
//! finds there to its own socket. That is deliberate and structural: a client
//! that stops draining its socket can only ever stall its own feed task, because
//! no code path inside the registry, or inside anyone else's dispatch loop, can
//! reach that client's writer at all.
//!
//! It is deliberately small, and deliberately not an authorization boundary —
//! `authorize_remote` in `server.rs` remains the trust gate. What lives here
//! is presence (who is watching) and the kick (stop watching, now).

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::SystemTime;

use tokio::sync::watch;
use tokio::task::JoinHandle;
// `tokio`'s clock rather than `std`'s, so the sharing grace
// (`server::sharing_should_be_live`) can be moved by `tokio::time::advance`
// in tests instead of by sleeping through it.
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::activity::{ActivityEntry, RemoteActivityPayload};
use crate::protocol::{
    write_frame, Frame, MessageKind, RemoteViewersPayload, ViewerSummaryPayload,
};
use crate::server::{ClientTrust, SharedWriter};

/// What a viewer calls itself in `Hello` (spec §5).
///
/// **Self-reported, and this type holds nothing else.** Everything in here
/// arrived in the connecting client's own `Hello` payload, so it is a label
/// for a human to read and never an input to a decision. The trusted half —
/// what Cloudflare and the relay *observed* — is [`AssertedIdentity`], and it
/// deliberately does not live in this struct: a check written against
/// `viewer.account_email` would be a check whose input the caller chooses, and
/// the way to make that impossible is for there to be no such field to reach
/// for. The assertion rides [`ClientTrust::Remote`] instead, which is to say it
/// arrives *with the connection* rather than in the client's first frame.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ViewerIdentity {
    pub viewer_id: String,
    pub machine_name: String,
}

/// What the **relay** says about a connection, carried on the control
/// channel's `{"open": "<conn_id>", "viewer": {…}}` message (spec §9).
///
/// The split from [`ViewerIdentity`] is the whole point of the type. These
/// fields are observations, not claims: `ip` is Cloudflare's
/// `CF-Connecting-IP` and `country` its `CF-IPCountry`, neither settable by
/// the client; `user_sub` and `account_email` come from the viewer's JWT,
/// which the relay verified before it opened anything. **Only these fields may
/// be read by a check.** Anything the connecting app says about itself lands
/// in `ViewerIdentity`, and a check run on a value the connecting client
/// supplies checks nothing.
///
/// Every field is optional because the relay omits what it does not know
/// rather than inventing it (spec §9: "City is omitted, not faked"), and
/// unknown keys are ignored so the relay may add to the dictionary without a
/// daemon release. An assertion with no `account_email` therefore exists, and
/// [`crate::server::viewer_owns_this_account`] refuses it — absence fails
/// closed rather than defaulting to anything.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Deserialize)]
#[serde(default)]
pub struct AssertedIdentity {
    /// The viewer's account, from the JWT the relay verified.
    pub user_sub: Option<String>,
    /// The email that account signs in with — the one fact the daemon's
    /// account check runs on ([`crate::server::viewer_owns_this_account`]).
    pub account_email: Option<String>,
    /// `CF-Connecting-IP` at the edge.
    pub ip: Option<String>,
    /// `CF-IPCountry` at the edge.
    pub country: Option<String>,
    /// The viewer app's user agent, as the relay saw it.
    pub client: Option<String>,
}

impl AssertedIdentity {
    /// Whether the relay says these two connections belong to the same
    /// person — the gate on [`LeaseHolder::is_the_same_viewer_as`].
    ///
    /// `user_sub` when the relay sent one, else the normalized
    /// `account_email`; a pair that agrees on neither is not the same person,
    /// so this fails closed. `ip`, `country` and `client` are deliberately
    /// **not** compared: they are precisely the fields a reconnect changes —
    /// a viewer that came back on another network is the case this exists for.
    fn is_the_same_account_as(&self, other: &Self) -> bool {
        match (&self.user_sub, &other.user_sub) {
            (Some(mine), Some(theirs)) => !mine.is_empty() && mine == theirs,
            (None, None) => match (&self.account_email, &other.account_email) {
                (Some(mine), Some(theirs)) => {
                    !mine.trim().is_empty() && mine.trim().eq_ignore_ascii_case(theirs.trim())
                }
                _ => false,
            },
            _ => false,
        }
    }
}

/// Who holds the lease (spec §3) — deliberately *not* a [`ViewerIdentity`].
///
/// A remote client older than phase 2 sends no `viewer_id` at all, and it can
/// still take the lease: it is one machine driving this one, which is the only
/// thing the lease is about. But it cannot be kicked by id, because there is
/// no id — [`ConnectionRegistry::cancel_viewer`] matches on the identity a
/// connection registered, and that connection registered none.
///
/// So the absence is in the type. A holder's `viewer_id` is `Option`, and the
/// host's Terminate button has to face that before it can call
/// `cancel_viewer`. Storing `""` instead would have type-checked and then
/// no-opped silently at the one moment a host most wants the button to work.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LeaseHolder {
    /// `None` for a client that never named itself in `Hello`. Self-reported.
    pub viewer_id: Option<String>,
    /// Self-reported. A label for the host's panel, never a decision input.
    pub machine_name: String,
    /// What the relay asserted about the connection holding the lease — the
    /// trusted half, kept here because this record is what the host's takeover
    /// panel is drawn from and what `server.rs` compares a returning viewer
    /// against. A lease is only ever taken by a `ClientTrust::Remote`
    /// connection, which by construction has one, so this is not an `Option`:
    /// there is no way to record a holder whose identity nobody asserted.
    pub asserted: AssertedIdentity,
}

impl LeaseHolder {
    /// Whether `candidate` is **this same viewer coming back** — the one case
    /// in which the machine changes hands without the host doing anything
    /// (spec §11, "Viewer link drops mid-session").
    ///
    /// A viewer whose link blips re-dials onto a fresh relay data socket while
    /// the relay is still holding the old one. Without this it is told "in use
    /// by <itself>" and has to wait its own corpse out.
    ///
    /// **The gate is the relay-asserted account**, which is the half no client
    /// can forge; the self-reported `viewer_id` then says *which machine*
    /// within that account. Consulting a self-reported field at all is safe
    /// only because of what has already happened by the time this runs:
    /// `server::viewer_owns_this_account` refuses every connection whose
    /// asserted account is not the one this daemon serves, so both sides of
    /// this comparison are the same person, and the worst a forged id can do
    /// is let the owner's second Mac take over from the owner's first. It
    /// cannot cross an account boundary, which is the boundary that matters.
    ///
    /// It is *not* keyed on `machine_name`: names are not unique and nothing
    /// stops two machines sharing one. Both ids must be present and equal, so
    /// an anonymous viewer (a pre-phase-2 app, no id at all) never reclaims
    /// and is refused like any other second machine.
    ///
    /// The durable fix is for the relay to assert a per-viewer identifier of
    /// its own; §9's `viewer` dictionary has none today, and inventing one
    /// daemon-side would be inventing it out of client-supplied data.
    fn is_the_same_viewer_as(&self, candidate: &Self) -> bool {
        self.asserted.is_the_same_account_as(&candidate.asserted)
            && match (&self.viewer_id, &candidate.viewer_id) {
                (Some(mine), Some(theirs)) => !mine.is_empty() && mine == theirs,
                _ => false,
            }
    }
}

/// One live client connection.
///
/// Note what is *not* here: the connection's writer. Presence reaches a client
/// through its own [`PresenceFeed`], so the registry never holds an I/O handle
/// and a slow socket is unreachable from inside its lock.
pub struct ConnectionEntry {
    pub trust: ClientTrust,
    pub viewer: Option<ViewerIdentity>,
    /// The session ids this connection is attached to right now.
    pub attached: HashSet<String>,
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
        self.trust.is_remote() && self.viewer.is_some()
    }
}

/// Every live connection, by id. Cloned into each [`crate::ClientContext`].
///
/// **Three locks, and one strict order.** `entries`, `lease` and
/// `local_gone_since` are separate mutexes. `lease` is never held with either
/// of the others — [`Self::take_lease`] touches only the lease,
/// [`Self::remove`] releases it before it locks the entries map, and
/// [`Self::cancel_viewer`] drops its guard before it releases. `entries` may
/// be held while taking `local_gone_since` (that is [`Self::remove`], which
/// has to change both in one section) and **never the reverse**: the readers
/// of `local_gone_since` take nothing else.
#[derive(Clone)]
pub struct ConnectionRegistry {
    entries: Arc<Mutex<HashMap<u64, ConnectionEntry>>>,
    next_id: Arc<AtomicU64>,
    /// The remote connection currently driving this machine, if any (spec §3
    /// "The lease", §12 invariant 4) — its connection id and who it says it
    /// is.
    ///
    /// The id is half the value: [`Self::release_lease`] clears the lease only
    /// when it matches, so a release arriving late from a connection that has
    /// already died cannot evict the viewer that took the lease after it.
    lease: Arc<Mutex<Option<(u64, LeaseHolder)>>>,
    /// When the last [`ClientTrust::Local`] connection went away — the clock
    /// the sharing grace runs on (`server::sharing_should_be_live`).
    ///
    /// `None` means *either* "a local connection is attached" *or* "none ever
    /// has been", and no caller has to tell those apart: [`Self::has_local`]
    /// is asked first and short-circuits the first case, while the second is
    /// a daemon whose app has not started yet, which shares nothing anyway.
    local_gone_since: Arc<Mutex<Option<Instant>>>,
    /// The current roster. `watch` is exactly the right shape for presence:
    /// publishing never blocks and never fails, and a receiver always observes
    /// the **latest** roster rather than a queue of superseded ones. Two rapid
    /// changes may collapse into one frame, which is correct — a roster is a
    /// statement of the present, not an event log.
    roster: Arc<watch::Sender<Arc<RemoteViewersPayload>>>,
    /// The daemon-lifetime activity history (Task 19, spec §8) — published
    /// through a `watch` channel exactly like [`Self::roster`] and for the
    /// same reason: publishing must never be able to block on a slow local
    /// reader, and giving every local connection its own feed task
    /// ([`ActivityFeed::spawn`]) is what makes that structural rather than
    /// merely likely.
    ///
    /// **Unlike the roster, this is not "the present," and [`Self::notify_activity`]
    /// does not simply replace it.** A roster genuinely is the current state,
    /// so overwriting it on every publish is correct — a `watch` receiver
    /// that misses an intermediate value has missed nothing, because the
    /// *latest* roster is the only one that was ever true. An activity row is
    /// an event, not a state: overwriting the same way would mean two
    /// publishes landing before an `ActivityFeed` task gets scheduled between
    /// them silently erases the first one, which is exactly the failure mode
    /// this file's own doc comment warns a naive copy of `PresenceFeed` would
    /// have. So `notify_activity` *extends* [`ActivityHistory::entries`]
    /// instead, and each feed tracks how much of it it has already forwarded
    /// by a monotonic index rather than a length — see
    /// [`ActivityFeed::spawn`].
    activity: Arc<watch::Sender<Arc<ActivityHistory>>>,
}

/// The cap on [`ActivityHistory::entries`] — bounds this registry's memory
/// over a long-lived daemon (this channel's lifetime is the whole process,
/// spanning however many remote connections come and go, not one connection),
/// generous enough that a real local reader (draining every 30s scheduling
/// beat while a session is live) never comes close to it. Losing entries to a
/// trim requires a local reader that has fallen behind by this many rows
/// without ever draining — the same class of "this reader is broken, not the
/// stream" accepted for session output's own `CLIENT_QUEUE_CAPACITY` +
/// `ResyncRequired`. The durable `remote-activity.jsonl` file
/// ([`crate::append`]) is unaffected either way: it is written before this
/// channel is ever touched, from every entry `record` produces, independent
/// of whether any local reader is even attached.
const ACTIVITY_HISTORY_CAP: usize = 1000;

/// The value inside [`ConnectionRegistry`]'s activity `watch` channel. See
/// the field's own doc for why this is an ever-growing, capped log rather
/// than a value [`ConnectionRegistry::notify_activity`] simply replaces.
/// `pub(crate)` rather than private: `server.rs`'s `serve_client` is the
/// caller that hands the subscribed receiver to [`ActivityFeed::spawn`], so
/// the receiver's type has to name this — but it never reaches outside this
/// crate, since `mod connections;` in `lib.rs` is not `pub`.
#[derive(Debug, Clone, Default)]
pub(crate) struct ActivityHistory {
    /// How many entries have ever been dropped off the front by the cap —
    /// what turns "how many entries are in `entries` right now" into a
    /// *global*, never-reused index ([`ActivityFeed::spawn`]'s `next`), so a
    /// trim can never make a feed re-send or silently skip something.
    trimmed: usize,
    entries: Vec<ActivityEntry>,
}

impl Default for ConnectionRegistry {
    fn default() -> Self {
        let (roster, _) = watch::channel(Arc::new(RemoteViewersPayload {
            viewers: Vec::new(),
        }));
        let (activity, _) = watch::channel(Arc::new(ActivityHistory::default()));
        Self {
            entries: Arc::default(),
            next_id: Arc::default(),
            lease: Arc::default(),
            local_gone_since: Arc::default(),
            roster: Arc::new(roster),
            activity: Arc::new(activity),
        }
    }
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

    /// Same reasoning as [`Self::entries`], and one more: a poisoned lease
    /// lock that stayed poisoned would refuse every viewer for the life of the
    /// daemon, which is the exact failure the lease is meant not to have.
    fn lease(&self) -> MutexGuard<'_, Option<(u64, LeaseHolder)>> {
        self.lease
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Same reasoning as [`Self::entries`]: a poisoned lock still holds the
    /// truth, and this one decides whether the machine is shared at all.
    fn local_gone(&self) -> MutexGuard<'_, Option<Instant>> {
        self.local_gone_since
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Whether the host's own app is attached right now — spec §2 condition 3,
    /// the "icon in the menu bar" rule.
    ///
    /// A `Local` entry is a connection that came through the unix socket's
    /// peer-UID check, which is to say the app on this Mac. Nothing else can
    /// produce one: a relayed client is [`ClientTrust::Remote`] by
    /// construction, so this cannot be satisfied from the other end of the
    /// relay.
    pub fn has_local(&self) -> bool {
        self.entries().values().any(|entry| entry.trust.is_local())
    }

    /// When the last local connection went away, for the grace that
    /// [`crate::sharing_should_be_live`] applies to [`Self::has_local`].
    /// `None` while one is attached, and while none ever has been.
    pub fn local_gone_since(&self) -> Option<Instant> {
        *self.local_gone()
    }

    /// Claims the machine for this connection.
    ///
    /// - `Ok(None)` — the lease was free and is now this connection's.
    /// - `Ok(Some(stale))` — the **same viewer** already held it and this
    ///   connection has taken it over; `stale` is the connection id the caller
    ///   must now cancel, because it is a socket that will otherwise sit there
    ///   attached to sessions the returning viewer is driving. See
    ///   [`LeaseHolder::is_the_same_viewer_as`] for why "same viewer" is what
    ///   the relay asserted and not what anyone claimed.
    /// - `Err(machine_name)` — a different machine is driving, named so the
    ///   refusal is a sentence a human can act on.
    ///
    /// Exclusivity is the check and the write happening under one guard — two
    /// remote `Hello`s racing cannot both come back with the machine. The
    /// caller passes the holder rather than the registry looking it up, so
    /// this touches one lock and so that the lease can be taken *before* a
    /// connection is put on the roster (see `serve_client`).
    pub fn take_lease(&self, id: u64, holder: LeaseHolder) -> Result<Option<u64>, String> {
        let mut lease = self.lease();
        match lease.as_ref() {
            Some((stale, held)) if held.is_the_same_viewer_as(&holder) => {
                let stale = *stale;
                *lease = Some((id, holder));
                Ok(Some(stale))
            }
            Some((_, held)) => Err(held.machine_name.clone()),
            None => {
                *lease = Some((id, holder));
                Ok(None)
            }
        }
    }

    /// Drops one connection by id, cancelling it — the reclaim's other half.
    /// Returns whether the roster changed.
    ///
    /// **Remote only**, for the same structural reason [`Self::cancel_viewer`]
    /// is: nothing in this family may reach the host's own app, and the
    /// local-absence clock that [`Self::remove`] keeps is not this function's
    /// to maintain. A remote entry never touches it.
    ///
    /// The lease is deliberately left alone. The only caller has just taken it
    /// for *itself*, and `release_lease` matches on the holder id, so calling
    /// it here would be a no-op with a misleading name.
    pub fn cancel_connection(&self, id: u64) -> bool {
        let mut entries = self.entries();
        if !entries
            .get(&id)
            .is_some_and(|entry| entry.trust.is_remote())
        {
            return false;
        }
        entries
            .remove(&id)
            .map(|entry| {
                entry.cancel.cancel();
                entry.is_listed_viewer()
            })
            .unwrap_or(false)
    }

    /// Frees the lease **if this connection is the one holding it**.
    ///
    /// The id check is not defensive tidiness. A connection that is torn down
    /// late — a kicked viewer whose task unwinds after the host let the next
    /// machine in — would otherwise release a lease it no longer owns and
    /// evict a live viewer. Releasing an id that holds nothing is a no-op, so
    /// every exit path may call this unconditionally.
    pub fn release_lease(&self, id: u64) {
        let mut lease = self.lease();
        if lease.as_ref().is_some_and(|(holder, _)| *holder == id) {
            *lease = None;
        }
    }

    /// Who is driving this machine, if anyone.
    pub fn lease_holder(&self) -> Option<LeaseHolder> {
        self.lease().as_ref().map(|(_, holder)| holder.clone())
    }

    pub fn register(&self, trust: ClientTrust, cancel: CancellationToken) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let is_local = trust.is_local();
        self.entries().insert(
            id,
            ConnectionEntry {
                trust,
                viewer: None,
                attached: HashSet::new(),
                cancel,
                since: SystemTime::now(),
            },
        );
        if is_local {
            // The app is back, so there is no absence to time. Clearing is not
            // load-bearing — `has_local` is asked first and would short-circuit
            // a stale timestamp — but a marker that outlived what it recorded
            // is a trap for the next reader.
            *self.local_gone() = None;
        }
        id
    }

    /// Returns whether this removed a connection a host could see — i.e.
    /// whether the roster just changed. Removing an id twice is harmless.
    ///
    /// The lease goes with the entry. Putting it here rather than at the call
    /// site is what makes "the lease is always released" structural: there is
    /// no way to take a connection out of this registry that leaves it
    /// holding the machine.
    ///
    /// The grace clock starts here too, for the same reason: the moment the
    /// host's *last* local connection leaves this map is the moment sharing
    /// has a deadline on it, and there is no other way out of the map.
    pub fn remove(&self, id: u64) -> bool {
        self.release_lease(id);
        let mut entries = self.entries();
        let removed = entries.remove(&id);
        let was_local = removed.as_ref().is_some_and(|entry| entry.trust.is_local());
        if was_local && !entries.values().any(|entry| entry.trust.is_local()) {
            // Under the entries guard on purpose: "no local is left" and "the
            // absence started now" have to become true together, or a local
            // connection arriving in between would leave behind a timestamp
            // for an absence that never happened.
            *self.local_gone() = Some(Instant::now());
        }
        removed.is_some_and(|entry| entry.is_listed_viewer())
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
        Self::roster_of(&self.entries())
    }

    /// [`Self::viewers`], but off a guard the caller already holds — so a
    /// snapshot and the publish that follows it can be one atomic section.
    fn roster_of(entries: &HashMap<u64, ConnectionEntry>) -> Vec<ViewerSummaryPayload> {
        struct Machine {
            machine_name: String,
            since: SystemTime,
            sessions: BTreeSet<String>,
            /// The assertion carried by the **oldest** of this machine's
            /// connections — the same one `since` is taken from, so the two
            /// halves of the row describe one connection rather than a
            /// composite of two. A machine holds more than one only across a
            /// reconnect blip, where both assertions name the same account
            /// anyway; picking deterministically is what stops the row
            /// flickering between them.
            asserted: AssertedIdentity,
        }
        let mut machines: HashMap<String, Machine> = HashMap::new();
        for entry in entries.values() {
            let Some(viewer) = entry.viewer.as_ref().filter(|_| entry.is_listed_viewer()) else {
                continue;
            };
            let asserted = entry.trust.asserted().cloned().unwrap_or_default();
            let machine = machines
                .entry(viewer.viewer_id.clone())
                .or_insert_with(|| Machine {
                    machine_name: viewer.machine_name.clone(),
                    since: entry.since,
                    sessions: BTreeSet::new(),
                    asserted: asserted.clone(),
                });
            if entry.since < machine.since {
                machine.since = entry.since;
                machine.asserted = asserted;
            }
            machine.sessions.extend(entry.attached.iter().cloned());
        }
        let mut viewers: Vec<_> = machines
            .into_iter()
            .map(|(viewer_id, machine)| ViewerSummaryPayload {
                viewer_id,
                machine_name: machine.machine_name,
                sessions: machine.sessions.into_iter().collect(),
                since: rfc3339(machine.since),
                account_email: machine.asserted.account_email,
                ip: machine.asserted.ip,
                country: machine.asserted.country,
                client: machine.asserted.client,
            })
            .collect();
        viewers.sort_by(|a, b| {
            a.since
                .cmp(&b.since)
                .then_with(|| a.viewer_id.cmp(&b.viewer_id))
        });
        viewers
    }

    /// Publishes the current roster to every local connection's feed.
    ///
    /// Synchronous and non-blocking by construction: it hands a value to a
    /// `watch` channel and returns. Nothing here can wait on a client, so no
    /// connection — local or remote — can have its presence bookkeeping, or
    /// its attach/detach dispatch, held up by a peer that has stopped reading.
    ///
    /// **Snapshot and publish happen together, under the entries lock.** They
    /// used to be two steps with the lock dropped in between, which let two
    /// concurrent publishers — the realistic pair being a dying socket's
    /// removal racing its replacement's attach during a reconnect — read in
    /// one order and publish in the other, leaving the channel's *final*
    /// value the older roster until something else changed. Holding the guard
    /// across `send_replace` makes the section atomic, so the last value
    /// published is always the newest state read. Both halves are synchronous
    /// and non-blocking, and no watch receiver ever calls back into the
    /// registry, so there is no lock cycle to deadlock on.
    ///
    /// Delivery to each feed remains latest-wins: a receiver observes the
    /// current roster, not a backlog, and rapid changes may collapse into one
    /// frame.
    pub fn notify_presence(&self) {
        let entries = self.entries();
        let roster = Arc::new(RemoteViewersPayload {
            viewers: Self::roster_of(&entries),
        });
        self.roster.send_replace(roster);
        drop(entries);
    }

    /// The roster feed for one connection, or `None` when it must never have
    /// one.
    ///
    /// Spec §7 invariant 3 — `RemoteViewers` goes to local connections only, a
    /// viewer never learns about other viewers — lives here, in the one place
    /// that hands out access to the roster, rather than at each call site.
    pub fn presence_updates(
        &self,
        trust: &ClientTrust,
    ) -> Option<watch::Receiver<Arc<RemoteViewersPayload>>> {
        trust.is_local().then(|| self.roster.subscribe())
    }

    /// Extends the activity history with everything one frame, or one
    /// [`crate::ActivityLog::tick`], produced — never replaces it (see the
    /// field's own doc for why). A no-op for an empty batch: nothing
    /// happened, so there is nothing to append or announce.
    pub fn notify_activity(&self, new_entries: Vec<ActivityEntry>) {
        if new_entries.is_empty() {
            return;
        }
        let mut history = self.activity.borrow().as_ref().clone();
        history.entries.extend(new_entries);
        if history.entries.len() > ACTIVITY_HISTORY_CAP {
            let overflow = history.entries.len() - ACTIVITY_HISTORY_CAP;
            history.entries.drain(0..overflow);
            history.trimmed += overflow;
        }
        self.activity.send_replace(Arc::new(history));
    }

    /// The activity feed for one connection, or `None` when it must never
    /// have one — [`Self::presence_updates`]'s reasoning, applied to spec §8
    /// rather than §7: `RemoteActivity` reaches local connections only, so a
    /// remote viewer never learns what the log says about it. This is what
    /// makes that structural: `crate::authorize_remote`'s allowlist keeps a
    /// remote client from *asking* for it, and this keeps the daemon from
    /// ever *offering* it.
    pub(crate) fn activity_updates(
        &self,
        trust: &ClientTrust,
    ) -> Option<watch::Receiver<Arc<ActivityHistory>>> {
        trust.is_local().then(|| self.activity.subscribe())
    }

    /// Drops every **remote** connection with this viewer id, returning
    /// whether there was one. The entries go here, not when each
    /// `serve_client` notices its token — so the roster published straight
    /// after a kick is already correct.
    ///
    /// The trust filter is structural, not decorative: `serve_client` calls
    /// [`Self::set_viewer`] for local connections too (a host may name
    /// itself), so matching on viewer id alone would let a
    /// `DisconnectViewer` naming the host's own id drop the local app's
    /// connection. Nothing sends that today; the way to keep it that way is
    /// for the kick to be unable to reach a local entry at all.
    pub fn cancel_viewer(&self, viewer_id: &str) -> bool {
        let mut entries = self.entries();
        let kicked: Vec<u64> = entries
            .iter()
            .filter(|(_, entry)| {
                entry.trust.is_remote()
                    && entry
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
        // The lease is freed here rather than when each kicked task notices
        // its token, for the same reason the entries are: the host has just
        // ended this connection, and the next machine must not be told "in use
        // by" a viewer that is already gone. The guard goes first — the two
        // locks are never held together.
        drop(entries);
        for id in &kicked {
            self.release_lease(*id);
        }
        !kicked.is_empty()
    }
}

/// Writes roster updates to one local connection, on its own task.
///
/// A client that stops draining its socket must wedge only itself. Presence
/// used to be written by a loop that held a registry-wide lock across every
/// client's `write_frame` in turn, awaited inline in the dispatch loops — so
/// one stalled same-UID client could stall presence bookkeeping and the
/// attach/detach dispatch of every other connection, remote viewers included.
/// Giving each connection its own feed task, exactly as each attachment
/// already has its own `forward_events`, makes that impossible rather than
/// unlikely.
///
/// **The ordering that is kept** is the one that matters: a client's *last*
/// roster is the newest state any publisher read, because
/// [`ConnectionRegistry::notify_presence`] snapshots and publishes atomically
/// under the entries lock, and `watch` then hands this task the latest value
/// rather than a backlog. Intermediate rosters may be skipped when changes
/// arrive faster than a client drains — which is right, since a roster states
/// the present rather than recording an event — and every frame written is
/// internally consistent.
pub struct PresenceFeed(JoinHandle<()>);

impl Drop for PresenceFeed {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl PresenceFeed {
    pub fn spawn(
        mut updates: watch::Receiver<Arc<RemoteViewersPayload>>,
        writer: SharedWriter,
    ) -> Self {
        Self(tokio::spawn(async move {
            // The roster at connect time goes to this one client, never to
            // everybody — and only when it is news. A client starts out
            // believing nobody is watching, so an empty roster would be an
            // unsolicited frame between its `Hello` and the reply to its
            // first request, saying something it already knows.
            let initial = updates.borrow_and_update().clone();
            if !initial.viewers.is_empty() && write_roster(&writer, &initial).await.is_err() {
                return;
            }
            while updates.changed().await.is_ok() {
                let roster = updates.borrow_and_update().clone();
                if write_roster(&writer, &roster).await.is_err() {
                    return;
                }
            }
        }))
    }
}

async fn write_roster(writer: &SharedWriter, roster: &RemoteViewersPayload) -> std::io::Result<()> {
    let payload = serde_json::to_vec(roster).map_err(std::io::Error::other)?;
    // A push, so the header carries a sequence rather than a request id, and
    // there is no request this answers.
    let frame = Frame::new(MessageKind::RemoteViewers, 0, payload);
    write_frame(&mut *writer.lock().await, &frame).await
}

/// Writes `RemoteActivity` pushes to one local connection, on its own task
/// (Task 19, spec §8) — the same structure as [`PresenceFeed`], and the same
/// reason: a client that stops draining its socket must be able to stall
/// only itself, never presence or another connection's dispatch.
///
/// **Unlike [`PresenceFeed`], nothing is sent at subscribe time.** A roster
/// is the present, worth replaying to a connection that just opened; an
/// activity batch is a record of things that already happened, and replaying
/// whatever was last published to a freshly-attached local connection would
/// announce old news as if it were new. So the value already in the channel
/// when this subscribes is marked seen and never written — only what is
/// published *after* this task starts watching ever reaches this connection.
///
/// **Tracks a monotonic global index, not a length.** [`ActivityHistory`] is
/// capped and trimmed from the front (see its own doc), so "how many entries
/// are in the vec right now" is not a stable measure of "how much of it has
/// this feed already sent" across a trim. `trimmed + entries.len()` is: it
/// only ever grows, so comparing against it — and slicing from `next -
/// trimmed` — is correct whether or not a trim happened in between.
pub struct ActivityFeed(JoinHandle<()>);

impl Drop for ActivityFeed {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl ActivityFeed {
    pub fn spawn(mut updates: watch::Receiver<Arc<ActivityHistory>>, writer: SharedWriter) -> Self {
        Self(tokio::spawn(async move {
            let mut next = {
                let seen = updates.borrow_and_update();
                seen.trimmed + seen.entries.len()
            };
            while updates.changed().await.is_ok() {
                let history = updates.borrow_and_update().clone();
                let total = history.trimmed + history.entries.len();
                if total <= next {
                    // Coalesced watch notification with nothing new for this
                    // feed specifically — can happen if this task observes a
                    // publish that superseded one it never got to see.
                    continue;
                }
                // `next.saturating_sub` rather than a plain subtraction: if
                // every entry this feed had not yet sent was trimmed out from
                // under it (an extreme, accepted loss — see
                // `ACTIVITY_HISTORY_CAP`'s doc), send everything still
                // retained rather than panicking on the underflow.
                let start = next
                    .saturating_sub(history.trimmed)
                    .min(history.entries.len());
                let fresh = RemoteActivityPayload {
                    entries: history.entries[start..].to_vec(),
                };
                next = total;
                if fresh.entries.is_empty() {
                    continue;
                }
                if write_activity(&writer, &fresh).await.is_err() {
                    return;
                }
            }
        }))
    }
}

async fn write_activity(
    writer: &SharedWriter,
    payload: &RemoteActivityPayload,
) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(payload).map_err(std::io::Error::other)?;
    let frame = Frame::new(MessageKind::RemoteActivity, 0, bytes);
    write_frame(&mut *writer.lock().await, &frame).await
}

fn rfc3339(at: SystemTime) -> String {
    chrono::DateTime::<chrono::Utc>::from(at).to_rfc3339()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn viewer(id: &str, name: &str) -> ViewerIdentity {
        ViewerIdentity {
            viewer_id: id.into(),
            machine_name: name.into(),
        }
    }

    fn holder(id: Option<&str>, name: &str) -> LeaseHolder {
        LeaseHolder {
            viewer_id: id.map(str::to_owned),
            machine_name: name.into(),
            asserted: asserted_for("bruno@bonando.com"),
        }
    }

    /// What the relay asserts about a viewer signed in as `email`.
    fn asserted_for(email: &str) -> AssertedIdentity {
        AssertedIdentity {
            account_email: Some(email.to_owned()),
            ..AssertedIdentity::default()
        }
    }

    /// A relayed connection, for the registry tests — which are about
    /// presence and the kick, not about who the relay said was calling.
    fn remote() -> ClientTrust {
        ClientTrust::Remote(Box::new(asserted_for("bruno@bonando.com")))
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
        let host = registry.register(ClientTrust::Local, CancellationToken::new());
        let anonymous = registry.register(remote(), CancellationToken::new());
        let air = registry.register(remote(), CancellationToken::new());

        // A local connection may carry an identity; it is still not a viewer.
        assert!(!registry.set_viewer(host, viewer("v-host", "Studio")));
        assert!(registry.set_viewer(air, viewer("v-air", "Air")));
        registry.set_attached(anonymous, attached(&["s9"]));

        let viewers = registry.viewers();
        assert_eq!(viewers.len(), 1);
        assert_eq!(viewers[0].viewer_id, "v-air");
    }

    /// Spec §7 invariant 3, at its source: only a local connection can even
    /// obtain the roster feed.
    #[test]
    fn a_remote_connection_cannot_subscribe_to_the_roster() {
        let registry = ConnectionRegistry::default();
        assert!(registry.presence_updates(&ClientTrust::Local).is_some());
        assert!(registry.presence_updates(&remote()).is_none());
    }

    /// One machine, two sockets — the relay opens a fresh data connection when
    /// a viewer re-dials, and the old one lives until its read fails.
    #[test]
    fn two_connections_from_one_machine_are_one_roster_entry() {
        let registry = ConnectionRegistry::default();
        let old = registry.register(remote(), CancellationToken::new());
        let new = registry.register(remote(), CancellationToken::new());
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
        let air = registry.register(remote(), CancellationToken::new());
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

    /// A kick reaches viewers only. `serve_client` calls `set_viewer` for
    /// local connections too, so a `DisconnectViewer` naming the host's own
    /// viewer id must find nothing to cancel rather than dropping the app.
    #[test]
    fn a_kick_cannot_reach_a_local_connection_sharing_the_viewer_id() {
        let registry = ConnectionRegistry::default();
        let host_cancel = CancellationToken::new();
        let host = registry.register(ClientTrust::Local, host_cancel.clone());
        registry.set_viewer(host, viewer("v-shared", "Studio"));

        assert!(
            !registry.cancel_viewer("v-shared"),
            "a local connection is not a viewer, so there was nothing to kick"
        );
        assert!(!host_cancel.is_cancelled(), "the host's socket survives");

        // And the same id on a remote connection still goes, host or no host.
        let air = registry.register(remote(), CancellationToken::new());
        registry.set_viewer(air, viewer("v-shared", "Air"));
        assert!(registry.cancel_viewer("v-shared"));
        assert!(!host_cancel.is_cancelled(), "and the host still survives");
    }

    /// The lease is one machine's at a time, and the refusal names the one
    /// holding it.
    #[test]
    fn one_connection_holds_the_lease_and_the_next_is_told_whose_it_is() {
        let registry = ConnectionRegistry::default();
        let air = registry.register(remote(), CancellationToken::new());
        registry.set_viewer(air, viewer("v-air", "Air"));
        let mini = registry.register(remote(), CancellationToken::new());

        assert_eq!(
            registry.take_lease(air, holder(Some("v-air"), "Air")),
            Ok(None)
        );
        assert_eq!(
            registry.take_lease(mini, holder(Some("v-mini"), "Mini")),
            Err("Air".to_string())
        );
        assert_eq!(
            registry.lease_holder(),
            Some(holder(Some("v-air"), "Air")),
            "the holder carries the viewer id the host would Terminate"
        );

        // And it is free again the moment that connection leaves the registry.
        registry.remove(air);
        assert!(registry.lease_holder().is_none());
        assert_eq!(
            registry.take_lease(mini, holder(Some("v-mini"), "Mini")),
            Ok(None)
        );
    }

    /// The reclaim (spec §11), at the registry: the viewer that already holds
    /// the machine takes it over and is handed the stale connection id to
    /// cancel; a different machine is still refused.
    #[test]
    fn the_same_viewer_reclaims_the_lease_and_a_different_machine_does_not() {
        let registry = ConnectionRegistry::default();
        let air = registry.register(remote(), CancellationToken::new());
        let air_again = registry.register(remote(), CancellationToken::new());
        let mini = registry.register(remote(), CancellationToken::new());

        assert_eq!(
            registry.take_lease(air, holder(Some("v-air"), "Air")),
            Ok(None)
        );
        assert_eq!(
            registry.take_lease(mini, holder(Some("v-mini"), "Mini")),
            Err("Air".to_string())
        );
        // The same viewer, on a second socket, with the machine renamed since
        // — the name is not the key, the asserted account plus the id is.
        assert_eq!(
            registry.take_lease(air_again, holder(Some("v-air"), "Air (2)")),
            Ok(Some(air)),
            "the returning viewer did not reclaim, or was not told what to cancel"
        );
        assert_eq!(
            registry.lease_holder().and_then(|held| held.viewer_id),
            Some("v-air".to_string())
        );
    }

    /// The gate on the reclaim. Same claimed `viewer_id`, a different
    /// relay-asserted account: refused. `server::viewer_owns_this_account`
    /// already refuses such a connection long before the lease, and this
    /// holds the registry to the same rule on its own — the point of two
    /// independent checks is that neither leans on the other.
    #[test]
    fn a_different_asserted_account_never_reclaims_even_with_the_same_viewer_id() {
        let registry = ConnectionRegistry::default();
        let mine = registry.register(remote(), CancellationToken::new());
        let theirs = registry.register(remote(), CancellationToken::new());
        registry
            .take_lease(mine, holder(Some("v-air"), "Air"))
            .unwrap();

        let stranger = LeaseHolder {
            asserted: asserted_for("someone@else.com"),
            ..holder(Some("v-air"), "Air")
        };
        assert_eq!(
            registry.take_lease(theirs, stranger),
            Err("Air".to_string())
        );
    }

    /// An anonymous holder — a pre-phase-2 app with no `viewer_id` — is never
    /// reclaimed from: there is nothing on either side that says the two
    /// connections are one machine, so "no id" must not compare equal to
    /// "no id".
    #[test]
    fn an_anonymous_holder_is_never_reclaimed_from() {
        let registry = ConnectionRegistry::default();
        let first = registry.register(remote(), CancellationToken::new());
        let second = registry.register(remote(), CancellationToken::new());
        registry
            .take_lease(first, holder(None, "Unknown Mac"))
            .unwrap();
        assert_eq!(
            registry.take_lease(second, holder(None, "Unknown Mac")),
            Err("Unknown Mac".to_string())
        );
    }

    /// `cancel_connection` reaches remote connections only, for
    /// `cancel_viewer`'s reason: nothing in this family may drop the host's
    /// own app, and the local-absence clock is `remove`'s to keep.
    #[test]
    fn cancel_connection_cannot_reach_the_hosts_own_app() {
        let registry = ConnectionRegistry::default();
        let host_cancel = CancellationToken::new();
        let host = registry.register(ClientTrust::Local, host_cancel.clone());

        assert!(!registry.cancel_connection(host));
        assert!(!host_cancel.is_cancelled());
        assert!(registry.has_local(), "the host's own app was dropped");
        assert!(
            !registry.cancel_connection(9_999),
            "cancelling an id that is not here is a no-op, not a panic"
        );
    }

    /// The reason [`ConnectionRegistry::release_lease`] matches on the id.
    ///
    /// A kicked viewer's `serve_client` task unwinds a beat after the kick,
    /// which is long enough for the next machine to have connected and taken
    /// the lease. A release that cleared whatever it found would evict that
    /// live viewer — and nothing would say so; it would show up as a session
    /// that ends by itself.
    #[test]
    fn a_late_release_from_a_dead_connection_cannot_evict_a_live_one() {
        let registry = ConnectionRegistry::default();
        let dead = registry.register(remote(), CancellationToken::new());
        registry
            .take_lease(dead, holder(Some("v-air"), "Air"))
            .unwrap();
        registry.release_lease(dead);

        let live = registry.register(remote(), CancellationToken::new());
        registry
            .take_lease(live, holder(Some("v-mini"), "Mini"))
            .unwrap();

        registry.release_lease(dead);
        assert_eq!(
            registry.lease_holder().map(|holder| holder.machine_name),
            Some("Mini".to_string()),
            "the dead connection's release took the live one's lease"
        );
    }

    /// A client older than phase 2 sends no `viewer_id`. It may still hold the
    /// lease — it is a machine driving this one — but the host cannot Terminate
    /// it by id, and the type says so rather than handing back an empty string
    /// that `cancel_viewer` would accept and silently no-op on.
    #[test]
    fn an_anonymous_holder_offers_no_viewer_id_to_kick_it_with() {
        let registry = ConnectionRegistry::default();
        let anonymous = registry.register(remote(), CancellationToken::new());
        registry
            .take_lease(anonymous, holder(None, "Unknown Mac"))
            .unwrap();

        let held = registry.lease_holder().unwrap();
        assert_eq!(held.machine_name, "Unknown Mac");
        assert_eq!(held.viewer_id, None, "there is no id, and it is not \"\"");
        // The one thing that must be impossible by accident: kicking with it.
        // There is no `&str` to pass, so this does not type-check at all —
        // what a caller can do is the `if let Some(id)` the `Option` forces.
        assert!(
            !registry.cancel_viewer(""),
            "and an empty id matches nothing, so a slip is a no-op rather than a wrong kick"
        );
    }

    /// A kick frees the machine at once, rather than when the kicked task
    /// happens to notice its cancellation token.
    #[test]
    fn kicking_a_viewer_frees_the_lease_with_its_entry() {
        let registry = ConnectionRegistry::default();
        let air = registry.register(remote(), CancellationToken::new());
        registry.set_viewer(air, viewer("v-air", "Air"));
        registry
            .take_lease(air, holder(Some("v-air"), "Air"))
            .unwrap();

        assert!(registry.cancel_viewer("v-air"));
        assert!(registry.lease_holder().is_none());
    }

    /// Publishing is non-blocking even with nobody listening, and a feed that
    /// subscribes later still opens on the current roster rather than an empty
    /// one.
    #[tokio::test]
    async fn publishing_never_waits_and_a_late_subscriber_sees_the_current_roster() {
        let registry = ConnectionRegistry::default();
        let air = registry.register(remote(), CancellationToken::new());
        registry.set_viewer(air, viewer("v-air", "Air"));
        registry.notify_presence();

        let updates = registry.presence_updates(&ClientTrust::Local).unwrap();
        assert_eq!(updates.borrow().viewers.len(), 1);
    }

    /// The published value is the newest state, never a stale snapshot.
    ///
    /// This is the observable half of the fix in `notify_presence`. The
    /// *interleaving* half — two publishers reading in one order and
    /// publishing in the other — is not something a test can pin without
    /// scheduling both threads by hand; it is closed structurally instead, by
    /// snapshotting and calling `send_replace` under one entries guard, so
    /// there is no window between the read and the publish for another
    /// publisher to slip into. What this asserts is the property that window
    /// used to break: after a sequence of changes, the channel's final value
    /// describes the final state.
    #[test]
    fn the_last_published_roster_is_the_newest_one() {
        let registry = ConnectionRegistry::default();
        let updates = registry.presence_updates(&ClientTrust::Local).unwrap();

        let old = registry.register(remote(), CancellationToken::new());
        registry.set_viewer(old, viewer("v-air", "Air"));
        registry.notify_presence();
        assert_eq!(updates.borrow().viewers.len(), 1);

        // The reconnect: the replacement attaches, the dead socket is reaped.
        let new = registry.register(remote(), CancellationToken::new());
        registry.set_viewer(new, viewer("v-mini", "Mini"));
        registry.notify_presence();
        registry.remove(old);
        registry.notify_presence();

        let roster = updates.borrow().clone();
        assert_eq!(
            roster
                .viewers
                .iter()
                .map(|v| &v.viewer_id)
                .collect::<Vec<_>>(),
            ["v-mini"],
            "the value left in the channel is the roster after the last change"
        );
    }
}

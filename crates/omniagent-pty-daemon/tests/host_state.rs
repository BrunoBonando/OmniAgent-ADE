//! `PublishHostState` / `HostState` (Task 21, spec §4) — the channel the app
//! (Task 22) uses to tell the lease holder the handful of facts a viewer's
//! own machine would otherwise answer wrongly about itself: the CPU/memory/
//! GPU gauges, the Claude usage limits, and engine availability.
//!
//! The daemon's whole job here is to hold the last published payload and
//! forward it, opaque, to whichever connection currently holds the lease —
//! never to parse it. These two tests pin exactly that: the payload reaches
//! the lease holder on connect and on every subsequent publish
//! (`host_state_reaches_the_lease_holder_on_connect_and_on_change`), and a
//! remote client can never publish on the host's behalf
//! (`a_remote_client_may_not_publish_host_state`) — `PublishHostState` is
//! local-only, pinned again at the allowlist level by
//! `remote_authz.rs::the_local_only_kinds_stay_local`.

mod support;

#[tokio::test]
async fn host_state_reaches_the_lease_holder_on_connect_and_on_change() {
    let mut harness = support::daemon_with_local_client().await;
    harness
        .local()
        .publish_host_state(r#"{"metrics":{"cpu":0.5}}"#)
        .await;

    let mut viewer = harness.connect_remote("MacBook Pro");
    viewer.hello().await;
    assert_eq!(viewer.next_host_state().await["metrics"]["cpu"], 0.5);

    harness
        .local()
        .publish_host_state(r#"{"metrics":{"cpu":0.9}}"#)
        .await;
    assert_eq!(viewer.next_host_state().await["metrics"]["cpu"], 0.9);
}

#[tokio::test]
async fn a_remote_client_may_not_publish_host_state() {
    let harness = support::daemon_with_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    viewer.hello().await;
    assert!(viewer.publish_host_state("{}").await.is_error());
}

/// A connection that never publishes anything is sent nothing at all —
/// `HostStateFeed` must not manufacture a frame out of an empty `Option`.
/// Half of the standing "nothing runs when nobody is connected" rule: this
/// pins the other half, that a viewer who *does* connect before the host has
/// ever published is not handed a synthetic empty object it would have to
/// tell apart from real zeros.
#[tokio::test]
async fn a_viewer_who_connects_before_any_publish_receives_nothing() {
    let harness = support::daemon_with_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    viewer.hello().await;

    assert!(
        viewer.received_no_activity_push().await,
        "a lease holder that has never been published to must receive no HostState push"
    );
}

/// The daemon holds exactly one slot for the whole machine, not one per
/// connection: a second viewer that reclaims the lease after the first
/// disconnects is told the same last-known state, not nothing.
#[tokio::test]
async fn a_reconnecting_viewer_sees_the_last_published_state() {
    let mut harness = support::daemon_with_local_client().await;
    harness
        .local()
        .publish_host_state(r#"{"metrics":{"cpu":0.3}}"#)
        .await;

    {
        let mut first = harness.connect_remote("MacBook Pro");
        first.hello().await;
        assert_eq!(first.next_host_state().await["metrics"]["cpu"], 0.3);
    }
    harness.wait_for_no_lease().await;

    let mut second = harness.connect_remote("MacBook Pro");
    second.hello().await;
    assert_eq!(second.next_host_state().await["metrics"]["cpu"], 0.3);
}

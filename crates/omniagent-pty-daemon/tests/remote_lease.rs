//! The lease: at most one remote connection at a time
//! (`docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
//! §3 "The lease", §12 invariant 4).
//!
//! This is the first of the three controls that make a valid device token
//! something other than unrestricted use of the machine. The allowlist widened
//! to the whole environment — `CreateSession` is arbitrary execution — so what
//! stands between a token and the host is *who* may hold the lease, not what a
//! holder may do. The property under test is therefore not "a second viewer
//! sees a nice message" but **exactly one connection can hold it, and it is
//! always released**.

mod support;

use support::HelloResult;

/// §12 invariant 4. The second machine is told which one has the environment,
/// by name — a refusal a human can act on rather than a closed socket.
#[tokio::test]
async fn a_second_viewer_is_refused_while_the_first_holds_the_lease() {
    let harness = support::daemon_with_local_client().await;

    let mut first = harness.connect_remote("MacBook Pro");
    assert!(matches!(first.hello().await, HelloResult::Ack(_)));

    let mut second = harness.connect_remote("Mac mini");
    match second.hello().await {
        HelloResult::Error(message) => {
            assert!(message.contains("in use by MacBook Pro"), "{message}")
        }
        other => panic!("expected refusal, got {other:?}"),
    }
}

/// The half that a daemon can get wrong for good: a lease that is taken on one
/// path and released on only some of the ways back out refuses every future
/// viewer until the daemon restarts.
#[tokio::test]
async fn the_lease_is_released_when_the_connection_ends() {
    let harness = support::daemon_with_local_client().await;
    {
        let mut first = harness.connect_remote("MacBook Pro");
        assert!(matches!(first.hello().await, HelloResult::Ack(_)));
    } // dropped

    harness.wait_for_no_lease().await;
    let mut second = harness.connect_remote("Mac mini");
    assert!(matches!(second.hello().await, HelloResult::Ack(_)));
}

/// A refused connection must not have taken the lease on its way to being
/// refused. The blocklist runs before the lease for this reason, and this
/// pins it from the outside: the blocked machine leaves nothing behind.
#[tokio::test]
async fn a_blocked_viewer_is_refused_without_taking_the_lease() {
    let harness = support::daemon_with_local_client().await;
    harness
        .ctx
        .settings
        .lock()
        .unwrap()
        .set_setting(
            omniagent_pty_daemon::BLOCKED_VIEWERS_KEY,
            r#"["v-macbook-pro"]"#,
        )
        .unwrap();

    let mut blocked = harness.connect_remote("MacBook Pro");
    assert!(matches!(blocked.hello().await, HelloResult::Error(_)));
    assert!(
        harness.ctx.connections.lease_holder().is_none(),
        "a refused connection left the lease held"
    );

    let mut allowed = harness.connect_remote("Mac mini");
    assert!(matches!(allowed.hello().await, HelloResult::Ack(_)));
}

/// The lease is remote-only. A host's own app connects and reconnects freely —
/// a daemon that made the local client take the lease would lock the machine
/// out of itself on the second window.
#[tokio::test]
async fn local_connections_never_take_the_lease() {
    let harness = support::daemon_with_local_client().await;
    assert!(harness.ctx.connections.lease_holder().is_none());

    let mut remote = harness.connect_remote("MacBook Pro");
    assert!(matches!(remote.hello().await, HelloResult::Ack(_)));
    assert_eq!(
        harness
            .ctx
            .connections
            .lease_holder()
            .map(|holder| holder.machine_name),
        Some("MacBook Pro".to_string())
    );
}

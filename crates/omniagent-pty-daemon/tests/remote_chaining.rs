//! No remote connection without a local app — and therefore no chaining
//! (`docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
//! §2 condition 3, §3 "One remote session per machine, in either direction").
//!
//! The third of the three controls that make a valid device token something
//! other than unrestricted use of the machine, and the one that reads like a
//! UI nicety and is not. Sharing is live only while the host's own app is
//! attached — "whenever the menu bar icon is there" — and that single
//! condition is what forbids chaining, *structurally*:
//!
//! - a Mac that is driving another has swapped its single app connection away
//!   from its own daemon, so it has no local connection, fails this test,
//!   closes its own control channel and refuses everyone inbound;
//! - so a machine being driven can never be made to reach onward to a third,
//!   and a machine that is driving cannot simultaneously be driven.
//!
//! No rule is enforced anywhere to get that, and no state is kept in sync for
//! it. What these tests pin is the condition itself, both edges of its 5 s
//! grace, and the refusal a machine that fails it gives.
//!
//! The grace is moved with `tokio::time::pause`/`advance` rather than slept
//! through: five real seconds per test would be paid to observe nothing, and
//! the edges (2 s in, 6 s out) would be timing luck rather than assertions.

mod support;

use std::time::Duration;

use omniagent_pty_daemon::{
    sharing_should_be_live, ClientTrust, ConnectionRegistry, DEVICE_TOKEN_KEY, REMOTE_SHARING_KEY,
};
use support::HelloResult;
use tokio_util::sync::CancellationToken;

/// The property, stated as the daemon states it: no local app, no inbound
/// connection. This is the `daemon_without_local_client` case — sharing on,
/// device token present, app away — which is precisely the state of a Mac
/// whose app has gone to drive another one.
#[tokio::test]
async fn no_remote_connection_is_accepted_without_a_local_app() {
    let harness = support::daemon_without_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    match viewer.hello().await {
        HelloResult::Error(message) => assert!(message.contains("not available"), "{message}"),
        other => panic!("expected refusal, got {other:?}"),
    }
}

/// The refusal names **this** Mac, not the caller.
///
/// A viewer shows this sentence about the machine it dialled, so "MacBook Pro
/// is not available" on a MacBook Pro would be nonsense. The name is the one
/// this Mac announced to the relay at pairing, which is the only name the
/// daemon has for itself.
#[tokio::test]
async fn the_refusal_names_the_machine_that_is_unavailable() {
    let harness = support::daemon_without_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    match viewer.hello().await {
        HelloResult::Error(message) => {
            assert_eq!(message, "Mac Studio is not available");
        }
        other => panic!("expected refusal, got {other:?}"),
    }
}

/// A refused connection must leave the machine exactly as it found it — the
/// availability check runs *before* the lease is taken, so a Mac whose app is
/// away is not also a Mac that has been locked by everyone who knocked while
/// it was.
#[tokio::test(start_paused = true)]
async fn an_unavailable_machine_hands_out_no_lease() {
    let mut harness = support::daemon_with_local_client().await;
    harness.drop_local_client().await;
    harness.advance_past_the_grace().await;

    let mut viewer = harness.connect_remote("MacBook Pro");
    assert!(matches!(viewer.hello().await, HelloResult::Error(_)));
    assert!(
        harness.ctx.connections.lease_holder().is_none(),
        "a refused connection left the lease held"
    );
    assert!(
        harness.ctx.connections.viewers().is_empty(),
        "a refused connection was put on the host's roster"
    );

    // And the machine is genuinely usable again the moment its app is back:
    // the refusal is a state, not a latch.
    harness.reconnect_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    assert!(matches!(viewer.hello().await, HelloResult::Ack(_)));
}

/// The grace, on the side that matters most: an app reconnect — or a
/// `rebuild-app.sh` restart, which is routine here — must not flap a live
/// remote session.
#[tokio::test(start_paused = true)]
async fn a_local_reconnect_inside_the_grace_does_not_drop_the_remote() {
    let mut harness = support::daemon_with_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    assert!(matches!(viewer.hello().await, HelloResult::Ack(_)));

    harness.drop_local_client().await;
    harness.advance(Duration::from_secs(2)).await;
    assert!(
        harness.sharing_is_live(),
        "sharing went down two seconds into a five-second grace"
    );

    harness.reconnect_local_client().await;
    harness.advance(Duration::from_secs(10)).await;
    assert!(
        harness.sharing_is_live(),
        "the app came back inside the grace and sharing stayed down"
    );
    assert!(
        viewer.is_open().await,
        "a live remote session was dropped by an app restart"
    );
}

/// The other edge: the grace really does expire. A daemon that only ever
/// tolerated an absent app would share this machine forever after the app was
/// quit — and would keep chaining possible, since the machine driving another
/// would go on accepting inbound connections of its own.
#[tokio::test(start_paused = true)]
async fn sharing_goes_down_once_the_grace_expires() {
    let mut harness = support::daemon_with_local_client().await;
    assert!(harness.sharing_is_live());

    harness.drop_local_client().await;
    harness.advance(Duration::from_secs(6)).await;
    assert!(
        !harness.sharing_is_live(),
        "sharing survived six seconds without the app"
    );

    // …and the machine says so to the next caller rather than merely going
    // quiet, which is the difference between a viewer showing a sentence and a
    // viewer reconnecting in a loop.
    let mut viewer = harness.connect_remote("MacBook Pro");
    match viewer.hello().await {
        HelloResult::Error(message) => assert!(message.contains("not available"), "{message}"),
        other => panic!("expected refusal, got {other:?}"),
    }
}

/// All three conditions, conjunctively, so that "sharing is live" can never
/// quietly come to mean any two of them.
///
/// Directly against the function rather than through the harness, because
/// "the device token row is absent" is a state only a store that never had one
/// can be in — settings rows are written, never deleted.
#[test]
fn every_one_of_the_three_conditions_is_necessary() {
    let store = brain_core::Store::open_in_memory().unwrap();
    let connections = ConnectionRegistry::default();
    let local = connections.register(ClientTrust::Local, CancellationToken::new());

    assert!(
        !sharing_should_be_live(&store, &connections),
        "an app is attached, but nothing has been switched on"
    );
    store
        .set_setting(REMOTE_SHARING_KEY, r#"{"enabled":true}"#)
        .unwrap();
    assert!(
        !sharing_should_be_live(&store, &connections),
        "a machine with no device token is paired with no relay"
    );
    store
        .set_setting(
            DEVICE_TOKEN_KEY,
            r#"{"device_id":"dev","token":"tok","name":"Mac Studio","relay_url":"http://127.0.0.1:1"}"#,
        )
        .unwrap();
    assert!(
        sharing_should_be_live(&store, &connections),
        "switched on, paired, app attached"
    );

    // The condition this file is about, isolated: the same settings, and a
    // registry whose app has never connected.
    assert!(
        !sharing_should_be_live(&store, &ConnectionRegistry::default()),
        "a daemon whose app has never connected shared itself"
    );

    // An app that has just left is inside its grace, not past it.
    connections.remove(local);
    assert!(
        !connections.has_local(),
        "the local connection outlived its removal"
    );
    assert!(
        sharing_should_be_live(&store, &connections),
        "the grace started already expired"
    );
}

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

/// A refused viewer is never a viewer the host is shown.
///
/// The lease is taken *before* the connection names itself, so a machine that
/// knocks while another is driving is never rostered at all — where taking the
/// lease afterwards would have put it on the host's roster for the moment
/// between registering and being refused, flickering an unadmitted machine
/// through the takeover panel. That window is not observable from out here;
/// what is, and what this holds, is that nothing is left behind either.
#[tokio::test]
async fn a_refused_viewer_is_not_on_the_roster() {
    let harness = support::daemon_with_local_client().await;
    let mut first = harness.connect_remote("MacBook Pro");
    assert!(matches!(first.hello().await, HelloResult::Ack(_)));

    let mut second = harness.connect_remote("Mac mini");
    assert!(matches!(second.hello().await, HelloResult::Error(_)));

    let machines: Vec<String> = harness
        .ctx
        .connections
        .viewers()
        .into_iter()
        .map(|viewer| viewer.machine_name)
        .collect();
    assert_eq!(machines, ["MacBook Pro".to_string()]);
}

/// An app older than phase 2 sends no `viewer_id`. It may still drive the
/// machine — that is one Mac on another, which is all the lease is about — but
/// the host cannot Terminate it *by id*, and `lease_holder()` has to say so in
/// its type rather than hand back an empty string that `cancel_viewer` would
/// accept and silently do nothing with.
#[tokio::test]
async fn an_anonymous_viewer_holds_the_lease_with_no_id_to_kick_it_by() {
    let harness = support::daemon_with_local_client().await;
    let mut anonymous = harness.connect_remote("MacBook Pro");
    assert!(matches!(
        anonymous.hello_without_naming_itself().await,
        HelloResult::Ack(_)
    ));

    let held = harness.ctx.connections.lease_holder().unwrap();
    assert_eq!(held.machine_name, "MacBook Pro");
    assert_eq!(held.viewer_id, None);
    // And it really is holding the machine, not merely recorded as doing so.
    let mut second = harness.connect_remote("Mac mini");
    match second.hello().await {
        HelloResult::Error(message) => {
            assert!(message.contains("in use by MacBook Pro"), "{message}")
        }
        other => panic!("expected refusal, got {other:?}"),
    }
}

// ---------------------------------------------------------------------------
// Protocol version 2 (spec §3 "Protocol version")
// ---------------------------------------------------------------------------

/// Local skew is handled by shipping together — `rebuild-app.sh` restarts the
/// daemon with the app. *Remote* skew is real: Mac A updated, Mac B not. Phase
/// 1's answer was to drop the stream, which the viewer read as an outage and
/// answered with a reconnect loop and a dead keyboard. The refusal has to be a
/// sentence instead.
#[tokio::test]
async fn a_remote_peer_on_the_old_protocol_is_told_to_update() {
    let harness = support::daemon_with_local_client().await;
    let mut old = harness.connect_remote_with_version("MacBook Pro", 1);
    match old.hello().await {
        HelloResult::Error(message) => {
            assert!(
                message.contains("update OmniAgent on MacBook Pro"),
                "{message}"
            )
        }
        other => panic!("expected refusal, got {other:?}"),
    }
}

/// **The order of the two refusals**, pinned where it is observable.
///
/// If the lease were taken before the version were checked, a skewed peer
/// arriving while another machine holds the lease would be told "in use by
/// Mac mini" — the wrong problem, and a message that sends its owner looking
/// for a viewer to disconnect instead of an app to update. The same swap also
/// lets a skewed peer take the lease on its way to being refused and hold it
/// until its connection tears down, locking out the machine that could
/// actually have used it; that window is too small to catch by racing it, so
/// the message is what this asserts.
#[tokio::test]
async fn the_version_is_checked_before_the_lease_not_after() {
    let harness = support::daemon_with_local_client().await;
    let mut holder = harness.connect_remote("Mac mini");
    assert!(matches!(holder.hello().await, HelloResult::Ack(_)));

    let mut old = harness.connect_remote_with_version("MacBook Pro", 1);
    match old.hello().await {
        HelloResult::Error(message) => assert!(
            message.contains("update OmniAgent on MacBook Pro"),
            "the skewed peer was told about the lease instead of the skew: {message}"
        ),
        other => panic!("expected refusal, got {other:?}"),
    }
}

/// And the refused peer leaves the machine free — its connection is still open
/// here, exactly as a real one would be for the moment before it is torn down.
#[tokio::test]
async fn a_refused_old_peer_leaves_the_lease_free_for_the_next_one() {
    let harness = support::daemon_with_local_client().await;
    let mut old = harness.connect_remote_with_version("MacBook Pro", 1);
    assert!(matches!(old.hello().await, HelloResult::Error(_)));
    assert!(
        harness.ctx.connections.lease_holder().is_none(),
        "the skewed peer held the machine on its way out"
    );

    let mut current = harness.connect_remote("Mac mini");
    assert!(matches!(current.hello().await, HelloResult::Ack(_)));
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

//! Nobody ever sees another person's sessions
//! (`docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
//! §9, §12 invariants 9-10).
//!
//! The invariant the whole feature rests on is checked **twice, in two
//! processes, on two facts**: the relay refuses a viewer whose `sub` does not
//! own the device, and the daemon — which does not trust that — refuses anyone
//! whose relay-asserted account does not hash to the account directory it is
//! serving. This file is the second check, and it is deliberately written as
//! if the first did not exist.
//!
//! The one thing every case here is really about: **the check reads the
//! assertion the relay attached to the connection, never the client's own
//! `Hello`.** A check run on a value the connecting client supplies checks
//! nothing, so the liar case below is not a nicety — it is the property.

mod support;

use support::HelloResult;

/// A refusal is an `Error` frame *and* a closed connection, not one or the
/// other: a viewer left connected after being told no is a viewer that can
/// try the next frame.
async fn assert_refused(client: &mut support::Client) -> String {
    let message = match client.hello().await {
        HelloResult::Error(message) => message,
        other => panic!("expected a refusal, got {other:?}"),
    };
    assert!(
        !client.is_open().await,
        "the daemon refused the viewer and left the socket open"
    );
    message
}

/// §12 invariant 10. The daemon is serving one account's directory; a viewer
/// the relay says belongs to somebody else is refused, and the owner is not.
#[tokio::test]
async fn a_viewer_from_a_different_account_is_refused() {
    let harness = support::daemon_for_account("bruno@bonando.com").await;

    let mut stranger = harness.connect_remote_asserting("MacBook Pro", "someone@else.com");
    assert_refused(&mut stranger).await;
    assert!(
        harness.ctx.connections.lease_holder().is_none(),
        "a stranger held the machine on its way out"
    );

    let mut owner = harness.connect_remote_asserting("MacBook Pro", "bruno@bonando.com");
    assert!(matches!(owner.hello().await, HelloResult::Ack(_)));
}

/// The check has to normalize the way the directory name was chosen, or the
/// owner is locked out of their own Mac by a capital letter.
/// `Store::account_dir_id` trims and lower-cases before hashing; reusing that
/// function is what makes this true rather than a second rule to keep in step.
#[tokio::test]
async fn the_check_is_case_and_whitespace_insensitive_like_the_account_dir() {
    let harness = support::daemon_for_account("bruno@bonando.com").await;
    let mut owner = harness.connect_remote_asserting("MacBook Pro", "  Bruno@Bonando.COM ");
    assert!(matches!(owner.hello().await, HelloResult::Ack(_)));
}

/// **The property.** The connection is asserted to be a stranger's and its own
/// `Hello` claims to be the owner's — `account_email`, `user_sub`, and a
/// nested `viewer` object of the exact shape the relay sends. Every one of
/// those is a field the client chose, and none of them may move the decision.
///
/// If this ever passes with an `Ack`, the account check has been rewritten
/// against the payload rather than the assertion, and the feature's central
/// invariant is gone with it.
#[tokio::test]
async fn a_hello_claiming_a_different_email_cannot_override_the_assertion() {
    let harness = support::daemon_for_account("bruno@bonando.com").await;
    let mut liar = harness
        .connect_remote_asserting("MacBook Pro", "someone@else.com")
        .claiming_in_hello("bruno@bonando.com");
    assert_refused(&mut liar).await;
}

/// And the mirror: a connection the relay asserts *is* the owner is admitted
/// even though its `Hello` claims somebody else entirely. The self-reported
/// half is not consulted in either direction.
#[tokio::test]
async fn a_hello_claiming_a_stranger_cannot_lock_the_owner_out_either() {
    let harness = support::daemon_for_account("bruno@bonando.com").await;
    let mut owner = harness
        .connect_remote_asserting("MacBook Pro", "bruno@bonando.com")
        .claiming_in_hello("someone@else.com");
    assert!(matches!(owner.hello().await, HelloResult::Ack(_)));
}

/// An assertion with no email at all is a refusal, not a default. A check
/// that can be skipped by omitting a field is not a check.
#[tokio::test]
async fn a_missing_assertion_is_refused_rather_than_waved_through() {
    let harness = support::daemon_for_account("bruno@bonando.com").await;
    let mut nameless = harness.connect_remote_asserting_nothing("MacBook Pro");
    assert_refused(&mut nameless).await;
}

/// A blank email is the same case as a missing one, and must not be allowed to
/// become "the hash of the empty string" — which is a real directory name that
/// something could one day be sitting in.
#[tokio::test]
async fn a_blank_asserted_email_is_refused() {
    let harness = support::daemon_for_account("bruno@bonando.com").await;
    let mut blank = harness.connect_remote_asserting("MacBook Pro", "   ");
    assert_refused(&mut blank).await;
}

/// A signed-out host has no account directory — the data dir is the root
/// itself, with no `accounts/` segment — so there is nothing an assertion
/// could match. It refuses everyone, including an assertion that would have
/// been admitted a moment earlier.
///
/// In production such a Mac has no device token and no control channel either,
/// so the question does not arise. That is a reason to be sure of this, not a
/// reason to skip it: the check must fail closed on its own.
#[tokio::test]
async fn a_signed_out_host_refuses_every_viewer() {
    let harness = support::daemon_signed_out().await;
    let mut viewer = harness.connect_remote_asserting("MacBook Pro", "bruno@bonando.com");
    assert_refused(&mut viewer).await;
}

/// **Where the check sits in the `Hello` sequence**, pinned where it is
/// observable.
///
/// The refusals after it all say something: "‹machine› is not available" names
/// *this Mac* as it announced itself to the relay, the blocklist confirms that
/// a viewer id is known here, and the lease names the machine currently
/// driving. None of those are facts a stranger is entitled to. So the account
/// check goes first among the viewer-specific refusals — a caller who is not
/// this account learns only that it is not this account.
///
/// Here the host is not sharing *and* the caller is a stranger. The sentence
/// that comes back must be the account one, and must not contain the host's
/// name.
#[tokio::test(start_paused = true)]
async fn a_stranger_is_refused_before_the_host_would_name_itself() {
    let mut harness = support::daemon_for_account("bruno@bonando.com").await;
    harness.drop_local_client().await;
    harness.advance_past_the_grace().await;
    assert!(!harness.sharing_is_live(), "the host must not be sharing");

    let mut stranger = harness.connect_remote_asserting("MacBook Pro", "someone@else.com");
    let message = assert_refused(&mut stranger).await;
    assert!(
        !message.contains("Mac Studio") && !message.contains("not available"),
        "the refusal told a stranger about this machine: {message}"
    );
}

/// …and the blocklist is likewise behind it: a stranger whose viewer id
/// happens to be blocked is told about the account, not about the block.
/// Otherwise a stranger could enumerate which machines a host has kicked.
#[tokio::test]
async fn a_stranger_is_refused_before_the_blocklist_would_confirm_an_id() {
    let harness = support::daemon_for_account("bruno@bonando.com").await;
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

    let mut stranger = harness.connect_remote_asserting("MacBook Pro", "someone@else.com");
    let message = assert_refused(&mut stranger).await;
    assert!(
        !message.contains("disconnected"),
        "the refusal told a stranger it was on the blocklist: {message}"
    );
}

/// The check is remote-only. The host's own app comes in over the unix socket
/// with no assertion at all — the peer-UID check already answered the same
/// question, and better — so a daemon that ran this on local connections would
/// lock the Mac out of itself.
#[tokio::test]
async fn the_hosts_own_app_is_not_subject_to_the_account_check() {
    // `daemon_for_account` only returns once the local client is past `Hello`.
    let harness = support::daemon_for_account("bruno@bonando.com").await;
    assert!(harness.ctx.connections.has_local());
}

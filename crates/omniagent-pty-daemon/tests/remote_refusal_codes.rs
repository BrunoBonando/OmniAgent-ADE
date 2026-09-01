//! `RefusalCode` on every `Hello` refusal (Task 14 item 2;
//! `docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
//! §3, §9, §12 invariant 10).
//!
//! `server.rs`'s `Hello` arm composes five sentences across six call sites —
//! the blocklist is checked twice, once before a viewer is registered and
//! once after, for the race window between the two — and until this code
//! existed, `SessionConnection.isTerminalRefusal` decided whether to keep
//! retrying by prefix-matching that prose. A copy edit to any one sentence
//! could silently misclassify a refusal, and nothing caught it: the Swift
//! tests hardcode their own copy of the string, so the two sides could drift
//! and neither would notice.
//!
//! What this file pins is therefore deliberately narrow and deliberately not
//! about wording: **every refusal in the `Hello` arm's version -> account ->
//! availability -> blocklist -> lease sequence carries the code this comment
//! promises, regardless of what its sentence says.** A future change that
//! rewords a sentence cannot fail these tests; a future change that gets the
//! *code* wrong — or forgets one — fails immediately.

mod support;

use omniagent_pty_daemon::protocol::RefusalCode;
use support::HelloResult;

/// Version skew, first of the sequence and the only terminal one.
#[tokio::test]
async fn version_skew_carries_its_code() {
    let harness = support::daemon_with_local_client().await;
    let mut old = harness.connect_remote_with_version("MacBook Pro", 1);
    assert!(matches!(old.hello().await, HelloResult::Error(_)));
    assert_eq!(old.last_error_code(), Some(RefusalCode::VersionSkew));
}

/// Host signed out — the first of the two account-check sentences, and the
/// one that must not be told "a different account" (`remote_account_isolation.rs`
/// covers that sentence directly; this file only pins the code next to it).
#[tokio::test]
async fn host_signed_out_carries_its_code() {
    let harness = support::daemon_signed_out().await;
    let mut viewer = harness.connect_remote_asserting("MacBook Pro", support::HOST_ACCOUNT_EMAIL);
    assert!(matches!(viewer.hello().await, HelloResult::Error(_)));
    assert_eq!(viewer.last_error_code(), Some(RefusalCode::HostSignedOut));
}

/// Wrong account — the account check's other sentence, same call site,
/// different code.
#[tokio::test]
async fn wrong_account_carries_its_code() {
    let harness = support::daemon_for_account(support::HOST_ACCOUNT_EMAIL).await;
    let mut stranger = harness.connect_remote_asserting("MacBook Pro", "someone@else.com");
    assert!(matches!(stranger.hello().await, HelloResult::Error(_)));
    assert_eq!(stranger.last_error_code(), Some(RefusalCode::WrongAccount));
}

/// Machine unavailable — sharing off, or (as here) no local app attached.
#[tokio::test]
async fn machine_unavailable_carries_its_code() {
    let harness = support::daemon_without_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    assert!(matches!(viewer.hello().await, HelloResult::Error(_)));
    assert_eq!(
        viewer.last_error_code(),
        Some(RefusalCode::MachineUnavailable)
    );
}

/// Blocked — the pre-registration check (`server.rs`'s first blocklist read,
/// before the lease). The post-registration re-check exists to close a race
/// too narrow to land deterministically from out here (its own comment says
/// as much: "That path needs a kick to land inside a window with no await in
/// it"), so it is not separately exercised — both sites send the same
/// [`RefusalCode::Blocked`], and this is the one this harness can reach.
#[tokio::test]
async fn blocked_carries_its_code() {
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
    assert_eq!(blocked.last_error_code(), Some(RefusalCode::Blocked));
}

/// Lease held — last of the sequence.
#[tokio::test]
async fn lease_held_carries_its_code() {
    let harness = support::daemon_with_local_client().await;
    let mut holder = harness.connect_remote("MacBook Pro");
    assert!(matches!(holder.hello().await, HelloResult::Ack(_)));

    let mut second = harness.connect_remote("Mac mini");
    assert!(matches!(second.hello().await, HelloResult::Error(_)));
    assert_eq!(second.last_error_code(), Some(RefusalCode::LeaseHeld));
}

/// The property the whole file exists for, stated directly: of the six
/// refusals above, exactly one — version skew — is the one
/// `SessionConnection.isTerminalRefusal` must treat as terminal. Nothing here
/// can enforce that Swift classification from the Rust side; what this pins
/// is the fact the classification has to key on, so that changing it on
/// purpose means changing a code, never a sentence.
#[tokio::test]
async fn only_version_skew_uses_the_terminal_code() {
    let harness = support::daemon_with_local_client().await;
    let mut old = harness.connect_remote_with_version("MacBook Pro", 1);
    assert!(matches!(old.hello().await, HelloResult::Error(_)));
    assert_eq!(old.last_error_code(), Some(RefusalCode::VersionSkew));

    let mut holder = harness.connect_remote("MacBook Pro");
    assert!(matches!(holder.hello().await, HelloResult::Ack(_)));
    let mut second = harness.connect_remote("Mac mini");
    assert!(matches!(second.hello().await, HelloResult::Error(_)));
    assert_ne!(second.last_error_code(), Some(RefusalCode::VersionSkew));
}

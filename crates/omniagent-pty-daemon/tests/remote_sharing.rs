//! `remote_sharing` is the machine-wide sharing switch (spec §2) that
//! replaces the phase-1/2 test of "does the `remote_control` projection
//! list at least one workspace" — sharing is no longer per-workspace, so
//! `remote_control_active` no longer looks at workspaces at all.

use omniagent_pty_daemon::{remote_control_active, REMOTE_SHARING_KEY};

fn temp_store() -> brain_core::Store {
    brain_core::Store::open_in_memory().unwrap()
}

#[test]
fn sharing_is_a_single_flag_not_a_workspace_count() {
    let store = temp_store();

    // Absent row: off.
    assert!(!remote_control_active(&store));

    // Explicitly off.
    store
        .set_setting(REMOTE_SHARING_KEY, r#"{"enabled":false}"#)
        .unwrap();
    assert!(!remote_control_active(&store));

    // On — with no workspaces mentioned anywhere, which is the whole point.
    store
        .set_setting(REMOTE_SHARING_KEY, r#"{"enabled":true}"#)
        .unwrap();
    assert!(remote_control_active(&store));

    // Garbage fails closed rather than inheriting the previous answer.
    store.set_setting(REMOTE_SHARING_KEY, "not json").unwrap();
    assert!(!remote_control_active(&store));
}

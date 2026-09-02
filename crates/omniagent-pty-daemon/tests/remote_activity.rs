//! Frames become rows (Task 17), then rows survive the connection (Task 18) —
//! `docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
//! §8.
//!
//! Pure unit-level tests: no daemon, no socket. `ActivityLog::record` maps a
//! [`Frame`] straight to an [`ActivityEntry`], and [`append`] is a plain
//! function over a directory — both testable without `serve_client` at all.

use std::time::{Duration, Instant, SystemTime};

use omniagent_pty_daemon::protocol::{
    encode_raw_payload, AttachPayload, BrainSearchPayload, Frame, ListDirectoryPayload,
    MessageKind, RootsAddProjectPayload, RootsReingestProjectPayload, RootsRenameProjectPayload,
    RootsSetPausedPayload, RootsStartIngestPayload, SessionIdPayload, SettingValue,
};
use omniagent_pty_daemon::{append, ActivityContext, ActivityEntry, ActivityLog, CreateSession};

fn frame(kind: MessageKind, payload: impl serde::Serialize) -> Frame {
    Frame::new(kind, 0, serde_json::to_vec(&payload).unwrap())
}

fn input_frame(session: &str, bytes: &[u8]) -> Frame {
    Frame::new(
        MessageKind::Input,
        0,
        encode_raw_payload(session, bytes).unwrap(),
    )
}

fn attach_frame(id: &str) -> Frame {
    frame(
        MessageKind::Attach,
        AttachPayload {
            id: id.into(),
            after_sequence: None,
        },
    )
}

fn interrupt_frame(id: &str) -> Frame {
    frame(MessageKind::Interrupt, SessionIdPayload { id: id.into() })
}

fn kill_frame(id: &str) -> Frame {
    frame(MessageKind::Kill, SessionIdPayload { id: id.into() })
}

fn detach_frame(id: &str) -> Frame {
    frame(MessageKind::Detach, SessionIdPayload { id: id.into() })
}

fn resize_frame(id: &str) -> Frame {
    frame(
        MessageKind::Resize,
        serde_json::json!({"id": id, "cols": 120, "rows": 40, "pixel_width": 0, "pixel_height": 0}),
    )
}

fn get_setting_frame(key: &str) -> Frame {
    frame(MessageKind::GetSetting, serde_json::json!({"key": key}))
}

fn list_sessions_frame() -> Frame {
    frame(MessageKind::ListSessions, serde_json::json!({}))
}

fn create_session_frame(id: &str, command: &[&str], cwd: Option<&str>) -> Frame {
    frame(
        MessageKind::CreateSession,
        CreateSession {
            id: id.into(),
            command: command.iter().map(|s| s.to_string()).collect(),
            cwd: cwd.map(String::from),
            env: Default::default(),
            cols: 80,
            rows: 24,
            transcript_path: None,
        },
    )
}

fn set_setting_frame(key: &str, value: &str) -> Frame {
    frame(
        MessageKind::SetSetting,
        SettingValue {
            key: key.into(),
            value: value.into(),
        },
    )
}

fn roots_add_project_frame(path: &str, name: Option<&str>) -> Frame {
    frame(
        MessageKind::RootsAddProject,
        RootsAddProjectPayload {
            path: path.into(),
            name: name.map(String::from),
        },
    )
}

fn roots_rename_project_frame(id: &str, new_label: &str) -> Frame {
    frame(
        MessageKind::RootsRenameProject,
        RootsRenameProjectPayload {
            id: id.into(),
            new_label: new_label.into(),
        },
    )
}

fn roots_set_paused_frame(project: &str, paused: bool) -> Frame {
    frame(
        MessageKind::RootsSetPaused,
        RootsSetPausedPayload {
            project: project.into(),
            paused,
        },
    )
}

fn roots_reingest_project_frame(project: &str) -> Frame {
    frame(
        MessageKind::RootsReingestProject,
        RootsReingestProjectPayload {
            project: project.into(),
        },
    )
}

fn roots_start_ingest_frame(path: &str) -> Frame {
    frame(
        MessageKind::RootsStartIngest,
        RootsStartIngestPayload { path: path.into() },
    )
}

fn roots_rebuild_frame() -> Frame {
    frame(MessageKind::RootsRebuild, serde_json::json!({}))
}

fn list_directory_frame(path: &str) -> Frame {
    frame(
        MessageKind::ListDirectory,
        ListDirectoryPayload {
            path: path.into(),
            show_hidden: false,
        },
    )
}

fn brain_search_frame(query: &str) -> Frame {
    frame(
        MessageKind::BrainSearch,
        BrainSearchPayload {
            query: query.into(),
            scope: None,
        },
    )
}

// ---------------------------------------------------------------------
// Task 17: frames become rows
// ---------------------------------------------------------------------

#[test]
fn a_typed_prompt_is_one_row_not_one_row_per_keystroke() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture(); // knows pane titles, engines, workspaces

    for byte in b"hello there" {
        assert!(log.record(&input_frame("pane-1", &[*byte]), &ctx).is_none());
    }
    let entry = log
        .record(&input_frame("pane-1", b"\r"), &ctx)
        .expect("flushed on CR");

    assert_eq!(entry.kind, "input");
    assert_eq!(entry.summary, "Sent a prompt to Terminal 1 (claude)");
    assert_eq!(entry.detail.as_deref(), Some("hello there"));
}

#[test]
fn input_flushes_after_five_seconds_of_quiet_even_without_a_return() {
    let mut log = ActivityLog::default();
    log.record(
        &input_frame("pane-1", b"partial"),
        &ActivityContext::fixture(),
    );
    let entries = log.tick(Instant::now() + Duration::from_secs(6));
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].detail.as_deref(), Some("partial"));
}

#[test]
fn rows_that_say_everything_have_no_detail_to_expand() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(&attach_frame("pane-1"), &ActivityContext::fixture())
        .unwrap();
    assert_eq!(
        entry.summary,
        "Opened Terminal 1 in Session 1 · OmniAgent-ADE"
    );
    assert_eq!(entry.detail, None);
}

#[test]
fn secrets_are_redacted_before_they_are_ever_written() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    log.record(
        &input_frame(
            "pane-1",
            b"export TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwxyz",
        ),
        &ctx,
    );
    let entry = log.record(&input_frame("pane-1", b"\r"), &ctx).unwrap();
    assert!(!entry.detail.as_deref().unwrap().contains("ghp_0123456789"));
}

#[test]
fn interrupt_flushes_whatever_was_half_typed() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    log.record(&input_frame("pane-1", b"half"), &ctx);
    let entries: Vec<_> = [log.record(&interrupt_frame("pane-1"), &ctx)]
        .into_iter()
        .flatten()
        .collect();
    assert!(entries.iter().any(|e| e.detail.as_deref() == Some("half")));
}

#[test]
fn interrupt_with_nothing_pending_still_gets_its_own_row() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(&interrupt_frame("pane-1"), &ActivityContext::fixture())
        .unwrap();
    assert_eq!(entry.kind, "interrupt");
    assert_eq!(entry.summary, "Interrupted Terminal 1");
    assert_eq!(entry.detail, None);
}

#[test]
fn kill_closes_a_named_pane() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(&kill_frame("pane-1"), &ActivityContext::fixture())
        .unwrap();
    assert_eq!(entry.kind, "kill");
    assert_eq!(entry.summary, "Closed Terminal 1");
}

#[test]
fn an_unknown_pane_id_falls_back_to_itself_rather_than_being_dropped() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    let attach = log.record(&attach_frame("mystery-pane"), &ctx).unwrap();
    assert_eq!(attach.summary, "Opened mystery-pane");
    let kill = log.record(&kill_frame("mystery-pane"), &ctx).unwrap();
    assert_eq!(kill.summary, "Closed mystery-pane");
}

#[test]
fn create_session_names_the_engine_and_the_workspace() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(
            &create_session_frame(
                "pane-9",
                &["/usr/local/bin/claude", "--resume"],
                Some("/Users/bruno/Bruno.Digital/OmniAgent-ADE"),
            ),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert_eq!(entry.kind, "create_session");
    assert_eq!(entry.summary, "Started a claude terminal in OmniAgent-ADE");
    let detail = entry.detail.unwrap();
    assert!(detail.contains("OmniAgent-ADE"));
    assert!(detail.contains("claude"));
}

#[test]
fn set_setting_layout_gets_the_friendly_wording() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(
            &set_setting_frame("layout", "{}"),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert_eq!(entry.kind, "set_setting");
    assert_eq!(entry.summary, "Changed the workspace layout");
}

/// Every other remotely-writable key (`editor_panes_native`, `roots`,
/// `persona`, …) is just as reachable as `layout` through the protocol
/// (`protected_setting_key` only blocks `remote_sharing`/`relay_device_token`/
/// `remote_control_blocked`/`auth_*`) — a `SetSetting` that changes one of
/// them must not vanish just because it isn't the one key the spec table
/// names by way of example.
#[test]
fn set_setting_on_any_other_reachable_key_still_gets_a_row() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(
            &set_setting_frame("persona", "grumpy"),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert_eq!(entry.kind, "set_setting");
    assert_eq!(entry.summary, "Changed a setting (persona)");
}

#[test]
fn roots_add_project_names_the_workspace() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(
            &roots_add_project_frame("/Users/bruno/Projects/widget", None),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert_eq!(entry.kind, "roots");
    assert_eq!(
        entry.summary,
        "Added workspace /Users/bruno/Projects/widget"
    );
    assert_eq!(entry.detail, None);
}

#[test]
fn roots_add_project_with_a_custom_name_keeps_the_path_as_detail() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(
            &roots_add_project_frame("/Users/bruno/Projects/widget", Some("Widget")),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert_eq!(entry.summary, "Added workspace Widget");
    assert_eq!(
        entry.detail.as_deref(),
        Some("/Users/bruno/Projects/widget")
    );
}

#[test]
fn roots_rename_project_says_the_new_name() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(
            &roots_rename_project_frame("proj-1", "Renamed Widget"),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert_eq!(entry.summary, "Renamed a workspace to Renamed Widget");
}

#[test]
fn roots_set_paused_says_paused_or_resumed() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    let paused = log
        .record(&roots_set_paused_frame("/proj", true), &ctx)
        .unwrap();
    assert_eq!(paused.summary, "Paused workspace /proj");
    let resumed = log
        .record(&roots_set_paused_frame("/proj", false), &ctx)
        .unwrap();
    assert_eq!(resumed.summary, "Resumed workspace /proj");
}

#[test]
fn roots_reingest_project_says_which_one() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(
            &roots_reingest_project_frame("/proj"),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert_eq!(entry.summary, "Re-ingested workspace /proj");
}

#[test]
fn roots_start_ingest_gets_a_row() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(
            &roots_start_ingest_frame("/Users/bruno/Projects"),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert_eq!(entry.kind, "roots");
}

/// Wiping and re-ingesting the whole brain is exactly the kind of thing a
/// person must be told happened to their machine.
#[test]
fn roots_rebuild_gets_a_row() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(&roots_rebuild_frame(), &ActivityContext::fixture())
        .unwrap();
    assert_eq!(entry.kind, "roots");
    assert_eq!(entry.summary, "Rebuilt the whole brain");
}

#[test]
fn list_directory_names_the_path() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(
            &list_directory_frame("/Users/bruno/Documents"),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert_eq!(entry.kind, "list_directory");
    assert_eq!(entry.summary, "Browsed /Users/bruno/Documents");
}

#[test]
fn brain_search_shows_a_short_query_in_full_with_no_detail() {
    let mut log = ActivityLog::default();
    let entry = log
        .record(
            &brain_search_frame("daemon protocol"),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert_eq!(entry.kind, "brain_search");
    assert_eq!(entry.summary, "Searched the brain for \"daemon protocol\"");
    assert_eq!(entry.detail, None);
}

#[test]
fn brain_search_truncates_a_long_query_and_keeps_the_rest_as_detail() {
    let mut log = ActivityLog::default();
    let long_query = "x".repeat(200);
    let entry = log
        .record(
            &brain_search_frame(&long_query),
            &ActivityContext::fixture(),
        )
        .unwrap();
    assert!(entry.summary.len() < long_query.len());
    assert_eq!(entry.detail.as_deref(), Some(long_query.as_str()));
}

/// Reads never produce a row: nothing happened to the machine.
#[test]
fn read_only_frames_produce_no_row() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    assert!(log.record(&list_sessions_frame(), &ctx).is_none());
    assert!(log.record(&get_setting_frame("layout"), &ctx).is_none());
}

/// `Resize` and `Detach` are deliberately silent (module doc): a live grid
/// follows the driver's window continuously, and a row per frame of a
/// window drag would be exactly the "Input 12 bytes" noise this log exists
/// to avoid; `Detach` only drops a subscription, not the session.
#[test]
fn resize_and_detach_are_deliberately_silent() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    assert!(log.record(&resize_frame("pane-1"), &ctx).is_none());
    assert!(log.record(&detach_frame("pane-1"), &ctx).is_none());
}

// ---------------------------------------------------------------------
// Task 18: the log survives the connection
// ---------------------------------------------------------------------

fn entry(kind: &'static str, summary: &str) -> ActivityEntry {
    ActivityEntry {
        ts: SystemTime::now(),
        kind,
        summary: summary.to_string(),
        detail: None,
    }
}

#[test]
fn entries_append_one_json_object_per_line() {
    let dir = tempfile::tempdir().unwrap();
    append(&entry("attach", "Opened Terminal 1"), dir.path()).unwrap();
    append(&entry("input", "Sent a prompt"), dir.path()).unwrap();

    let text = std::fs::read_to_string(dir.path().join("remote-activity.jsonl")).unwrap();
    let lines: Vec<_> = text.lines().collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(lines[0]).unwrap()["kind"],
        "attach"
    );
}

#[test]
fn the_file_rotates_once_and_keeps_exactly_one_previous() {
    let dir = tempfile::tempdir().unwrap();
    for _ in 0..40_000 {
        append(&entry("input", &"x".repeat(256)), dir.path()).unwrap();
    }
    assert!(dir.path().join("remote-activity.jsonl").exists());
    assert!(dir.path().join("remote-activity.1.jsonl").exists());
    assert!(!dir.path().join("remote-activity.2.jsonl").exists());
}

#[test]
fn a_fresh_data_dir_appends_without_error() {
    let dir = tempfile::tempdir().unwrap();
    // No prior file at all — `append` must create it rather than requiring
    // it to already exist.
    append(&entry("attach", "Opened Terminal 1"), dir.path()).unwrap();
    assert!(dir.path().join("remote-activity.jsonl").exists());
}

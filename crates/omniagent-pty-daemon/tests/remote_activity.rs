//! Frames become rows (Task 17), then rows survive the connection (Task 18) —
//! `docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
//! §8.
//!
//! Pure unit-level tests: no daemon, no socket. `ActivityLog::record` maps a
//! [`Frame`] straight to zero or more [`ActivityEntry`] values, and
//! [`append`] is a plain function over a directory — both testable without
//! `serve_client` at all.

use std::time::{Duration, Instant};

use omniagent_pty_daemon::protocol::{
    encode_raw_payload, AttachPayload, BrainGetContextPayload, BrainSearchPayload, Frame,
    ListDirectoryPayload, MessageKind, ResizePayload, RootsAddProjectPayload,
    RootsReingestProjectPayload, RootsRenameProjectPayload, RootsSetPausedPayload,
    RootsStartIngestPayload, SessionIdPayload, SettingValue,
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

fn resize_frame(id: &str, cols: u16, rows: u16) -> Frame {
    frame(
        MessageKind::Resize,
        ResizePayload {
            id: id.into(),
            cols,
            rows,
            pixel_width: 0,
            pixel_height: 0,
        },
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

fn brain_get_context_frame(project: &str) -> Frame {
    frame(
        MessageKind::BrainGetContext,
        BrainGetContextPayload {
            project: project.into(),
        },
    )
}

/// Asserts `record` produced exactly one row and returns it — most frames in
/// this table produce at most one; the multi-line `Input` tests are the
/// deliberate exception and check the `Vec` directly.
fn one(entries: Vec<ActivityEntry>) -> ActivityEntry {
    assert_eq!(
        entries.len(),
        1,
        "expected exactly one row, got {entries:?}"
    );
    entries.into_iter().next().unwrap()
}

// ---------------------------------------------------------------------
// Task 17: frames become rows
// ---------------------------------------------------------------------

#[test]
fn a_typed_prompt_is_one_row_not_one_row_per_keystroke() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture(); // knows pane titles, engines, workspaces

    for byte in b"hello there" {
        assert!(log
            .record(&input_frame("pane-1", &[*byte]), &ctx)
            .is_empty());
    }
    let entries = log.record(&input_frame("pane-1", b"\r"), &ctx);
    assert_eq!(entries.len(), 1, "flushed on CR");
    let entry = &entries[0];

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

/// A multi-line paste is the exact shape a PTY client sends when a user
/// pastes several lines at once: the whole clipboard content arrives as one
/// `Input` frame, with an embedded `\r` after every line. Losing everything
/// past the first `\r` is the under-logging failure on the most sensitive
/// text this log carries.
#[test]
fn a_multi_line_paste_in_one_frame_produces_one_row_per_line() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    let entries = log.record(
        &input_frame("pane-1", b"first line\rsecond line\rthird"),
        &ctx,
    );
    assert_eq!(entries.len(), 2, "two completed lines, one still pending");
    assert_eq!(entries[0].detail.as_deref(), Some("first line"));
    assert_eq!(entries[1].detail.as_deref(), Some("second line"));
    // "third" has no trailing `\r` yet — still buffered, not lost.
    let tail = log.tick(Instant::now() + Duration::from_secs(6));
    assert_eq!(tail.len(), 1);
    assert_eq!(tail[0].detail.as_deref(), Some("third"));
}

/// The same paste, arriving as two separate `Input` frames (a PTY client is
/// free to split writes anywhere) — the buffer must still stitch the halves
/// back into whole lines rather than losing anything at the frame boundary.
#[test]
fn a_multi_line_paste_split_across_two_frames_still_produces_every_line() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    let first = log.record(&input_frame("pane-1", b"first line\rseco"), &ctx);
    assert_eq!(first.len(), 1);
    assert_eq!(first[0].detail.as_deref(), Some("first line"));

    let second = log.record(&input_frame("pane-1", b"nd line\rthird line\r"), &ctx);
    assert_eq!(second.len(), 2);
    assert_eq!(second[0].detail.as_deref(), Some("second line"));
    assert_eq!(second[1].detail.as_deref(), Some("third line"));
}

#[test]
fn rows_that_say_everything_have_no_detail_to_expand() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(&attach_frame("pane-1"), &ActivityContext::fixture()));
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
    let entry = one(log.record(&input_frame("pane-1", b"\r"), &ctx));
    assert!(!entry.detail.as_deref().unwrap().contains("ghp_0123456789"));
}

#[test]
fn interrupt_flushes_whatever_was_half_typed() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    log.record(&input_frame("pane-1", b"half"), &ctx);
    let entries = log.record(&interrupt_frame("pane-1"), &ctx);
    assert!(entries.iter().any(|e| e.detail.as_deref() == Some("half")));
}

#[test]
fn interrupt_with_nothing_pending_still_gets_its_own_row() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(&interrupt_frame("pane-1"), &ActivityContext::fixture()));
    assert_eq!(entry.kind, "interrupt");
    assert_eq!(entry.summary, "Interrupted Terminal 1");
    assert_eq!(entry.detail, None);
}

#[test]
fn kill_closes_a_named_pane() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(&kill_frame("pane-1"), &ActivityContext::fixture()));
    assert_eq!(entry.kind, "kill");
    assert_eq!(entry.summary, "Closed Terminal 1");
}

#[test]
fn an_unknown_pane_id_falls_back_to_itself_rather_than_being_dropped() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    let attach = one(log.record(&attach_frame("mystery-pane"), &ctx));
    assert_eq!(attach.summary, "Opened mystery-pane");
    let kill = one(log.record(&kill_frame("mystery-pane"), &ctx));
    assert_eq!(kill.summary, "Closed mystery-pane");
}

#[test]
fn create_session_names_the_engine_and_the_workspace() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &create_session_frame(
            "pane-9",
            &["/usr/local/bin/claude", "--resume"],
            Some("/Users/bruno/Bruno.Digital/OmniAgent-ADE"),
        ),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.kind, "create_session");
    assert_eq!(entry.summary, "Started a claude terminal in OmniAgent-ADE");
    let detail = entry.detail.unwrap();
    assert!(detail.contains("OmniAgent-ADE"));
    assert!(detail.contains("claude"));
}

#[test]
fn set_setting_layout_gets_the_friendly_wording_and_no_detail() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &set_setting_frame("layout", "{}"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.kind, "set_setting");
    assert_eq!(entry.summary, "Changed the workspace layout");
    assert_eq!(entry.detail, None, "layout is a blob, not human-readable");
}

/// Every other remotely-writable key (`remote_control`,
/// `remote_control_workspaces`, `roots`, `persona`, …) is just as reachable
/// as `layout` through the protocol (`protected_setting_key` only blocks
/// `remote_sharing`/`relay_device_token`/`remote_control_blocked`/`auth_*`)
/// — a `SetSetting` that changes one of them must not vanish just because it
/// isn't the one key the spec table names by way of example, and the
/// redacted value itself is the auditable fact: "changed the persona" with
/// no detail does not say what it was changed to.
#[test]
fn set_setting_on_any_other_reachable_key_gets_a_row_with_the_value_in_detail() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &set_setting_frame("persona", "grumpy"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.kind, "set_setting");
    assert_eq!(entry.summary, "Changed a setting (persona)");
    assert_eq!(entry.detail.as_deref(), Some("grumpy"));
}

#[test]
fn set_setting_on_remote_control_workspaces_is_logged_with_its_redacted_value() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &set_setting_frame("remote_control_workspaces", "[\"/a\",\"/b\"]"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(
        entry.summary,
        "Changed a setting (remote_control_workspaces)"
    );
    assert_eq!(entry.detail.as_deref(), Some("[\"/a\",\"/b\"]"));
}

#[test]
fn roots_add_project_names_the_workspace() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &roots_add_project_frame("/Users/bruno/Projects/widget", None),
        &ActivityContext::fixture(),
    ));
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
    let entry = one(log.record(
        &roots_add_project_frame("/Users/bruno/Projects/widget", Some("Widget")),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.summary, "Added workspace Widget");
    assert_eq!(
        entry.detail.as_deref(),
        Some("/Users/bruno/Projects/widget")
    );
}

#[test]
fn roots_rename_project_says_the_new_name() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &roots_rename_project_frame("proj-1", "Renamed Widget"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.summary, "Renamed a workspace to Renamed Widget");
}

#[test]
fn roots_set_paused_says_paused_or_resumed() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    let paused = one(log.record(&roots_set_paused_frame("/proj", true), &ctx));
    assert_eq!(paused.summary, "Paused workspace /proj");
    let resumed = one(log.record(&roots_set_paused_frame("/proj", false), &ctx));
    assert_eq!(resumed.summary, "Resumed workspace /proj");
}

#[test]
fn roots_reingest_project_says_which_one() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &roots_reingest_project_frame("/proj"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.summary, "Re-ingested workspace /proj");
}

#[test]
fn roots_start_ingest_gets_a_row() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &roots_start_ingest_frame("/Users/bruno/Projects"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.kind, "roots");
}

/// Wiping and re-ingesting the whole brain is exactly the kind of thing a
/// person must be told happened to their machine.
#[test]
fn roots_rebuild_gets_a_row() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(&roots_rebuild_frame(), &ActivityContext::fixture()));
    assert_eq!(entry.kind, "roots");
    assert_eq!(entry.summary, "Rebuilt the whole brain");
}

#[test]
fn list_directory_names_the_path() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &list_directory_frame("/Users/bruno/Documents"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.kind, "list_directory");
    assert_eq!(entry.summary, "Browsed /Users/bruno/Documents");
}

/// `BrainGetContext` hands the remote client brain content — the project's
/// summary, decisions, notes — the same disclosure `ListDirectory` and
/// `BrainSearch` are already logged for. Leaving it silent while those two
/// are logged is an inconsistent read policy.
#[test]
fn brain_get_context_is_logged_like_the_other_disclosing_reads() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &brain_get_context_frame("OmniAgent-ADE"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.kind, "brain_get_context");
    assert_eq!(entry.summary, "Read the brief for OmniAgent-ADE");
}

#[test]
fn brain_search_shows_a_short_query_in_full_with_no_detail() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &brain_search_frame("daemon protocol"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.kind, "brain_search");
    assert_eq!(entry.summary, "Searched the brain for \"daemon protocol\"");
    assert_eq!(entry.detail, None);
}

#[test]
fn brain_search_truncates_a_long_query_and_keeps_the_rest_as_detail() {
    let mut log = ActivityLog::default();
    let long_query = "x".repeat(200);
    let entry = one(log.record(
        &brain_search_frame(&long_query),
        &ActivityContext::fixture(),
    ));
    assert!(entry.summary.len() < long_query.len());
    assert_eq!(entry.detail.as_deref(), Some(long_query.as_str()));
}

/// Reads never produce a row: nothing happened to the machine.
#[test]
fn read_only_frames_produce_no_row() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    assert!(log.record(&list_sessions_frame(), &ctx).is_empty());
    assert!(log.record(&get_setting_frame("layout"), &ctx).is_empty());
}

/// `Detach` is deliberately silent (module doc): it drops a subscription,
/// not the session underneath it.
#[test]
fn detach_is_deliberately_silent() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    assert!(log.record(&detach_frame("pane-1"), &ctx).is_empty());
}

// -- Resize: coalesced, not silent, and not immediate ------------------

/// `Resize` really does mutate the host (`session.resize`'s ioctl), so it
/// must not be silent — but a single frame of a drag is not itself the
/// story: the row is the settled size, once the drag stops.
#[test]
fn a_single_resize_produces_no_immediate_row() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    assert!(log
        .record(&resize_frame("pane-1", 120, 40), &ctx)
        .is_empty());
}

#[test]
fn resize_settles_into_one_row_after_quiet() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    log.record(&resize_frame("pane-1", 120, 40), &ctx);
    let entries = log.tick(Instant::now() + Duration::from_secs(6));
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].kind, "resize");
    assert_eq!(entries[0].summary, "Resized Terminal 1 to 120x40");
}

/// A drag sends many `Resize` frames; the settled row must reflect the final
/// size, not the first one, and must still be exactly one row.
#[test]
fn rapid_resizes_coalesce_to_the_final_size() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    for (cols, rows) in [(100, 30), (110, 35), (120, 40)] {
        log.record(&resize_frame("pane-1", cols, rows), &ctx);
    }
    let entries = log.tick(Instant::now() + Duration::from_secs(6));
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].summary, "Resized Terminal 1 to 120x40");
}

// ---------------------------------------------------------------------
// flush_all: a dropped connection must not erase what was pending
// ---------------------------------------------------------------------

#[test]
fn flush_all_recovers_input_left_pending_when_a_connection_closes() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    log.record(&input_frame("pane-1", b"never sent"), &ctx);
    let entries = log.flush_all();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].kind, "input");
    assert_eq!(entries[0].detail.as_deref(), Some("never sent"));
    // Nothing left pending after a full flush.
    assert!(log.flush_all().is_empty());
}

#[test]
fn flush_all_also_recovers_an_unsettled_resize() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    log.record(&resize_frame("pane-1", 90, 20), &ctx);
    let entries = log.flush_all();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].kind, "resize");
    assert_eq!(entries[0].summary, "Resized Terminal 1 to 90x20");
}

/// The whole point: a CR-triggered row and a connection-close-triggered row
/// for the identical keystrokes must read identically, because the pane name
/// was resolved once, at push time, not re-derived depending on how the line
/// happened to end.
#[test]
fn flush_all_names_the_pane_exactly_like_a_cr_flush_does() {
    let mut cr_log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    cr_log.record(&input_frame("pane-1", b"same text"), &ctx);
    let cr_entry = one(cr_log.record(&input_frame("pane-1", b"\r"), &ctx));

    let mut closed_log = ActivityLog::default();
    closed_log.record(&input_frame("pane-1", b"same text"), &ctx);
    let closed_entries = closed_log.flush_all();
    assert_eq!(closed_entries.len(), 1);

    assert_eq!(cr_entry.summary, closed_entries[0].summary);
    assert_eq!(cr_entry.summary, "Sent a prompt to Terminal 1 (claude)");
}

/// The same discipline pinned directly against the 5 s quiet path: it must
/// not fall back to the raw session id just because nothing ended the line.
#[test]
fn a_five_second_quiet_flush_names_the_pane_exactly_like_a_cr_flush_does() {
    let ctx = ActivityContext::fixture();
    let mut cr_log = ActivityLog::default();
    cr_log.record(&input_frame("pane-1", b"same text"), &ctx);
    let cr_entry = one(cr_log.record(&input_frame("pane-1", b"\r"), &ctx));

    let mut quiet_log = ActivityLog::default();
    quiet_log.record(&input_frame("pane-1", b"same text"), &ctx);
    let quiet_entries = quiet_log.tick(Instant::now() + Duration::from_secs(6));
    assert_eq!(quiet_entries.len(), 1);

    assert_eq!(cr_entry.summary, quiet_entries[0].summary);
}

// ---------------------------------------------------------------------
// ActivityEntry: RFC 3339 timestamps, round-trippable
// ---------------------------------------------------------------------

/// Task 20 reads `remote-activity.jsonl` back to render history: the wire
/// format must be a plain, human-readable timestamp (not serde's default
/// `SystemTime` shape), and `ActivityEntry` must actually deserialize.
#[test]
fn the_timestamp_is_rfc3339_on_the_wire_and_round_trips() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(&kill_frame("pane-1"), &ActivityContext::fixture()));

    let json = serde_json::to_string(&entry).unwrap();
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    let ts = value["ts"]
        .as_str()
        .expect("ts must be a string on the wire");
    assert!(ts.contains('T'), "expected an RFC 3339 timestamp, got {ts}");

    let round_tripped: ActivityEntry = serde_json::from_str(&json).unwrap();
    assert_eq!(round_tripped, entry);
}

// ---------------------------------------------------------------------
// Task 18: the log survives the connection
// ---------------------------------------------------------------------

fn entry(kind: &'static str, summary: &str) -> ActivityEntry {
    ActivityEntry {
        ts: std::time::SystemTime::now(),
        kind: kind.to_string(),
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
fn the_file_rotates_once_keeps_exactly_one_previous_and_drops_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let total = 40_000usize;
    for i in 0..total {
        // A unique, parseable marker per entry — identical entries (the
        // original shape of this test) cannot tell a lossless rotation from
        // one that silently truncates or duplicates at the boundary.
        let summary = format!("row {i} {}", "x".repeat(240));
        append(&entry("input", &summary), dir.path()).unwrap();
    }
    let current_path = dir.path().join("remote-activity.jsonl");
    let rotated_path = dir.path().join("remote-activity.1.jsonl");
    assert!(current_path.exists());
    assert!(
        rotated_path.exists(),
        "expected a rotation to have happened"
    );
    assert!(!dir.path().join("remote-activity.2.jsonl").exists());

    let mut indices = Vec::with_capacity(total);
    for path in [&rotated_path, &current_path] {
        let text = std::fs::read_to_string(path).unwrap();
        for line in text.lines() {
            let value: serde_json::Value = serde_json::from_str(line).unwrap();
            let summary = value["summary"].as_str().unwrap();
            let index: usize = summary.split_whitespace().nth(1).unwrap().parse().unwrap();
            indices.push(index);
        }
    }
    // Every entry appended, exactly once, in the order it was written — the
    // rotated file holds the older half and the current file the newer half,
    // and rotation must be lossless and order-preserving across that split.
    let expected: Vec<usize> = (0..total).collect();
    assert_eq!(indices, expected);
}

#[test]
fn a_fresh_data_dir_appends_without_error() {
    let dir = tempfile::tempdir().unwrap();
    // No prior file at all — `append` must create it rather than requiring
    // it to already exist.
    append(&entry("attach", "Opened Terminal 1"), dir.path()).unwrap();
    assert!(dir.path().join("remote-activity.jsonl").exists());
}

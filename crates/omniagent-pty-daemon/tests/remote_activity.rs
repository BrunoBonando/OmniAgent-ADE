//! Frames become rows (Task 17), then rows survive the connection (Task 18),
//! then reach the host app (Task 19) —
//! `docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
//! §8.
//!
//! Most of this file is pure unit-level tests: no daemon, no socket.
//! `ActivityLog::record` maps a [`Frame`] straight to zero or more
//! [`ActivityEntry`] values, and [`append`] is a plain function over a
//! directory — both testable without `serve_client` at all. The Task 19
//! section at the bottom is the one place this file runs a real daemon: it is
//! the only way to pin *who* gets pushed a `RemoteActivity` frame, since that
//! is a property of `serve_client`'s dispatch loop, not of `ActivityLog`
//! itself.

mod support;

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

/// The two bidi isolates a field is wrapped in, spelled out here rather than
/// imported from the daemon. A test that asks the code under test what a
/// field looks like agrees with any change to it — including one that drops
/// the isolates altogether.
const FSI: char = '\u{2068}';
const PDI: char = '\u{2069}';

/// One field, exactly as a row must render it: `"` U+2068 text U+2069 `"`.
fn q(content: &str) -> String {
    format!("\"{FSI}{content}{PDI}\"")
}

/// Splits a row summary into its template — every field replaced by `{}` —
/// and the fields' contents, **proving the row is well formed as it goes**
/// (fix round 4). This is the assertion the whole round is about: a row's
/// structure must be recoverable no matter what a viewer put in a field.
///
/// Well formed means: every `"` opens a field and is immediately followed by
/// U+2068; the field's text runs to the first U+2069, which is immediately
/// followed by the closing `"`; neither isolate nor a quote appears anywhere
/// else — not in a field's text, and not loose in the template; and every
/// character *outside* a field is one of the daemon's own words.
///
/// That last check is what stops a value from hiding as template text. A
/// summary built by interpolating a raw string — the mistake this round's
/// exhaustive `MessageKind` test exists to catch — would put viewer text
/// where the template goes, and the row would still parse cleanly into its
/// (fewer) fields without it.
fn parse_row(summary: &str) -> (String, Vec<String>) {
    let chars: Vec<char> = summary.chars().collect();
    let mut template = String::new();
    let mut fields = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] != '"' {
            assert!(
                chars[i] != FSI && chars[i] != PDI,
                "a bare isolate U+{:04X} at {i} is outside any field in {summary:?}",
                chars[i] as u32
            );
            // The row templates in `activity.rs`/`server.rs` are English
            // words and ASCII punctuation, plus exactly two non-ASCII
            // characters of their own: `·` between a pane, its session and
            // its workspace, and `…` after a truncated brain query.
            //
            // `?` is excluded from that ASCII (fix round 5), and it is the
            // half of this check that catches the *sanitized* mistake. No
            // template contains a question mark, and `?` is precisely what
            // the sanitizer leaves behind — so a value that was cleaned but
            // never wrapped shows up here, where the ASCII rule alone would
            // wave it through: `HOSTILE` sanitizes to pure ASCII.
            assert!(
                (chars[i].is_ascii() && chars[i] != '?') || chars[i] == '·' || chars[i] == '…',
                "U+{:04X} ({:?}) is outside every field and is not one of the row \
                 format's own characters — an interpolated value that skipped \
                 `display_field`? — in {summary:?}",
                chars[i] as u32,
                chars[i]
            );
            template.push(chars[i]);
            i += 1;
            continue;
        }
        i += 1;
        assert_eq!(
            chars.get(i).copied(),
            Some(FSI),
            "a field's opening quote is not followed by U+2068 in {summary:?}"
        );
        i += 1;
        let mut text = String::new();
        while let Some(&c) = chars.get(i) {
            if c == PDI {
                break;
            }
            assert!(
                c != '"' && c != FSI,
                "U+{:04X} escaped its field's delimiters in {summary:?}",
                c as u32
            );
            text.push(c);
            i += 1;
        }
        assert_eq!(
            chars.get(i).copied(),
            Some(PDI),
            "a field is never closed in {summary:?}"
        );
        i += 1;
        assert_eq!(
            chars.get(i).copied(),
            Some('"'),
            "a field's U+2069 is not followed by its closing quote in {summary:?}"
        );
        i += 1;
        template.push_str("{}");
        fields.push(text);
    }
    (template, fields)
}

/// The allowlist, **spelled out here** rather than asked of the production
/// predicate (fix round 4, the same correction `server.rs`'s own copy got): a
/// Unicode letter, mark or number, one of seven punctuation marks (the five
/// an ordinary name needs, plus `/` for paths and `…` for the sanitizer's own
/// truncation marker), or the `?` a disallowed codepoint was replaced with.
fn assert_only_allowed_chars(text: &str) {
    let letter_mark_or_number = regex::Regex::new(r"^[\p{L}\p{M}\p{N}]$").unwrap();
    for c in text.chars() {
        assert!(
            c == '?'
                || matches!(c, ' ' | '-' | '_' | '.' | '\'' | '/' | '…')
                || letter_mark_or_number.is_match(c.encode_utf8(&mut [0; 4])),
            "disallowed codepoint U+{:04X} ({c:?}) survived sanitization in {text:?}",
            c as u32
        );
    }
}

/// Parses a row and checks every field's content against the allowlist,
/// returning the template so a caller can pin the row's shape. The two
/// halves of what a row has to guarantee, in one call: the structure is
/// recoverable, and nothing inside a field is a character the sanitizer was
/// supposed to have replaced.
fn assert_well_formed(summary: &str) -> (String, Vec<String>) {
    let (template, fields) = parse_row(summary);
    for field in &fields {
        assert_only_allowed_chars(field);
    }
    (template, fields)
}

/// A machine name shaped like the row format itself — fullwidth parens, a
/// dot lookalike, a line separator, a bidi override — touching every
/// category fix round 2 named. Reused here for every OTHER
/// viewer-influenceable field, since the threat is identical regardless of
/// which field carries it.
const HOSTILE: &str =
    "Air\u{ff08}1.2.3.4\u{ff09}\u{ff09}\u{2022}Disconnected\u{2028}\u{202e}3m 00s";

/// A `layout` row (`ActivityContext::from_layout`'s own input shape) whose
/// pane title, session label, workspace name, and engine are all [`HOSTILE`]
/// — every field the lease-holding viewer can set through `SetSetting`
/// (`layout` is deliberately not a protected key) and that
/// `ActivityContext` resolves into a summary.
fn hostile_layout_ctx() -> ActivityContext {
    let layout = serde_json::json!({
        "tabs": [{
            "project": format!("/Users/bruno/{HOSTILE}"),
            "engine": HOSTILE,
            "cwd": "/tmp",
            "id": "pane-1",
            "group": "g1",
            "label": HOSTILE,
            "groupLabel": HOSTILE,
        }]
    });
    ActivityContext::from_layout(Some(&layout.to_string()))
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
    assert_eq!(
        entry.summary,
        format!("Sent a prompt to {} ({})", q("Terminal 1"), q("claude"))
    );
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

/// Carried-over item D: `\r\n` must count as one terminator, not two — the
/// `\n` must not leak into the next line as a stray leading newline, and must
/// not linger as its own whitespace-only row once the connection eventually
/// flushes.
#[test]
fn crlf_terminated_lines_produce_clean_rows_with_no_stray_newline() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    let entries = log.record(&input_frame("pane-1", b"line1\r\nline2\r\n"), &ctx);
    assert_eq!(entries.len(), 2, "two CRLF-terminated lines");
    assert_eq!(entries[0].detail.as_deref(), Some("line1"));
    assert_eq!(entries[1].detail.as_deref(), Some("line2"));
    // Nothing pending, and nothing whitespace-only was ever buffered up
    // behind it — a full flush must find nothing left to say.
    assert!(log.flush_all().is_empty());
}

#[test]
fn rows_that_say_everything_have_no_detail_to_expand() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(&attach_frame("pane-1"), &ActivityContext::fixture()));
    assert_eq!(
        entry.summary,
        format!(
            "Opened {} in {} · {}",
            q("Terminal 1"),
            q("Session 1"),
            q("OmniAgent-ADE")
        )
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
    assert_eq!(entry.summary, format!("Interrupted {}", q("Terminal 1")));
    assert_eq!(entry.detail, None);
}

#[test]
fn kill_closes_a_named_pane() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(&kill_frame("pane-1"), &ActivityContext::fixture()));
    assert_eq!(entry.kind, "kill");
    assert_eq!(entry.summary, format!("Closed {}", q("Terminal 1")));
}

#[test]
fn an_unknown_pane_id_falls_back_to_itself_rather_than_being_dropped() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    let attach = one(log.record(&attach_frame("mystery-pane"), &ctx));
    assert_eq!(attach.summary, format!("Opened {}", q("mystery-pane")));
    let kill = one(log.record(&kill_frame("mystery-pane"), &ctx));
    assert_eq!(kill.summary, format!("Closed {}", q("mystery-pane")));
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
    assert_eq!(
        entry.summary,
        format!(
            "Started a {} terminal in {}",
            q("claude"),
            q("OmniAgent-ADE")
        )
    );
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
    assert_eq!(
        entry.summary,
        format!("Changed a setting ({})", q("persona"))
    );
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
        format!("Changed a setting ({})", q("remote_control_workspaces"))
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
        format!("Added workspace {}", q("/Users/bruno/Projects/widget"))
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
    assert_eq!(entry.summary, format!("Added workspace {}", q("Widget")));
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
    assert_eq!(
        entry.summary,
        format!("Renamed a workspace to {}", q("Renamed Widget"))
    );
}

#[test]
fn roots_set_paused_says_paused_or_resumed() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    let paused = one(log.record(&roots_set_paused_frame("/proj", true), &ctx));
    assert_eq!(paused.summary, format!("Paused workspace {}", q("/proj")));
    let resumed = one(log.record(&roots_set_paused_frame("/proj", false), &ctx));
    assert_eq!(resumed.summary, format!("Resumed workspace {}", q("/proj")));
}

#[test]
fn roots_reingest_project_says_which_one() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &roots_reingest_project_frame("/proj"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(
        entry.summary,
        format!("Re-ingested workspace {}", q("/proj"))
    );
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
    assert_eq!(
        entry.summary,
        format!("Browsed {}", q("/Users/bruno/Documents"))
    );
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
    assert_eq!(
        entry.summary,
        format!("Read the brief for {}", q("OmniAgent-ADE"))
    );
}

#[test]
fn brain_search_shows_a_short_query_in_full_with_no_detail() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &brain_search_frame("daemon protocol"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(entry.kind, "brain_search");
    assert_eq!(
        entry.summary,
        format!("Searched the brain for {}", q("daemon protocol"))
    );
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
    assert_eq!(
        entries[0].summary,
        format!("Resized {} to 120x40", q("Terminal 1"))
    );
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
    assert_eq!(
        entries[0].summary,
        format!("Resized {} to 120x40", q("Terminal 1"))
    );
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
    assert_eq!(
        entries[0].summary,
        format!("Resized {} to 90x20", q("Terminal 1"))
    );
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
    assert_eq!(
        cr_entry.summary,
        format!("Sent a prompt to {} ({})", q("Terminal 1"), q("claude"))
    );
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
// Fix round 3, ITEM 2: every viewer-influenceable string that reaches a
// summary is sanitized — not only the machine name fix round 2 already
// closed. `layout` is the door the review named (pane titles, session
// labels, workspace names, engines — all viewer-writable via `SetSetting`),
// but the sweep in this section also covers every raw frame-payload field
// (a `Resize`/`Interrupt`/`Kill`'s own session id when it names no known
// pane, `CreateSession`'s `cwd`, `SetSetting`'s own `key`, and every
// `Roots*`/`ListDirectory`/`BrainSearch`/`BrainGetContext` argument) that
// lands in a summary the same way.
// ---------------------------------------------------------------------

#[test]
fn hostile_pane_title_session_and_workspace_from_layout_cannot_forge_the_attach_row() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(&attach_frame("pane-1"), &hostile_layout_ctx()));
    // The row still parses as exactly three fields with this template's own
    // words between them, whatever the hostile text did inside them.
    let (template, fields) = assert_well_formed(&entry.summary);
    assert_eq!(template, "Opened {} in {} · {}");
    assert_eq!(fields.len(), 3, "{}", entry.summary);
}

/// `Resize`/`Interrupt`/`Kill` all resolve their pane name through
/// `ActivityContext::pane_title`, the same lookup `Attach` uses — one test
/// stands for all three rather than repeating the same shape three times.
#[test]
fn hostile_pane_title_from_layout_cannot_forge_the_resize_interrupt_or_kill_row() {
    let ctx = hostile_layout_ctx();

    let mut resize_log = ActivityLog::default();
    resize_log.record(&resize_frame("pane-1", 10, 10), &ctx);
    let resized = &resize_log.tick(Instant::now() + Duration::from_secs(6))[0];
    assert_eq!(
        assert_well_formed(&resized.summary).0,
        "Resized {} to 10x10"
    );

    let mut interrupt_log = ActivityLog::default();
    let interrupted = one(interrupt_log.record(&interrupt_frame("pane-1"), &ctx));
    assert_eq!(assert_well_formed(&interrupted.summary).0, "Interrupted {}");

    let mut kill_log = ActivityLog::default();
    let killed = one(kill_log.record(&kill_frame("pane-1"), &ctx));
    assert_eq!(assert_well_formed(&killed.summary).0, "Closed {}");
}

#[test]
fn hostile_engine_from_layout_cannot_forge_the_input_row_summary() {
    let mut log = ActivityLog::default();
    let ctx = hostile_layout_ctx();
    log.record(&input_frame("pane-1", b"hi"), &ctx);
    let entry = one(log.record(&input_frame("pane-1", b"\r"), &ctx));
    // The engine is its own field, not part of the title's: the parentheses
    // are the template's own, so a hostile engine name cannot swallow them.
    let (template, fields) = assert_well_formed(&entry.summary);
    assert_eq!(template, "Sent a prompt to {} ({})");
    assert_eq!(fields.len(), 2, "{}", entry.summary);
}

/// Not a `layout` field at all — `Attach`/`Resize`/`Interrupt`/`Kill`/`Input`
/// each carry their own session/pane id directly on the frame, and an id
/// naming no known pane falls back to itself rather than being dropped
/// (`an_unknown_pane_id_falls_back_to_itself_rather_than_being_dropped`
/// above). That id is exactly as viewer-chosen as a `layout` field, and
/// unlike one, is never sourced from anything the daemon itself wrote — it
/// must be sanitized at the same fallback, not only the looked-up case.
#[test]
fn a_hostile_unknown_pane_id_is_sanitized_rather_than_forging_the_row() {
    let mut log = ActivityLog::default();
    let ctx = ActivityContext::fixture();
    let attach = one(log.record(&attach_frame(HOSTILE), &ctx));
    assert_eq!(assert_well_formed(&attach.summary).0, "Opened {}");
}

#[test]
fn hostile_cwd_cannot_forge_the_create_session_row_summary() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &create_session_frame(
            "pane-9",
            &["/usr/local/bin/claude"],
            Some(&format!("/Users/bruno/{HOSTILE}")),
        ),
        &ActivityContext::fixture(),
    ));
    assert_eq!(
        assert_well_formed(&entry.summary).0,
        "Started a {} terminal in {}"
    );
}

#[test]
fn hostile_setting_key_cannot_forge_the_set_setting_row_summary() {
    let mut log = ActivityLog::default();
    let entry = one(log.record(
        &set_setting_frame(HOSTILE, "value"),
        &ActivityContext::fixture(),
    ));
    assert_eq!(
        assert_well_formed(&entry.summary).0,
        "Changed a setting ({})"
    );
    // `detail` is redacted but never sanitized (it is the auditable fact,
    // not display text) — unaffected by this fix.
    assert_eq!(entry.detail.as_deref(), Some("value"));
}

/// Every one of these follows the identical shape — one viewer-supplied
/// frame field, redacted, then interpolated into a one-line summary — so one
/// table of cases stands for all of them rather than seven near-identical
/// tests.
#[test]
fn hostile_roots_list_directory_and_brain_get_context_fields_cannot_forge_their_rows() {
    let ctx = ActivityContext::fixture();
    let cases: Vec<(&str, Frame)> = vec![
        ("roots_start_ingest.path", roots_start_ingest_frame(HOSTILE)),
        (
            "roots_add_project.path",
            roots_add_project_frame(HOSTILE, None),
        ),
        (
            "roots_add_project.name",
            roots_add_project_frame("/proj", Some(HOSTILE)),
        ),
        (
            "roots_rename_project.new_label",
            roots_rename_project_frame("proj-1", HOSTILE),
        ),
        (
            "roots_set_paused.project",
            roots_set_paused_frame(HOSTILE, true),
        ),
        (
            "roots_reingest_project.project",
            roots_reingest_project_frame(HOSTILE),
        ),
        ("list_directory.path", list_directory_frame(HOSTILE)),
        (
            "brain_get_context.project",
            brain_get_context_frame(HOSTILE),
        ),
    ];
    for (label, frame) in cases {
        let mut log = ActivityLog::default();
        let entry = one(log.record(&frame, &ctx));
        let (template, fields) = assert_well_formed(&entry.summary);
        assert_eq!(fields.len(), 1, "{label}: {}", entry.summary);
        assert!(
            template.ends_with("{}") || template.contains("{} "),
            "{label}: the hostile value must stay one delimited field: {template:?}"
        );
        assert!(
            !entry.summary.contains('\u{202e}'),
            "{label}: bidi override survived into {}",
            entry.summary
        );
    }
}

#[test]
fn hostile_brain_search_query_cannot_forge_the_row_summary_short_or_long() {
    let ctx = ActivityContext::fixture();

    let mut short_log = ActivityLog::default();
    let short = one(short_log.record(&brain_search_frame(HOSTILE), &ctx));
    assert_eq!(
        assert_well_formed(&short.summary).0,
        "Searched the brain for {}"
    );

    let long_hostile = format!("{HOSTILE}{}", "x".repeat(100));
    let mut long_log = ActivityLog::default();
    let long = one(long_log.record(&brain_search_frame(&long_hostile), &ctx));
    // The truncation ellipsis is the template's, outside the field's quotes,
    // so a query cannot pretend the daemon shortened it — or hide that it
    // did.
    assert_eq!(
        assert_well_formed(&long.summary).0,
        "Searched the brain for {}…"
    );
    // `detail` keeps the full, redacted-but-unsanitized query — the
    // auditable fact this fix must never touch.
    assert_eq!(long.detail.as_deref(), Some(long_hostile.as_str()));
}

/// The other half of "the same sanitizer" (fix round 3, ITEM 1): widening
/// the allowlist to Unicode letters must not have broken the legitimate case
/// — a real international pane title still reads correctly, not as
/// "Bj?rns Terminal".
#[test]
fn a_genuine_unicode_letter_in_a_pane_title_survives_into_the_summary() {
    let layout = serde_json::json!({
        "tabs": [{
            "project": "/Users/bruno/OmniAgent-ADE",
            "engine": "claude",
            "cwd": "/tmp",
            "id": "pane-1",
            "group": "g1",
            "label": "Björns Terminal",
        }]
    });
    let ctx = ActivityContext::from_layout(Some(&layout.to_string()));
    let mut log = ActivityLog::default();
    let entry = one(log.record(&attach_frame("pane-1"), &ctx));
    assert!(
        entry.summary.contains("Björns Terminal"),
        "{}",
        entry.summary
    );
}

// ---------------------------------------------------------------------
// Fix round 4: the row's structure is guaranteed at EMISSION, not by
// filtering the input.
//
// The three rounds before this one tried to make a viewer-supplied string
// incapable of looking like the row format. That cannot work, and these
// tests are the proof: U+A78F LATIN LETTER SINOLOGICAL DOT and U+1427
// CANADIAN SYLLABICS FINAL MIDDLE DOT are `\p{L}` and render as the `·` the
// format separates fields with; U+02BA MODIFIER LETTER DOUBLE PRIME is
// `\p{Lm}` and renders as `"`; a Hebrew letter is `\p{Lo}` and reorders the
// neutral characters around it under the plain Bidi Algorithm with no
// control character involved. Every one of them is a real letter that a real
// machine name may contain, so every one of them survives sanitization —
// deliberately. What must hold instead is that each stays *inside its own
// field*, which is what `assert_well_formed` checks.
// ---------------------------------------------------------------------

/// One pane, titled whatever the caller likes, in a session and workspace
/// with ordinary names — so a test can put hostile text in exactly one field
/// and read the row's shape around it.
fn layout_ctx_titled(title: &str) -> ActivityContext {
    let layout = serde_json::json!({
        "tabs": [{
            "project": "/Users/bruno/OmniAgent-ADE",
            "engine": "claude",
            "cwd": "/tmp",
            "id": "pane-1",
            "group": "g1",
            "label": title,
            "groupLabel": "Session 1",
        }]
    });
    ActivityContext::from_layout(Some(&layout.to_string()))
}

/// Both of these are LETTERS that look exactly like the ` · ` this row
/// format puts between a pane, its session and its workspace. No allowlist
/// that admits real machine names can exclude them, so the row must not care
/// that they are there: it still parses as its own three fields, and the
/// lookalike is visibly inside the first one.
#[test]
fn letters_that_render_as_the_row_separator_stay_inside_their_field() {
    for (dot, name) in [
        ('\u{a78f}', "LATIN LETTER SINOLOGICAL DOT"),
        ('\u{1427}', "CANADIAN SYLLABICS FINAL MIDDLE DOT"),
    ] {
        let title = format!("Air {dot} Session 9 {dot} Other Workspace");
        let mut log = ActivityLog::default();
        let entry = one(log.record(&attach_frame("pane-1"), &layout_ctx_titled(&title)));

        let (template, fields) = assert_well_formed(&entry.summary);
        assert_eq!(
            template, "Opened {} in {} · {}",
            "{name}: {}",
            entry.summary
        );
        assert_eq!(
            fields,
            vec![
                title.clone(),
                "Session 1".to_string(),
                "OmniAgent-ADE".to_string()
            ],
            "{name}: the row must still name exactly its own three fields"
        );
        assert!(
            fields[0].contains(dot),
            "{name} is a letter and must survive into the title, contained rather than stripped"
        );
    }
}

/// U+02BA is a LETTER that renders as `"` — which is why round 2's claim,
/// written into `sanitize_machine_name`'s own doc, that "a quoted field can
/// never contain a quote" was false. It still cannot contain the ASCII quote
/// that delimits it, and that is the only claim the format now rests on: the
/// row parses into exactly its fields regardless.
#[test]
fn a_letter_that_renders_as_a_quote_stays_inside_its_field() {
    let title = "Air\u{2ba} (1.2.3.4)\u{2ba}";
    let mut log = ActivityLog::default();
    let entry = one(log.record(&attach_frame("pane-1"), &layout_ctx_titled(title)));

    let (template, fields) = assert_well_formed(&entry.summary);
    assert_eq!(template, "Opened {} in {} · {}");
    // The parens are `?` (they are not in the allowlist, and never were);
    // the two quote *lookalikes* are letters and survive, contained.
    assert_eq!(fields[0], "Air\u{2ba} ?1.2.3.4?\u{2ba}");
    assert_eq!(
        entry.summary.matches('"').count(),
        6,
        "three fields, two quotes each — a quote lookalike must not add one: {}",
        entry.summary
    );
}

/// A strong right-to-left LETTER reorders the neutral characters around it
/// by the plain Bidi Algorithm — the parentheses and quotes this row format
/// puts around the *relay-asserted* IP address included. That is the attack
/// this round's isolates exist for, and it needs no control character, so
/// there was never a way to filter it out of the input.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_right_to_left_machine_name_cannot_displace_the_relay_asserted_ip() {
    let mut harness = support::daemon_with_local_client().await;
    // Hebrew, plus the characters an RTL run would drag around with it.
    let mut viewer = harness.connect_remote("\u{5d0}\u{5d1}\u{5d2} (1.2.3.4) Air");
    viewer.hello().await;

    let opened = harness.local().wait_for_activity("connected").await;
    let (template, fields) = assert_well_formed(&opened.summary);
    assert_eq!(template, "Connected from {} ({})");
    assert_eq!(
        fields[1], "203.0.113.7",
        "the relay-asserted IP is its own field and stays whole: {}",
        opened.summary
    );
    assert!(
        fields[0].contains('\u{5d0}'),
        "a Hebrew letter is a letter and must survive, isolated rather than stripped: {}",
        fields[0]
    );
    // The isolate that contains it is the daemon's own, and there is exactly
    // one pair per field — a viewer cannot add or close one, because U+2069
    // is `Cf` and never survives sanitization.
    assert_eq!(opened.summary.matches('\u{2068}').count(), 2);
    assert_eq!(opened.summary.matches('\u{2069}').count(), 2);
}

/// Fix round 5: **the guard's own hole, pinned.**
///
/// `parse_row` catches a raw interpolation because a hostile value is full of
/// non-ASCII. It very nearly missed the *sanitized* one: `HOSTILE` sanitizes
/// to pure ASCII, so an arm that cleaned a value and then interpolated it
/// without wrapping — the mistake a new `MessageKind` invites, because the
/// sanitizer is the function whose name sounds right — would have emitted a
/// zero-field row that the guard nodded through. Excluding `?` from the
/// template's alphabet closes it, and this test is what stops the exclusion
/// being quietly relaxed later by someone tidying up.
///
/// Asserted by *failing* the guard on purpose, since a guard nobody has seen
/// reject anything is a guard nobody knows works.
#[test]
fn the_guard_rejects_a_row_whose_value_was_sanitized_but_never_wrapped() {
    // Exactly what `format!("Browsed {}", sanitize_display_text(hostile))`
    // would have produced: no delimiters, and pure ASCII.
    let unwrapped = "Browsed Air?1.2.3.4??Disconnected??3m 00s";
    let rejected = std::panic::catch_unwind(|| parse_row(unwrapped)).is_err();
    assert!(
        rejected,
        "a sanitized-but-unwrapped value must not pass as template text: {unwrapped:?}"
    );

    // And the guard is not simply rejecting everything: the wrapped form of
    // the same value passes, with its `?`s inside the field where they
    // belong.
    let (template, fields) = parse_row(&format!("Browsed {}", q("Air?1.2.3.4??Disconnected")));
    assert_eq!(template, "Browsed {}");
    assert_eq!(fields, vec!["Air?1.2.3.4??Disconnected".to_string()]);
}

/// The isolates only hold because a field cannot contain one. U+2068/U+2069
/// are `Cf`: not a letter, mark, number or one of the seven punctuation
/// marks, so they are replaced before they can reach a row — which is the
/// whole reason the input sanitizer is still worth keeping.
#[test]
fn a_viewer_supplied_isolate_cannot_open_or_close_a_field_of_its_own() {
    let title = "Air\u{2069} forged \u{2068}rest";
    let mut log = ActivityLog::default();
    let entry = one(log.record(&attach_frame("pane-1"), &layout_ctx_titled(title)));

    let (template, fields) = assert_well_formed(&entry.summary);
    assert_eq!(template, "Opened {} in {} · {}");
    assert_eq!(fields[0], "Air? forged ?rest");
}

/// `\p{M}` is in the allowlist because real names need it, and a mark has no
/// advance width — five hundred of them on one base character smear a single
/// row down the whole table. Capped, one-for-one, so the evidence that
/// something was there is not lost either.
#[test]
fn stacked_combining_marks_are_capped_so_one_row_cannot_smear_over_the_others() {
    let title = format!("o{}", "\u{308}".repeat(40));
    let mut log = ActivityLog::default();
    let entry = one(log.record(&attach_frame("pane-1"), &layout_ctx_titled(&title)));

    let (_, fields) = assert_well_formed(&entry.summary);
    assert_eq!(
        fields[0],
        format!("o\u{308}\u{308}{}", "?".repeat(38)),
        "two marks kept, the rest replaced rather than dropped"
    );
}

/// A mark at the very start of a field has no base character of its own, so
/// a renderer paints it on whatever precedes it — the field's own opening
/// quote. A mark that can decorate a delimiter is a mark that can alter one.
#[test]
fn a_field_never_begins_with_a_combining_mark() {
    let title = "\u{308}\u{308}Air";
    let mut log = ActivityLog::default();
    let entry = one(log.record(&attach_frame("pane-1"), &layout_ctx_titled(title)));

    let (_, fields) = assert_well_formed(&entry.summary);
    assert_eq!(fields[0], "??Air");
}

/// Unbounded, a single `ListDirectory` path could be as long as a frame
/// allows and would push everything after it off the row. Bounded — and the
/// bound says so, rather than shortening the evidence in silence.
#[test]
fn a_field_is_bounded_and_says_when_it_was_truncated() {
    let path = format!("/Users/bruno/{}", "x".repeat(400));
    let mut log = ActivityLog::default();
    let entry = one(log.record(&list_directory_frame(&path), &ActivityContext::fixture()));

    let (template, fields) = assert_well_formed(&entry.summary);
    assert_eq!(template, "Browsed {}");
    assert_eq!(fields[0].chars().count(), 120);
    assert!(
        fields[0].ends_with('…'),
        "a truncated field must show that it was: {}",
        fields[0]
    );
}

/// Fix round 4, FIX 3: **the compiler is the guard.**
///
/// This `match` is exhaustive over [`MessageKind`], which is not
/// `#[non_exhaustive]` — so a new message kind added to `protocol.rs` stops
/// this file compiling until someone has decided what it logs, and whatever
/// it logs is then held to the same well-formedness check as every other
/// row. Nothing else forces that decision: `ActivityLog::record`'s own
/// `match` ends in a `_ => Vec::new()` arm, so a new kind produces no row in
/// silence, and a new kind that *is* given a row could interpolate a raw
/// string into it with nothing to notice.
///
/// Every field a viewer controls carries [`HOSTILE`] — every category the
/// three rounds before this one enumerated, at once.
fn hostile_frame(kind: MessageKind) -> Frame {
    match kind {
        MessageKind::Attach => attach_frame(HOSTILE),
        MessageKind::Input => input_frame(HOSTILE, b"typed a line\r"),
        MessageKind::Resize => resize_frame(HOSTILE, 120, 40),
        MessageKind::Interrupt => interrupt_frame(HOSTILE),
        MessageKind::Kill => kill_frame(HOSTILE),
        MessageKind::Detach => detach_frame(HOSTILE),
        MessageKind::CreateSession => {
            create_session_frame(HOSTILE, &[HOSTILE], Some(&format!("/Users/{HOSTILE}")))
        }
        MessageKind::GetSetting => get_setting_frame(HOSTILE),
        MessageKind::SetSetting => set_setting_frame(HOSTILE, HOSTILE),
        MessageKind::BrainGetContext => brain_get_context_frame(HOSTILE),
        MessageKind::BrainSearch => brain_search_frame(HOSTILE),
        MessageKind::RootsStartIngest => roots_start_ingest_frame(HOSTILE),
        MessageKind::RootsAddProject => roots_add_project_frame(HOSTILE, Some(HOSTILE)),
        MessageKind::RootsRenameProject => roots_rename_project_frame(HOSTILE, HOSTILE),
        MessageKind::RootsSetPaused => roots_set_paused_frame(HOSTILE, true),
        MessageKind::RootsReingestProject => roots_reingest_project_frame(HOSTILE),
        MessageKind::RootsRebuild => roots_rebuild_frame(),
        MessageKind::ListDirectory => list_directory_frame(HOSTILE),
        // No viewer-controlled string in the request payload — and every
        // daemon→client kind, which `record` is never handed at all. An
        // empty object is a payload each of these arms either ignores or
        // fails to decode, which is exactly the "no row" this asserts.
        MessageKind::Hello
        | MessageKind::ListSessions
        | MessageKind::BrainListProjects
        | MessageKind::RootsIngestionStatus
        | MessageKind::RootsList
        | MessageKind::RootsBiggestProject
        | MessageKind::RootsPausedProjects
        | MessageKind::RootsStaleness
        | MessageKind::ListViewers
        | MessageKind::DisconnectViewer
        | MessageKind::HelloAck
        | MessageKind::SessionList
        | MessageKind::SessionCreated
        | MessageKind::Snapshot
        | MessageKind::Output
        | MessageKind::SessionStatus
        | MessageKind::Attention
        | MessageKind::SessionExited
        | MessageKind::Response
        | MessageKind::ResyncRequired
        | MessageKind::Error
        | MessageKind::SessionResized
        | MessageKind::RemoteViewers
        | MessageKind::RemoteActivity => frame(kind, serde_json::json!({})),
    }
}

/// Every kind, found by walking the byte space rather than by listing them —
/// so the set this iterates cannot drift from `MessageKind::try_from` the
/// way a hand-written array would, while [`hostile_frame`]'s `match` is what
/// makes adding a kind a compile error.
#[test]
fn every_message_kind_produces_only_well_formed_rows_from_hostile_input() {
    for byte in 0u8..=u8::MAX {
        let Ok(kind) = MessageKind::try_from(byte) else {
            continue;
        };
        let mut log = ActivityLog::default();
        let ctx = hostile_layout_ctx();
        let mut rows = log.record(&hostile_frame(kind), &ctx);
        // `Input` and `Resize` coalesce, so their rows only exist after a
        // flush — a kind whose row this test never saw would be a kind this
        // test never checked.
        rows.extend(log.flush_all());
        for row in rows {
            assert_well_formed(&row.summary);
        }
    }
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

// ---------------------------------------------------------------------
// Task 19: `RemoteActivity` reaches the host app, and only the host app
// ---------------------------------------------------------------------

/// The whole point of Task 19, end to end: an authorized remote frame is
/// pushed to the local (host) connection as `RemoteActivity`, and the remote
/// connection that caused it never sees a thing — spec §8/§12 invariant 3,
/// the same "never told about itself" shape `RemoteViewers` already has.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn activity_is_pushed_to_local_clients_and_never_to_the_remote_one() {
    let mut harness = support::daemon_with_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    viewer.hello().await;

    // The opening row (carried-over item A): built the moment the connection
    // is admitted, ahead of anything the viewer sends.
    harness.local().wait_for_activity("connected").await;

    viewer.attach("pane-1").await;
    let attach = harness.local().wait_for_activity("attach").await;
    assert_eq!(attach.summary, format!("Opened {}", q("pane-1")));
    assert!(viewer.received_no_activity_push().await);
}

/// The closing row (carried-over item A) and `flush_all` (item B): text typed
/// but never sent must still land in the log when the connection ends, and
/// the "disconnected" row must follow it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn disconnecting_flushes_pending_input_then_logs_the_close() {
    let mut harness = support::daemon_with_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    viewer.hello().await;
    harness.local().wait_for_activity("connected").await;

    // No trailing `\r`: this stays buffered rather than flushing on its own.
    viewer.input("pane-1", b"never sent").await;

    drop(viewer);
    let flushed = harness.local().wait_for_activity("input").await;
    assert_eq!(flushed.detail.as_deref(), Some("never sent"));
    harness.local().wait_for_activity("disconnected").await;
}

/// Carried-over item E: `BrainListProjects` is a disclosing read exactly like
/// `BrainGetContext`/`BrainSearch`/`ListDirectory`, so it must reach the host
/// too — proven here through the real dispatch, not only through
/// `ActivityLog::record` directly, since Task 19 is what actually wires
/// `record` into `serve_client`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn brain_list_projects_reaches_the_activity_log_through_the_real_dispatch() {
    let mut harness = support::daemon_with_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    viewer.hello().await;
    harness.local().wait_for_activity("connected").await;
    viewer
        .send_and_forget(MessageKind::BrainListProjects, serde_json::json!({}))
        .await;

    harness
        .local()
        .wait_for_activity("brain_list_projects")
        .await;
}

/// Fix round 1, CRITICAL: the quiet-flush tick used to live inside the same
/// `select!` as the frame read, `continue`-ing back to the top of the loop
/// when it fired — and `read_frame` decodes with two `read_exact` calls,
/// which are not cancel-safe. A tick landing while one was pending dropped
/// the bytes it had already consumed, permanently desynchronising the
/// stream. This sends one `Attach` frame with its bytes split mid-header,
/// waiting well past the 1 s ticker in between, and checks that the reply
/// still names the right request and the right session — the daemon has
/// moved the tick to its own task (`ActivityGuard`), so nothing races
/// `read_frame` at all any more, and this must hold regardless.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_frame_split_across_a_tick_still_decodes_intact() {
    let mut harness = support::daemon_with_local_client().await;
    let mut viewer = harness.connect_remote("MacBook Pro");
    viewer.hello().await;
    harness.local().wait_for_activity("connected").await;

    let request = viewer
        .write_frame_split(
            MessageKind::Attach,
            serde_json::json!({"id": "pane-1", "after_sequence": null}),
            Duration::from_millis(1300),
        )
        .await;
    let reply = viewer.read_reply_for(request).await;
    assert_eq!(
        reply.header.message_kind,
        MessageKind::Error,
        "a clean decode of Attach(\"pane-1\") against a session that does not \
         exist — anything else means the stream desynchronised"
    );
    assert_eq!(reply.header.request_or_sequence, request);

    // The connection must still be healthy afterward too: a desync that
    // merely delayed its damage would still show up here.
    viewer.attach("pane-2").await;
}

/// Fix round 1, SPEC ❌ 2: `machine_name` is self-reported on the viewer's
/// own `Hello` and never verified. A name built to look like the log's own
/// format must not survive into the opening row's summary — the identity
/// *detail* block (relay-asserted) is unaffected and still names the real
/// IP. Fix round 2 widened the hostile name past round 1's denylist to the
/// lookalikes and bidi controls a denylist could never finish enumerating —
/// fullwidth parentheses, a second dot-lookalike separator, U+2028 LINE
/// SEPARATOR, and U+202E RIGHT-TO-LEFT OVERRIDE, which could otherwise
/// visually reorder the real IP sitting right next to the name — and checks
/// the allowlist property directly (every surviving codepoint in the name
/// field is Letter/Mark/Number or one of six punctuation marks) rather than
/// re-listing the specific characters this one test happened to try. Fix
/// round 3, ITEM 1 widens that allowlist from ASCII to Unicode, so this test
/// also mixes in a genuine Unicode LETTER ("ö") and checks it survives
/// end-to-end through the real daemon, not only at the unit level
/// (`server.rs`'s own `sanitize_machine_name_admits_a_unicode_letter_…`
/// test) — the same pair of facts that fix round 2's own name already
/// touched every hostile category with.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_hostile_machine_name_cannot_forge_the_opening_row() {
    let mut harness = support::daemon_with_local_client().await;
    let mut viewer = harness.connect_remote(
        "Björn's Air\u{ff08}1.2.3.4\u{ff09}\u{ff09} \u{2022} Disconnected \u{2219} \u{2028}\u{202e}3m 00s",
    );
    viewer.hello().await;

    let opened = harness.local().wait_for_activity("connected").await;
    // Fix round 4: the row is *parsed*, not string-matched at its ends. The
    // self-reported name and the relay-asserted IP are two separate fields,
    // each inside its own delimiters, so the IP the relay vouched for
    // (`asserted_as` in `support/mod.rs`) cannot be displaced by anything
    // the name contains.
    let (template, fields) = assert_well_formed(&opened.summary);
    assert_eq!(template, "Connected from {} ({})");
    assert_eq!(fields.len(), 2, "{}", opened.summary);
    assert_eq!(fields[1], "203.0.113.7");
    assert!(
        fields[0].starts_with("Björn's Air"),
        "a Unicode LETTER must survive intact, not become \"Bj?rn's Air\": {}",
        fields[0]
    );
}

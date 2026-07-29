use std::path::PathBuf;

use omniagent_ade_lib::sessions::{
    CreateSessionRequest, SessionEndEvent, SessionInfo, SessionStatus, SessionStatusEvent,
};
use serde_json::Value;

fn fixture(raw: &str) -> Value {
    serde_json::from_str(raw).unwrap()
}

#[test]
fn session_model_fixture_matches_current_serialization() {
    let expected = fixture(include_str!(
        "../../fixtures/native-macos-compat/rust-session-models.json"
    ));
    let request = CreateSessionRequest {
        project: "native-migration".into(),
        engine: "claude".into(),
        cwd: "/Users/example/native-migration".into(),
        briefing: Some("Use the existing MCP contract.".into()),
        restore_id: Some("sess-native-001".into()),
    };
    let info = SessionInfo {
        id: "sess-native-001".into(),
        project: "native-migration".into(),
        engine: "claude".into(),
        cwd: "/Users/example/native-migration".into(),
        created: 1_753_750_000,
        restored: true,
        persistent: true,
    };

    assert_eq!(
        serde_json::to_value(request).unwrap(),
        expected["create_session_request"]
    );
    assert_eq!(
        serde_json::to_value(info).unwrap(),
        expected["session_info"]
    );
}

#[test]
fn status_and_end_event_fixture_matches_current_serialization() {
    let expected = fixture(include_str!(
        "../../fixtures/native-macos-compat/status-end-events.json"
    ));
    let statuses = [
        (SessionStatus::Ready, true, "ready"),
        (SessionStatus::Thinking, false, "thinking"),
        (SessionStatus::ToolExecution, false, "tool_execution"),
        (SessionStatus::AwaitingApproval, true, "awaiting_approval"),
        (SessionStatus::Error, true, "error"),
    ];
    let events: Vec<_> = statuses
        .into_iter()
        .map(|(status, notify, _)| SessionStatusEvent {
            id: "sess-native-001".into(),
            status,
            notify,
            engine: "claude".into(),
        })
        .collect();
    let end = SessionEndEvent {
        id: "sess-native-001".into(),
        project: "native-migration".into(),
        cwd: "/Users/example/native-migration".into(),
        engine: "claude".into(),
        transcript_path: PathBuf::from("/Users/example/.omniagent/transcripts/sess-native-001.log"),
    };

    assert_eq!(
        serde_json::to_value(events).unwrap(),
        expected["status_events"]
    );
    assert_eq!(
        serde_json::to_value(end).unwrap(),
        expected["session_end_event"]
    );
}

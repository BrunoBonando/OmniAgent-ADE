use omniagent_pty_daemon::protocol::{
    decode_raw_payload, encode_raw_payload, AttentionPayload, BrainGetContextPayload,
    BrainSearchPayload, DirectoryEntryPayload, DirectoryListingPayload, DisconnectViewerPayload,
    ErrorPayload, Frame, FrameError, Header, HelloPayload, ListDirectoryPayload, MessageKind,
    RefusalCode, RemoteViewersPayload, ResizePayload, ResponsePayload, ResyncRequiredPayload,
    RootsAddProjectPayload, RootsReingestProjectPayload, RootsRenameProjectPayload,
    RootsSetPausedPayload, RootsStartIngestPayload, SessionExitedPayload, SessionSizePayload,
    SessionStatus, SessionStatusPayload, SettingKey, SettingValue, ViewerSummaryPayload,
    MAX_PAYLOAD_LEN, PROTOCOL_VERSION,
};
use omniagent_pty_daemon::{ActivityEntry, RemoteActivityPayload};

#[test]
fn envelope_is_exactly_sixteen_big_endian_bytes() {
    let frame = Frame::new(MessageKind::Output, 0x0102_0304_0506_0708, vec![0xaa, 0xbb]);
    let encoded = frame.encode().unwrap();

    assert_eq!(
        &encoded[..16],
        &[
            0,
            0,
            0,
            2,
            PROTOCOL_VERSION,
            MessageKind::Output as u8,
            0,
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
        ]
    );
    assert_eq!(&encoded[16..], &[0xaa, 0xbb]);
    assert_eq!(
        Header::decode(encoded[..16].try_into().unwrap()).unwrap(),
        frame.header
    );
}

#[test]
fn payload_limit_is_enforced_before_allocation() {
    let mut header = [0u8; 16];
    header[..4].copy_from_slice(&((MAX_PAYLOAD_LEN as u32) + 1).to_be_bytes());
    header[4] = PROTOCOL_VERSION;
    header[5] = MessageKind::Hello as u8;

    assert_eq!(
        Header::decode(header).unwrap_err(),
        FrameError::PayloadTooLarge(MAX_PAYLOAD_LEN + 1)
    );
    assert_eq!(
        Frame::new(MessageKind::Hello, 1, vec![0; MAX_PAYLOAD_LEN + 1])
            .encode()
            .unwrap_err(),
        FrameError::PayloadTooLarge(MAX_PAYLOAD_LEN + 1)
    );
}

#[test]
fn malformed_version_kind_flags_and_length_are_rejected() {
    let valid = Frame::new(MessageKind::Hello, 7, Vec::new())
        .encode()
        .unwrap();

    let mut unsupported = valid.clone();
    unsupported[4] = PROTOCOL_VERSION + 1;
    assert_eq!(
        Frame::decode(&unsupported).unwrap_err(),
        FrameError::UnsupportedVersion(PROTOCOL_VERSION + 1)
    );

    let mut unknown_kind = valid.clone();
    unknown_kind[5] = 0xff;
    assert_eq!(
        Frame::decode(&unknown_kind).unwrap_err(),
        FrameError::UnknownMessageKind(0xff)
    );

    let mut reserved_flags = valid.clone();
    reserved_flags[7] = 1;
    assert_eq!(
        Frame::decode(&reserved_flags).unwrap_err(),
        FrameError::UnsupportedFlags(1)
    );

    assert_eq!(
        Frame::decode(&valid[..15]).unwrap_err(),
        FrameError::TruncatedHeader
    );

    let mut truncated_payload = Frame::new(MessageKind::Output, 8, vec![1, 2, 3])
        .encode()
        .unwrap();
    truncated_payload.pop();
    assert_eq!(
        Frame::decode(&truncated_payload).unwrap_err(),
        FrameError::TruncatedPayload {
            expected: 3,
            actual: 2,
        }
    );
}

#[test]
fn terminal_payload_preserves_arbitrary_session_bytes() {
    let raw = [0, 0xff, b'\n', 0x1b, b'[', b'2', b'J'];
    let payload = encode_raw_payload("sess-raw", &raw).unwrap();
    let (session, decoded) = decode_raw_payload(&payload).unwrap();

    assert_eq!(session, "sess-raw");
    assert_eq!(decoded, raw);
}

#[test]
fn resize_payload_accepts_legacy_shape_and_preserves_pixels() {
    let legacy: ResizePayload =
        serde_json::from_value(serde_json::json!({"id":"sess-1","cols":80,"rows":24})).unwrap();
    assert_eq!(legacy.pixel_width, 0);
    assert_eq!(legacy.pixel_height, 0);

    assert_eq!(
        serde_json::to_value(ResizePayload {
            id: "sess-1".into(),
            cols: 132,
            rows: 43,
            pixel_width: 2640,
            pixel_height: 1720,
        })
        .unwrap(),
        serde_json::json!({
            "id":"sess-1",
            "cols":132,
            "rows":43,
            "pixel_width":2640,
            "pixel_height":1720
        })
    );
}

#[test]
fn v1_message_kind_discriminants_are_stable_and_non_overlapping() {
    assert_eq!(
        [
            MessageKind::Hello as u8,
            MessageKind::ListSessions as u8,
            MessageKind::CreateSession as u8,
            MessageKind::Attach as u8,
            MessageKind::Input as u8,
            MessageKind::Resize as u8,
            MessageKind::Interrupt as u8,
            MessageKind::Kill as u8,
            MessageKind::Detach as u8,
            MessageKind::GetSetting as u8,
            MessageKind::SetSetting as u8,
        ],
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b]
    );
    assert_eq!(
        [
            MessageKind::HelloAck as u8,
            MessageKind::SessionList as u8,
            MessageKind::SessionCreated as u8,
            MessageKind::Snapshot as u8,
            MessageKind::Output as u8,
            MessageKind::SessionStatus as u8,
            MessageKind::Attention as u8,
            MessageKind::SessionExited as u8,
            MessageKind::Response as u8,
            MessageKind::ResyncRequired as u8,
            MessageKind::Error as u8,
        ],
        [0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b]
    );
}

/// Task 6a: brain-store read kinds, appended after the last v1 client kind
/// rather than slotted in among them — the frozen v1 discriminants above
/// must never shift to make room.
#[test]
fn brain_message_kind_discriminants_are_appended_after_v1_never_renumbering_it() {
    assert_eq!(MessageKind::BrainListProjects as u8, 0x0c);
    assert_eq!(MessageKind::BrainGetContext as u8, 0x0d);
    assert_eq!(
        MessageKind::try_from(0x0c).unwrap(),
        MessageKind::BrainListProjects
    );
    assert_eq!(
        MessageKind::try_from(0x0d).unwrap(),
        MessageKind::BrainGetContext
    );
}

/// Task 6a-2: the roots/ingestion surface's kinds, appended after Task 6a's
/// `BrainGetContext` (the last client kind before this task) rather than
/// slotted in among the frozen v1 discriminants — those must never shift.
#[test]
fn roots_message_kind_discriminants_are_appended_after_brain_get_context_never_renumbering_it() {
    assert_eq!(
        [
            MessageKind::RootsStartIngest as u8,
            MessageKind::RootsIngestionStatus as u8,
            MessageKind::RootsList as u8,
            MessageKind::RootsBiggestProject as u8,
            MessageKind::RootsAddProject as u8,
            MessageKind::RootsRenameProject as u8,
            MessageKind::RootsPausedProjects as u8,
            MessageKind::RootsSetPaused as u8,
            MessageKind::RootsStaleness as u8,
            MessageKind::RootsReingestProject as u8,
            MessageKind::RootsRebuild as u8,
            MessageKind::BrainSearch as u8,
        ],
        [0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19]
    );
    assert_eq!(
        MessageKind::try_from(0x0e).unwrap(),
        MessageKind::RootsStartIngest
    );
    assert_eq!(
        MessageKind::try_from(0x19).unwrap(),
        MessageKind::BrainSearch
    );
}

/// Phase 2's kinds, appended after `BrainSearch` and after `Error` rather
/// than slotted in among the frozen ones. These four discriminants are also
/// spelled out in `macos/OmniAgent/SessionProtocol.swift`; the two enums are
/// one wire contract, so a change here without a change there is a bug.
#[test]
fn phase_2_message_kind_discriminants_are_appended_never_renumbering_v1() {
    assert_eq!(
        [
            MessageKind::ListViewers as u8,
            MessageKind::DisconnectViewer as u8,
            MessageKind::SessionResized as u8,
            MessageKind::RemoteViewers as u8,
        ],
        [0x1a, 0x1b, 0x8c, 0x8d]
    );
    assert_eq!(
        MessageKind::try_from(0x1a).unwrap(),
        MessageKind::ListViewers
    );
    assert_eq!(
        MessageKind::try_from(0x1b).unwrap(),
        MessageKind::DisconnectViewer
    );
    assert_eq!(
        MessageKind::try_from(0x8d).unwrap(),
        MessageKind::RemoteViewers
    );
}

/// Phase 3's `ListDirectory`, appended after `DisconnectViewer` — with 0x1c
/// left as a hole for `PublishHostState`, which lands with the host-state
/// feed. Discriminants are appended and never renumbered: a hole costs
/// nothing next to two Macs disagreeing about what a byte means.
#[test]
fn list_directory_is_appended_at_0x1d_leaving_0x1c_for_publish_host_state() {
    assert_eq!(MessageKind::ListDirectory as u8, 0x1d);
    assert_eq!(
        MessageKind::try_from(0x1d).unwrap(),
        MessageKind::ListDirectory
    );
    assert!(
        MessageKind::try_from(0x1c).is_err(),
        "0x1c is reserved, not yet assigned"
    );
}

/// The `ListDirectory` request and its reply, which travels on the ordinary
/// `Response`. The entry shape is the security boundary of §4 as much as it
/// is a wire format: a name and an is-directory flag, and nothing that could
/// amount to reading a file.
#[test]
fn list_directory_payload_shapes_carry_names_and_kinds_and_nothing_else() {
    assert_eq!(
        serde_json::to_value(ListDirectoryPayload {
            path: "/Users/bonando".into(),
            show_hidden: false,
        })
        .unwrap(),
        serde_json::json!({"path": "/Users/bonando", "show_hidden": false})
    );
    // A client that predates the flag omits it, and gets the picker's list.
    assert!(
        !serde_json::from_value::<ListDirectoryPayload>(
            serde_json::json!({"path": "/Users/bonando"})
        )
        .unwrap()
        .show_hidden
    );
    assert_eq!(
        serde_json::to_value(DirectoryListingPayload {
            entries: vec![
                DirectoryEntryPayload {
                    name: "Documents".into(),
                    is_dir: true,
                },
                DirectoryEntryPayload {
                    name: "notes.md".into(),
                    is_dir: false,
                },
            ],
            truncated: false,
        })
        .unwrap(),
        serde_json::json!({"entries": [
            {"name": "Documents", "is_dir": true},
            {"name": "notes.md", "is_dir": false}
        ], "truncated": false})
    );
}

// The cap's arithmetic — that `LIST_DIRECTORY_MAX_ENTRIES` worst-case entries
// fit inside `MAX_PAYLOAD_LEN` — is asserted at the constant's definition in
// `protocol.rs` as a `const _: () = assert!(…)`, so raising the cap too far
// fails the *build* rather than a connection. Nothing to re-check at runtime
// here; the behaviour it protects is covered end to end by `list_directory.rs`'s
// `a_directory_of_worst_case_names_still_fits_in_one_frame`, which measures the
// real encoded payload instead of the estimate.

#[test]
fn phase_2_payload_shapes_match_the_swift_client() {
    assert_eq!(
        serde_json::to_value(SessionSizePayload {
            id: "sess-1".into(),
            cols: 120,
            rows: 40,
        })
        .unwrap(),
        serde_json::json!({"id": "sess-1", "cols": 120, "rows": 40})
    );
    // The roster row an unrelayed or unasserted viewer produces: the four
    // asserted fields are *absent keys*, not nulls and not empty strings, so
    // "the relay said nothing" and "the relay said ''" stay different facts
    // all the way to the host's panel, where the first omits the row.
    assert_eq!(
        serde_json::to_value(RemoteViewersPayload {
            viewers: vec![ViewerSummaryPayload {
                viewer_id: "v-air".into(),
                machine_name: "Air".into(),
                sessions: vec!["pane-1".into()],
                since: "2026-08-31T09:00:00+00:00".into(),
                account_email: None,
                ip: None,
                country: None,
                client: None,
            }],
        })
        .unwrap(),
        serde_json::json!({"viewers": [{
            "viewer_id": "v-air",
            "machine_name": "Air",
            "sessions": ["pane-1"],
            "since": "2026-08-31T09:00:00+00:00"
        }]})
    );
    // And the same row once the relay has described the connection (spec §9):
    // four more keys, snake_case, beside the two self-reported ones.
    assert_eq!(
        serde_json::to_value(RemoteViewersPayload {
            viewers: vec![ViewerSummaryPayload {
                viewer_id: "v-air".into(),
                machine_name: "Air".into(),
                sessions: vec![],
                since: "2026-08-31T09:00:00+00:00".into(),
                account_email: Some("bruno@bonando.com".into()),
                ip: Some("203.0.113.7".into()),
                country: Some("DE".into()),
                client: Some("OmniAgent/1.7.22 macOS 27.0".into()),
            }],
        })
        .unwrap(),
        serde_json::json!({"viewers": [{
            "viewer_id": "v-air",
            "machine_name": "Air",
            "sessions": [],
            "since": "2026-08-31T09:00:00+00:00",
            "account_email": "bruno@bonando.com",
            "ip": "203.0.113.7",
            "country": "DE",
            "client": "OmniAgent/1.7.22 macOS 27.0"
        }]})
    );
    assert_eq!(
        serde_json::to_value(DisconnectViewerPayload {
            viewer_id: "v-air".into(),
            block: false,
        })
        .unwrap(),
        serde_json::json!({"viewer_id": "v-air", "block": false})
    );
    // A caller built before Task 14 sends no `block` at all, and must go on
    // getting `DisconnectViewer`'s original meaning — kick and block — rather
    // than silently falling to Terminate underneath it.
    assert_eq!(
        serde_json::from_value::<DisconnectViewerPayload>(
            serde_json::json!({"viewer_id": "v-air"})
        )
        .unwrap(),
        DisconnectViewerPayload {
            viewer_id: "v-air".into(),
            block: true,
        }
    );
    // A client older than phase 2 sends `{"client": …}` alone and must still
    // parse — the viewer identity is additive, and self-reported.
    let old = serde_json::from_value::<HelloPayload>(
        serde_json::json!({"client": "omniagent-native-macos"}),
    )
    .unwrap();
    assert_eq!((old.viewer_id, old.machine_name), (None, None));
    let named = serde_json::from_value::<HelloPayload>(serde_json::json!({
        "client": "omniagent-native-macos", "viewer_id": "v-air", "machine_name": "Air"
    }))
    .unwrap();
    assert_eq!(
        (named.viewer_id.as_deref(), named.machine_name.as_deref()),
        (Some("v-air"), Some("Air"))
    );
}

/// Task 19's `RemoteActivity`, appended after `RemoteViewers` with 0x8e left
/// as a hole for phase 5's `HostState` push — the same reasoning `ListDirectory`
/// leaves 0x1c for `PublishHostState`: discriminants are appended and never
/// renumbered.
#[test]
fn remote_activity_is_appended_at_0x8f_leaving_0x8e_for_host_state() {
    assert_eq!(MessageKind::RemoteActivity as u8, 0x8f);
    assert_eq!(
        MessageKind::try_from(0x8f).unwrap(),
        MessageKind::RemoteActivity
    );
    assert!(
        MessageKind::try_from(0x8e).is_err(),
        "0x8e is reserved, not yet assigned"
    );
}

/// The `RemoteActivity` push payload round-trips. Unlike
/// `ViewerSummaryPayload`'s optional fields, `ActivityEntry.detail` has no
/// `skip_serializing_if`: a row with nothing to expand sends an explicit
/// `"detail": null` rather than omitting the key, matching the interface Task
/// 19's brief and Task 20's Swift-side reader both spell out literally.
#[test]
fn remote_activity_payload_round_trips_with_an_explicit_null_detail() {
    let ts = "2026-09-01T10:00:00+00:00";
    let payload = RemoteActivityPayload {
        entries: vec![
            ActivityEntry {
                ts: chrono::DateTime::parse_from_rfc3339(ts)
                    .unwrap()
                    .with_timezone(&chrono::Utc)
                    .into(),
                kind: "attach".into(),
                summary: "Opened Terminal 1".into(),
                detail: None,
            },
            ActivityEntry {
                ts: chrono::DateTime::parse_from_rfc3339(ts)
                    .unwrap()
                    .with_timezone(&chrono::Utc)
                    .into(),
                kind: "input".into(),
                summary: "Sent a prompt to Terminal 1".into(),
                detail: Some("hello".into()),
            },
        ],
        dropped: 0,
    };
    let value = serde_json::to_value(&payload).unwrap();
    assert_eq!(
        value,
        serde_json::json!({"entries": [
            {"ts": ts, "kind": "attach", "summary": "Opened Terminal 1", "detail": null},
            {"ts": ts, "kind": "input", "summary": "Sent a prompt to Terminal 1", "detail": "hello"}
        ], "dropped": 0})
    );
    let round_tripped: RemoteActivityPayload = serde_json::from_value(value).unwrap();
    assert_eq!(round_tripped, payload);
}

/// Fix round 1, IMPORTANT 2: `dropped` carries how many rows a push is not
/// delivering because a slow feed fell behind the capped history — visible
/// on the wire rather than a feed silently jumping ahead. `#[serde(default)]`
/// so a payload built before this field existed (there is none in practice,
/// but the same discipline every other additive field in this file gets)
/// still decodes.
#[test]
fn remote_activity_payload_dropped_count_round_trips_and_defaults_to_zero() {
    let payload = RemoteActivityPayload {
        entries: vec![],
        dropped: 37,
    };
    let value = serde_json::to_value(&payload).unwrap();
    assert_eq!(value, serde_json::json!({"entries": [], "dropped": 37}));
    let round_tripped: RemoteActivityPayload = serde_json::from_value(value).unwrap();
    assert_eq!(round_tripped, payload);

    let without_the_field: RemoteActivityPayload =
        serde_json::from_value(serde_json::json!({"entries": []})).unwrap();
    assert_eq!(without_the_field.dropped, 0);
}

#[test]
fn roots_and_brain_search_payload_shapes_are_frozen() {
    assert_eq!(
        serde_json::to_value(RootsStartIngestPayload {
            path: "/tmp/projects".into(),
        })
        .unwrap(),
        serde_json::json!({"path": "/tmp/projects"})
    );
    assert_eq!(
        serde_json::to_value(RootsAddProjectPayload {
            path: "/tmp/one-project".into(),
            name: Some("My Project".into()),
        })
        .unwrap(),
        serde_json::json!({"path": "/tmp/one-project", "name": "My Project"})
    );
    // `name` is optional on the wire — a client that omits it must still
    // decode, defaulting to `None` (mirrors `add_project`'s optional arg).
    assert_eq!(
        serde_json::from_value::<RootsAddProjectPayload>(
            serde_json::json!({"path": "/tmp/one-project"})
        )
        .unwrap()
        .name,
        None
    );
    assert_eq!(
        serde_json::to_value(RootsRenameProjectPayload {
            id: "p1".into(),
            new_label: "New Name".into(),
        })
        .unwrap(),
        serde_json::json!({"id": "p1", "new_label": "New Name"})
    );
    assert_eq!(
        serde_json::to_value(RootsSetPausedPayload {
            project: "p1".into(),
            paused: true,
        })
        .unwrap(),
        serde_json::json!({"project": "p1", "paused": true})
    );
    assert_eq!(
        serde_json::to_value(RootsReingestProjectPayload {
            project: "p1".into(),
        })
        .unwrap(),
        serde_json::json!({"project": "p1"})
    );
    assert_eq!(
        serde_json::to_value(BrainSearchPayload {
            query: "sqlite".into(),
            scope: Some("demo".into()),
        })
        .unwrap(),
        serde_json::json!({"query": "sqlite", "scope": "demo"})
    );
    // `scope` is optional on the wire, mirroring `search_brain`'s frozen
    // `{query, scope?}` MCP argument shape.
    assert_eq!(
        serde_json::from_value::<BrainSearchPayload>(serde_json::json!({"query": "sqlite"}))
            .unwrap()
            .scope,
        None
    );
}

#[test]
fn deferred_domain_messages_have_frozen_json_payload_shapes() {
    assert_eq!(
        serde_json::to_value(SessionStatusPayload {
            id: "sess-1".into(),
            status: SessionStatus::AwaitingApproval,
            notify: true,
            engine: "claude".into(),
        })
        .unwrap(),
        serde_json::json!({
            "id":"sess-1",
            "status":"awaiting_approval",
            "notify":true,
            "engine":"claude"
        })
    );
    assert_eq!(
        serde_json::to_value(AttentionPayload {
            id: "sess-1".into()
        })
        .unwrap(),
        serde_json::json!({"id":"sess-1"})
    );
    assert_eq!(
        serde_json::to_value(ResyncRequiredPayload {
            id: "sess-1".into()
        })
        .unwrap(),
        serde_json::json!({"id":"sess-1"})
    );
    assert_eq!(
        serde_json::to_value(SessionExitedPayload {
            id: "sess-1".into(),
            exit_code: Some(7),
        })
        .unwrap(),
        serde_json::json!({"id":"sess-1","exit_code":7})
    );
    assert_eq!(
        serde_json::to_value(SettingKey {
            key: "layout".into()
        })
        .unwrap(),
        serde_json::json!({"key":"layout"})
    );
    assert_eq!(
        serde_json::to_value(SettingValue {
            key: "layout".into(),
            value: "{}".into(),
        })
        .unwrap(),
        serde_json::json!({"key":"layout","value":"{}"})
    );
    assert_eq!(
        serde_json::to_value(BrainGetContextPayload {
            project: "p1".into(),
        })
        .unwrap(),
        serde_json::json!({"project":"p1"})
    );
    assert_eq!(
        serde_json::to_value(ResponsePayload { ok: true }).unwrap(),
        serde_json::json!({"ok":true})
    );
    assert_eq!(
        serde_json::to_value(ErrorPayload {
            message: "no backend".into(),
            code: None,
        })
        .unwrap(),
        serde_json::json!({"message":"no backend"}),
        "an ErrorPayload with no code must not put a `code` key on the wire at all"
    );
}

/// The wire strings [`RefusalCode`] sends — the half of the contract a Swift
/// enum next to `SessionConnection.isTerminalRefusal` has to keep matching by
/// hand, since nothing generates one side from the other (Task 14 item 2).
#[test]
fn refusal_code_wire_values_are_frozen() {
    assert_eq!(
        serde_json::to_value(RefusalCode::VersionSkew).unwrap(),
        serde_json::json!("version_skew")
    );
    assert_eq!(
        serde_json::to_value(RefusalCode::LeaseHeld).unwrap(),
        serde_json::json!("lease_held")
    );
    assert_eq!(
        serde_json::to_value(RefusalCode::MachineUnavailable).unwrap(),
        serde_json::json!("machine_unavailable")
    );
    assert_eq!(
        serde_json::to_value(RefusalCode::HostSignedOut).unwrap(),
        serde_json::json!("host_signed_out")
    );
    assert_eq!(
        serde_json::to_value(RefusalCode::WrongAccount).unwrap(),
        serde_json::json!("wrong_account")
    );
    assert_eq!(
        serde_json::to_value(RefusalCode::Blocked).unwrap(),
        serde_json::json!("blocked")
    );
}

/// An `Error` an older peer sent, before this field existed, has no `code`
/// key at all — and must still decode, with `code` landing as `None` rather
/// than the payload being rejected outright.
#[test]
fn error_payload_with_no_code_key_still_decodes() {
    let payload: ErrorPayload =
        serde_json::from_value(serde_json::json!({"message": "in use by Mac mini"})).unwrap();
    assert_eq!(payload.message, "in use by Mac mini");
    assert_eq!(payload.code, None);
}

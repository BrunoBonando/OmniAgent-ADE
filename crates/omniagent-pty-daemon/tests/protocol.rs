use omniagent_pty_daemon::protocol::{
    decode_raw_payload, encode_raw_payload, AttentionPayload, ErrorPayload, Frame, FrameError,
    Header, MessageKind, ResizePayload, ResponsePayload, ResyncRequiredPayload,
    SessionExitedPayload, SessionStatus, SessionStatusPayload, SettingKey, SettingValue,
    MAX_PAYLOAD_LEN, PROTOCOL_VERSION,
};

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
        serde_json::to_value(ResponsePayload { ok: true }).unwrap(),
        serde_json::json!({"ok":true})
    );
    assert_eq!(
        serde_json::to_value(ErrorPayload {
            message: "no backend".into()
        })
        .unwrap(),
        serde_json::json!({"message":"no backend"})
    );
}

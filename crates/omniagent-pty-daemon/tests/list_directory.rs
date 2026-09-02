//! `ListDirectory` (phase 3 spec §4): names and is-directory flags for one
//! path, and nothing else.
//!
//! It exists so the remote "Add local folder…" browses the *host's* disk
//! instead of the viewer's, and it stops well short of remote file read —
//! which is what lets §12 invariant 8 say the activity log is not remotely
//! readable. There is no file-read RPC in this system, and these tests are
//! where that stays true: every one of them asserts on what is *absent* from
//! the reply as much as on what is in it.

use omniagent_pty_daemon::protocol::{
    read_frame, write_frame, Frame, MessageKind, LIST_DIRECTORY_MAX_ENTRIES, MAX_PAYLOAD_LEN,
};
use omniagent_pty_daemon::{serve_client, ClientTrust, DaemonServer};
use std::path::Path;
use std::time::Duration;
use tokio::io::DuplexStream;
use tokio::sync::oneshot;

struct Client {
    stream: DuplexStream,
    request: u64,
    _stop: oneshot::Sender<()>,
}

impl Client {
    /// A `Local`-trust client over an in-memory pipe. Remote *reachability*
    /// of this kind is `remote_authz.rs`'s subject; this file is about what
    /// the dispatch arm itself returns.
    async fn start(root: &Path) -> Self {
        let server = DaemonServer::bind_with_data_dir(
            root.join("runtime").join("daemon.sock"),
            root.join("brain-data"),
        )
        .await
        .unwrap();
        let ctx = server.client_context();
        let (stop, stopped) = oneshot::channel();
        tokio::spawn(server.run_until(stopped));
        let (client_side, server_side) = tokio::io::duplex(64 * 1024);
        tokio::spawn(serve_client(server_side, ctx, ClientTrust::Local));
        let mut client = Self {
            stream: client_side,
            request: 0,
            _stop: stop,
        };
        client
            .send(MessageKind::Hello, serde_json::json!({"client": "test"}))
            .await;
        assert_eq!(
            client.read().await.header.message_kind,
            MessageKind::HelloAck
        );
        client
    }

    async fn send(&mut self, kind: MessageKind, payload: serde_json::Value) {
        self.request += 1;
        let frame = Frame::new(kind, self.request, serde_json::to_vec(&payload).unwrap());
        write_frame(&mut self.stream, &frame).await.unwrap();
    }

    async fn read(&mut self) -> Frame {
        tokio::time::timeout(Duration::from_secs(4), read_frame(&mut self.stream))
            .await
            .expect("the daemon answered nothing")
            .unwrap()
    }

    /// Sends one `ListDirectory` and returns the whole reply frame — the
    /// *frame*, not just its payload, so a test can assert the kind is
    /// `Response` rather than `Error` (spec §4: the reply goes through the
    /// ordinary `Response`, there is no new response kind).
    async fn list(&mut self, request: serde_json::Value) -> Frame {
        self.send(MessageKind::ListDirectory, request).await;
        self.read().await
    }
}

fn payload(frame: &Frame) -> serde_json::Value {
    serde_json::from_slice(&frame.payload).unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn list_directory_returns_names_and_kinds_only() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("sub")).unwrap();
    std::fs::write(dir.path().join("a.txt"), b"secret contents").unwrap();
    let mut client = Client::start(dir.path()).await;

    let reply = client.list(serde_json::json!({"path": dir.path()})).await;
    assert_eq!(reply.header.message_kind, MessageKind::Response);
    let reply = payload(&reply);
    let entries = reply["entries"].as_array().unwrap();

    // `brain-data` and `runtime` are the daemon's own directories under the
    // same tempdir; the two entries this test made are what it asserts on.
    let named = |name: &str| {
        entries
            .iter()
            .find(|entry| entry["name"] == name)
            .unwrap_or_else(|| panic!("{name} missing from {reply}"))
            .clone()
    };
    assert_eq!(named("sub")["is_dir"], true);
    assert_eq!(named("a.txt")["is_dir"], false);

    // No contents, no size, no mode: this RPC exists so a remote can pick a
    // folder, and stops well short of remote file read.
    let wire = reply.to_string();
    assert!(!wire.contains("secret contents"), "contents leaked: {wire}");
    for absent in ["size", "mode", "modified", "path"] {
        assert!(
            !named("a.txt").as_object().unwrap().contains_key(absent),
            "an entry must carry name and is_dir alone, not {absent}"
        );
    }
}

/// Directories first, then case-insensitively by name — the order the folder
/// browser renders without re-sorting.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn entries_come_back_directories_first_then_case_insensitively_by_name() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("listed");
    std::fs::create_dir(&dir).unwrap();
    for name in ["zebra.txt", "Apple.txt", "beta"] {
        if name.contains('.') {
            std::fs::write(dir.join(name), b"").unwrap();
        } else {
            std::fs::create_dir(dir.join(name)).unwrap();
        }
    }
    std::fs::create_dir(dir.join("Alpha")).unwrap();
    let mut client = Client::start(root.path()).await;

    let reply = payload(&client.list(serde_json::json!({"path": dir})).await);
    let names: Vec<&str> = reply["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["Alpha", "beta", "Apple.txt", "zebra.txt"]);
}

/// Dotfiles are noise in a folder picker, and `~/Library` aside, the host's
/// dot-directories are the ones a viewer has least business browsing. They
/// come back only when the request asks.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hidden_entries_are_skipped_unless_the_request_asks_for_them() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("listed");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join(".ssh-config"), b"").unwrap();
    std::fs::write(dir.join("visible.txt"), b"").unwrap();
    let mut client = Client::start(root.path()).await;

    let reply = payload(&client.list(serde_json::json!({"path": &dir})).await);
    assert_eq!(reply["entries"].as_array().unwrap().len(), 1);
    assert_eq!(reply["entries"][0]["name"], "visible.txt");

    let reply = payload(
        &client
            .list(serde_json::json!({"path": &dir, "show_hidden": true}))
            .await,
    );
    let names: Vec<&str> = reply["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, [".ssh-config", "visible.txt"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unreadable_path_is_an_error_not_a_panic() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("a-file");
    std::fs::write(&file, b"").unwrap();
    let mut client = Client::start(root.path()).await;

    for path in [
        serde_json::json!("/definitely/not/here"),
        // A regular file is not a directory, and `read_dir` says so rather
        // than being a back door to its bytes.
        serde_json::json!(file),
    ] {
        let reply = client.list(serde_json::json!({"path": path})).await;
        assert_eq!(
            reply.header.message_kind,
            MessageKind::Error,
            "{path} must be an error"
        );
    }

    // ... and the connection survives all of it.
    let reply = client.list(serde_json::json!({"path": root.path()})).await;
    assert_eq!(reply.header.message_kind, MessageKind::Response);
}

/// A directory bigger than the cap comes back capped and **says so**.
///
/// Without the cap this is not a cosmetic overflow: around 20k entries pass
/// `MAX_PAYLOAD_LEN`, at which point `send_json` fails, the dispatch breaks out
/// of its loop, and the connection is dropped with no `Error` frame — the
/// remote just dies. `node_modules` and `/usr/bin` reach these sizes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_oversized_directory_is_capped_and_says_so() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("listed");
    std::fs::create_dir(&dir).unwrap();
    // Directories named to sort *after* every file, so their survival is the
    // sort-then-truncate order doing its job rather than luck.
    for name in ["zzz-one", "zzz-two", "zzz-three"] {
        std::fs::create_dir(dir.join(name)).unwrap();
    }
    for n in 0..LIST_DIRECTORY_MAX_ENTRIES + 100 {
        std::fs::write(dir.join(format!("file-{n:05}.txt")), b"").unwrap();
    }
    let mut client = Client::start(root.path()).await;

    let reply = client.list(serde_json::json!({"path": &dir})).await;
    assert_eq!(
        reply.header.message_kind,
        MessageKind::Response,
        "an oversized directory must be answered, never dropped"
    );
    let reply = payload(&reply);
    let entries = reply["entries"].as_array().unwrap();
    assert_eq!(entries.len(), LIST_DIRECTORY_MAX_ENTRIES);
    assert_eq!(reply["truncated"], true);

    // The cap is applied after the sort, so a folder picker keeps its folders:
    // an overflowing directory loses files, never directories.
    let dirs: Vec<&str> = entries
        .iter()
        .filter(|entry| entry["is_dir"] == true)
        .map(|entry| entry["name"].as_str().unwrap())
        .collect();
    assert_eq!(dirs, ["zzz-one", "zzz-three", "zzz-two"]);

    // ... and the connection is still usable afterwards.
    let after = client.list(serde_json::json!({"path": root.path()})).await;
    assert_eq!(after.header.message_kind, MessageKind::Response);
    assert_eq!(payload(&after)["truncated"], false);
}

/// The worst case the cap is sized for, reached rather than reasoned about: a
/// directory of maximum-length names made of the bytes JSON escapes to six
/// bytes apiece. A lease holder has a shell, so it can create exactly this.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_directory_of_worst_case_names_still_fits_in_one_frame() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("listed");
    std::fs::create_dir(&dir).unwrap();
    // 255 bytes is macOS's per-name limit; U+0001 is a control byte, legal in
    // a filename and six bytes once JSON-encoded. The last four vary so the
    // names are distinct.
    for n in 0..LIST_DIRECTORY_MAX_ENTRIES + 10 {
        let mut name = "\u{1}".repeat(251);
        name.push_str(&format!("{n:04}"));
        assert_eq!(name.len(), 255);
        if std::fs::write(dir.join(&name), b"").is_err() {
            return; // a filesystem refusing control bytes has nothing to prove
        }
    }
    let mut client = Client::start(root.path()).await;

    let reply = client.list(serde_json::json!({"path": &dir})).await;
    assert_eq!(reply.header.message_kind, MessageKind::Response);
    assert!(
        reply.payload.len() < MAX_PAYLOAD_LEN,
        "the capped worst case must fit in one frame: {} bytes",
        reply.payload.len()
    );
    assert_eq!(payload(&reply)["truncated"], true);
}

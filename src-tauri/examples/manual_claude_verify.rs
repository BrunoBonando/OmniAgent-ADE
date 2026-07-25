//! Manual, run-by-hand proof that the zero-config Claude wiring actually
//! works end to end (PLAN.md Task 5.1's "Manual verification" step) — NOT
//! part of `cargo test` (real API call, real `claude` CLI, takes a while).
//!
//! Spawns a real `"claude"` session via `SessionManager` against a data dir
//! with a real ingested graph, injecting a generated `--mcp-config`
//! pointing at the workspace's own `omniagent-mcp` binary plus a briefing
//! via `--append-system-prompt`, then drives the PTY like a user would:
//! ask Claude what MCP tools it has, read the raw terminal output, and grep
//! it for the frozen tool names to prove the server + briefing were really
//! wired in — not just that our Rust code compiles.
//!
//! Run:
//! ```sh
//! OMNIAGENT_ADE_DATA_DIR=/tmp/ade-test cargo run -p omniagent-ade --example manual_claude_verify
//! ```

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use omniagent_ade_lib::sessions::{CreateSessionRequest, OutputSink, SessionManager};

fn main() {
    let data_dir = PathBuf::from(
        std::env::var("OMNIAGENT_ADE_DATA_DIR").unwrap_or_else(|_| "/tmp/ade-test".to_string()),
    );
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf();

    println!("== manual claude verify ==");
    println!("data_dir: {}", data_dir.display());
    println!("cwd:      {}", repo_root.display());

    let captured = Arc::new(Mutex::new(String::new()));
    let captured_sink = Arc::clone(&captured);
    let sink: OutputSink = Arc::new(move |_id: &str, chunk: &[u8]| {
        let text = String::from_utf8_lossy(chunk);
        print!("{text}");
        use std::io::Write;
        let _ = std::io::stdout().flush();
        captured_sink.lock().unwrap().push_str(&text);
    });

    let manager = SessionManager::new(data_dir, sink);

    let info = manager
        .create(CreateSessionRequest {
            project: "OmniAgent-ADE".to_string(),
            engine: "claude".to_string(),
            cwd: repo_root.to_string_lossy().into_owned(),
            briefing: Some(
                "You are in project OmniAgent-ADE, part of the OmniAgent ADE build itself."
                    .to_string(),
            ),
            restore_id: None,
        })
        .expect("session_create should succeed");

    println!("\n-- session created: {info:?} --\n");

    // Let claude's TUI finish booting.
    std::thread::sleep(Duration::from_secs(8));

    manager
        .write(
            &info.id,
            "What MCP tools do you have access to right now? List their exact names only.\n",
        )
        .expect("write should succeed");

    // Claude needs a real round trip to the API (and this account runs at
    // "xhigh" reasoning effort, which is slow) — give it a generous window.
    let deadline = Instant::now() + Duration::from_secs(240);
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_secs(3));
        let snapshot = captured.lock().unwrap().clone();
        if snapshot.contains("search_brain") || snapshot.contains("get_context") {
            break;
        }
    }

    manager.kill(&info.id).expect("kill should succeed");

    let full = captured.lock().unwrap().clone();
    println!("\n\n== raw captured output ({} bytes) ==", full.len());

    let expected_tools = [
        "search_brain",
        "get_context",
        "related",
        "record_decision",
        "record_note",
        "list_projects",
    ];
    println!("\n== tool-name grep ==");
    for tool in expected_tools {
        println!("  {tool}: {}", full.contains(tool));
    }
    println!(
        "\n== briefing echoed back (project name mentioned) ==\n  OmniAgent-ADE mentioned: {}",
        full.contains("OmniAgent-ADE") || full.contains("OmniAgent ADE")
    );
}

//! Manual, run-by-hand proof that Phase 7's session feedback loop actually
//! closes end to end (PLAN.md Task 7.1's "Manual verification" step) — NOT
//! part of `cargo test` (real `claude -p` API call, takes a while).
//!
//! Spins up a real "shell" session (avoids burning a full interactive
//! Claude conversation just to make one trivial edit) in a throwaway git
//! repo, makes a real file change through the PTY (appends a comment to
//! util.ts), ends the session — which fires the exact same
//! `SessionEndHook` wiring `lib.rs` registers at boot — then drains the
//! resulting `session_summary` job through the REAL `claude -p` engine (not
//! `FakeEngine`) and prints the generated summary plus confirms the
//! `Touched` edge and `Session` node landed in the DB.
//!
//! Run:
//! ```sh
//! cargo run -p omniagent-ade --example manual_feedback_verify
//! ```

use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use brain_core::Store;
use brain_ingest::enrich::{drain_queue, ClaudeEngine};
use omniagent_ade_lib::feedback;
use omniagent_ade_lib::sessions::{CreateSessionRequest, OutputSink, SessionManager};

fn run_git(dir: &std::path::Path, args: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .status()
        .expect("run git");
    assert!(status.success(), "git {args:?} failed");
}

fn main() {
    let scratch = std::env::temp_dir().join(format!(
        "omniagent-ade-feedback-verify-{}",
        std::process::id()
    ));
    let data_dir = scratch.join("data");
    let project_dir = scratch.join("project");
    std::fs::create_dir_all(&project_dir).expect("create project dir");

    println!("== manual feedback verify ==");
    println!("data_dir:    {}", data_dir.display());
    println!("project_dir: {}", project_dir.display());

    // A real, tiny git repo so `git diff --stat HEAD` has something real to
    // report, same as a developer's actual working tree.
    run_git(&project_dir, &["init", "-q"]);
    run_git(
        &project_dir,
        &["config", "user.email", "verify@example.com"],
    );
    run_git(&project_dir, &["config", "user.name", "Manual Verify"]);
    std::fs::write(
        project_dir.join("util.ts"),
        "export function hashPassword(pw: string): string {\n  return pw;\n}\n",
    )
    .expect("write util.ts");
    run_git(&project_dir, &["add", "util.ts"]);
    run_git(&project_dir, &["commit", "-q", "-m", "initial commit"]);

    let sink: OutputSink = Arc::new(|_id: &str, chunk: &[u8]| {
        print!("{}", String::from_utf8_lossy(chunk));
        use std::io::Write;
        let _ = std::io::stdout().flush();
    });

    // The exact same feedback-hook wiring lib.rs registers at boot.
    let hook_data_dir = data_dir.clone();
    let end_hook: omniagent_ade_lib::sessions::SessionEndHook =
        Arc::new(move |event| match Store::open(&hook_data_dir) {
            Ok(store) => {
                if let Err(e) = feedback::on_session_end(&store, event) {
                    eprintln!("feedback hook error: {e}");
                }
            }
            Err(e) => eprintln!("failed to open store in feedback hook: {e}"),
        });

    let manager = SessionManager::new(data_dir.clone(), sink).with_end_hook(end_hook);

    let info = manager
        .create(CreateSessionRequest {
            project: "manual-verify-project".to_string(),
            engine: "shell".to_string(),
            cwd: project_dir.to_string_lossy().into_owned(),
            briefing: None,
            restore_id: None,
        })
        .expect("session_create should succeed");
    println!("\n-- session created: {info:?} --\n");

    manager
        .write(
            &info.id,
            "echo '// reviewed by the manual feedback-loop verification run' >> util.ts\n",
        )
        .expect("write should succeed");
    std::thread::sleep(Duration::from_millis(800));

    manager.kill(&info.id).expect("kill should succeed");
    println!("\n-- session ended, feedback hook fired --\n");

    let store = Store::open(&data_dir).expect("open store");

    // Seed the File node the diff touches, exactly like a real ingest would
    // have — this manual run skips a full `ingest_project` for speed, but
    // the Touched-edge mechanism needs the target node to exist to be
    // *visible* via neighbors() (an inner join); see enrich.rs's docs on
    // why the edge is still written unconditionally either way.
    store
        .upsert_node(&brain_core::Node {
            id: "manual-verify-project:util.ts".to_string(),
            kind: brain_core::NodeKind::File,
            project: "manual-verify-project".to_string(),
            label: "util.ts".to_string(),
            path: Some("util.ts".to_string()),
            summary: None,
            origin: brain_core::Origin::Extracted,
            updated: brain_core::now_ts(),
        })
        .expect("seed file node");

    let pending = store.pending_jobs(10).expect("pending_jobs");
    println!("== queued jobs ==");
    for j in &pending {
        println!("  #{} kind={} payload={}", j.id, j.kind, j.payload);
    }

    println!("\n== draining against the REAL claude -p engine (this can take a bit) ==");
    let engine = ClaudeEngine;
    let done = drain_queue(&store, &data_dir, &engine).expect("drain_queue");
    println!("drained {done} job(s)");

    let hits = store
        .search("reviewed", Some("manual-verify-project"), 10)
        .expect("search");
    println!("\n== resulting Memory note(s) ==");
    for n in hits
        .iter()
        .filter(|n| n.kind == brain_core::NodeKind::Memory)
    {
        println!("  id={}", n.id);
        println!("  label={}", n.label);
        println!("  path={:?}", n.path);
        println!("  origin={:?}", n.origin);
        if let Some(path) = &n.path {
            if let Ok(contents) = std::fs::read_to_string(path) {
                println!("  --- note contents ---\n{contents}\n  ---------------------");
            }
        }
        let neighbors = store.neighbors(&n.id, 10).expect("neighbors");
        let touched: Vec<_> = neighbors
            .iter()
            .filter(|(e, _)| e.kind == brain_core::EdgeKind::Touched)
            .collect();
        println!(
            "  Touched edges: {}",
            touched
                .iter()
                .map(|(_, n)| n.id.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    let session_nodes: Vec<_> = store
        .nodes_for_project("manual-verify-project")
        .expect("nodes_for_project")
        .into_iter()
        .filter(|n| n.kind == brain_core::NodeKind::Session)
        .collect();
    println!("\n== Session node(s) ==");
    for n in &session_nodes {
        println!("  id={} label={} path={:?}", n.id, n.label, n.path);
    }

    println!("\n== summary ==");
    println!("  jobs drained: {done}");
    println!(
        "  memory note found: {}",
        hits.iter().any(|n| n.kind == brain_core::NodeKind::Memory)
    );
    println!("  session node found: {}", !session_nodes.is_empty());
    println!(
        "\nscratch dir left on disk for inspection: {}",
        scratch.display()
    );
}

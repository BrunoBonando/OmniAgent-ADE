pub mod commands;
pub mod feedback;
pub mod map_feed;
pub mod roots;
pub mod sessions;
pub mod tmux;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use tauri::{Emitter, Manager};

use commands::BrainState;
use roots::IngestionState;
use sessions::SessionManager;

/// How often the background enrichment worker drains `enrich_queue`
/// (`project_summary`/`community_summary`/Task 7.1's `session_summary`).
/// PLAN.md Task 7.1 names this exact cadence: "Phase 4 worker, now spawned
/// as a background thread in the app on a 60 s tick". Phase 4/5's own
/// reports named this as a gap — nothing before this task actually spawned
/// it, so without this loop `session_summary` jobs (and project/community
/// summaries) would only ever drain via a manual `brain drain` CLI call,
/// which defeats "compounds automatically" (DESIGN.md's whole pitch for
/// this phase). Plain `std::thread::spawn` + sleep loop, matching this
/// crate's existing background-thread style (`sessions.rs`'s PTY reader
/// threads) rather than pulling in an async runtime for one timer.
const DRAIN_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

/// One tick of the enrichment drain loop's work: open a fresh `Store` and
/// drain the queue, logging the outcome. Extracted from the background
/// thread's loop body (see `run`'s `.setup()`) so it's directly
/// unit-testable and so `std::panic::catch_unwind` (wrapped around calls
/// to this by both `run()`'s real loop and this module's own tests) has a
/// single, clean call boundary. A panic anywhere in here (a malformed
/// queue payload, an engine that panics instead of erroring, ...) must
/// never be allowed to silently and permanently kill this thread — before
/// this fix it would, stopping all future enrichment forever with only an
/// easy-to-miss stderr line.
fn drain_tick(data_dir: &std::path::Path, engine: &dyn brain_ingest::enrich::EnrichEngine) {
    match brain_core::Store::open(data_dir) {
        Ok(store) => match brain_ingest::enrich::drain_queue(&store, data_dir, engine) {
            Ok(n) if n > 0 => eprintln!("omniagent-ade: drained {n} enrichment job(s)"),
            Ok(_) => {}
            Err(e) => eprintln!("omniagent-ade: drain_queue error: {e}"),
        },
        Err(e) => {
            eprintln!("omniagent-ade: failed to open brain store for the drain loop: {e}")
        }
    }
}

/// Renders a caught panic's payload as a human-readable string for
/// logging. `std::panic::catch_unwind`'s `Err` is `Box<dyn Any + Send>`,
/// which is almost always either a `&'static str` (a bare `panic!("...")`
/// literal) or an owned `String` (`panic!("{}", ...)`/`.unwrap()`/
/// `.expect(...)` messages); anything else falls back to a generic label
/// rather than failing to log at all.
pub(crate) fn panic_message(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "non-string panic payload".to_string()
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        // Task 8.1: FirstRun's native folder picker ("Where do your
        // projects live?").
        .plugin(tauri_plugin_dialog::init())
        // Standard macOS app menu (App/Edit/Window submenus — Quit, Hide,
        // Cut/Copy/Paste/Select All, Close Window, Minimize). App-specific
        // shortcuts (⌘T new tab, ⌘K command palette) are handled in the
        // React shell via a keydown listener rather than as native menu
        // accelerators — this is the standard Tauri pattern for shortcuts
        // that need to reach into live UI state (which tab, which project)
        // rather than firing a static menu event. This menu's job is just
        // making sure ⌘W/⌘Q/⌘M etc. behave like a normal Mac app instead of
        // doing nothing (Tauri ships no menu at all by default).
        .menu(tauri::menu::Menu::default)
        .setup(|app| {
            let handle = app.handle().clone();
            let data_dir = brain_core::Store::default_data_dir();

            let brain = BrainState::open(data_dir.clone())
                .map_err(|e| format!("failed to open brain store at {data_dir:?}: {e}"))?;
            app.manage(brain);

            let output_handle = handle.clone();
            let sink: sessions::OutputSink = std::sync::Arc::new(move |id: &str, chunk: &[u8]| {
                let payload = STANDARD.encode(chunk);
                let _ = output_handle.emit(&format!("session-output:{id}"), payload);
            });

            // Founder feedback (Bruno, 2026-07-24): a session that needs the
            // user's attention (right now: a Claude Code tool-permission
            // prompt — see `sessions.rs`'s module docs, "Attention
            // detection", for what was tried and why this is what's real)
            // should surface a badge until the user actually looks at that
            // tab. `sessions::SessionManager`'s PTY reader thread already
            // does the detection + per-session debouncing; this closure is
            // just the same thin Tauri-emit adapter `sink` above already is
            // for `session-output:{id}`, following the same naming
            // convention (`session-attention:{id}`). Payload is just the
            // fire timestamp (unix seconds) — nothing in the frontend reads
            // it today, it's here for the same reason lifecycle events carry
            // one (cheap to have, useful if a "how long has this been
            // waiting" affordance shows up later).
            let attention_handle = handle.clone();
            let attention_sink: sessions::AttentionSink =
                std::sync::Arc::new(move |id: &str| {
                    let _ = attention_handle
                        .emit(&format!("session-attention:{id}"), brain_core::now_ts());
                });

            // Task 7.1: the feedback-loop hook. Opens its own short-lived
            // `Store` connection per session end rather than sharing the
            // Mutex-guarded one behind `BrainState` — SQLite handles
            // multiple local connections to the same `brain.db` file fine
            // for this write volume (one INSERT per session end), and doing
            // it this way avoids threading a second reference to
            // `BrainState` through `SessionManager`'s constructor just for
            // this.
            let feedback_data_dir = data_dir.clone();
            let end_hook: sessions::SessionEndHook = std::sync::Arc::new(move |event| {
                match brain_core::Store::open(&feedback_data_dir) {
                    Ok(store) => {
                        if let Err(e) = feedback::on_session_end(&store, event) {
                            eprintln!(
                                "omniagent-ade: failed to enqueue session_summary for {}: {e}",
                                event.id
                            );
                        }
                    }
                    Err(e) => eprintln!(
                        "omniagent-ade: failed to open brain store for the feedback hook: {e}"
                    ),
                }
            });
            // Founder brief (Bruno, 2026-07-26): "Green means ready for any
            // new command, yellow means executing, red means requires
            // attention or input." Same thin Tauri-emit adapter shape as
            // `sink`/`attention_sink` above, same event-naming convention
            // (`session-status:{id}`). The payload is the state string
            // ("ready" | "executing" | "attention"); `sessions.rs` only calls
            // this when a session's state actually *changes*, so this is a
            // handful of events per session per minute, not a per-frame feed.
            // The pull counterpart is `commands::session_status`, for a pane
            // that just mounted and needs the current light immediately.
            let status_handle = handle.clone();
            let status_sink: sessions::StatusSink =
                std::sync::Arc::new(move |id: &str, status: sessions::SessionStatus| {
                    let _ = status_handle.emit(&format!("session-status:{id}"), status.as_str());
                });

            // Founder brief (same day): "Every new claude or terminal or
            // codex session, must be stored, if not properly closed… Maybe
            // it's nice to keep the session as tmux, regardless of agent."
            // `default_tmux` resolves tmux once (against the user's real
            // shell PATH — a GUI-launched .app has no Homebrew on its own
            // PATH) and writes this app's private tmux config. `None` here
            // means tmux simply isn't installed, which `SessionManager`
            // handles by spawning engines directly, exactly as it did before
            // persistence existed — never an error, never a blocked session.
            let tmux = sessions::default_tmux(&data_dir);
            if tmux.is_none() {
                eprintln!(
                    "omniagent-ade: tmux not found — sessions will run directly and will NOT \
                     survive the app closing (install tmux to enable session restore)"
                );
            }
            app.manage(
                SessionManager::new(data_dir.clone(), sink)
                    .with_tmux(tmux)
                    .with_end_hook(end_hook)
                    .with_attention_sink(attention_sink)
                    .with_status_sink(status_sink),
            );

            // Task 8.1: onboarding/rebuild ingestion progress, polled by the
            // frontend via `roots::ingestion_status` every ~2s.
            app.manage(IngestionState::new());

            // Part A file tree write side (founder feedback, 2026-07-25):
            // one registry of per-directory `notify` watchers, backing
            // `commands::watch_dir`/`unwatch_dir` so the file tree can
            // reflect external changes (Finder, an agent, git) without a
            // manual refresh. Same "closure captures the AppHandle, wired
            // once in .setup()" pattern as `sink`/`attention_sink` above —
            // see `brain_ingest::dirwatch`'s module doc for the full
            // lifecycle design (idempotent watch, no leaked watchers).
            let dirwatch_handle = handle.clone();
            let dirwatch_sink: brain_ingest::dirwatch::ChangeSink =
                std::sync::Arc::new(move |path: &std::path::Path| {
                    let _ = dirwatch_handle.emit(
                        &format!("dir-changed:{}", path.display()),
                        brain_core::now_ts(),
                    );
                });
            app.manage(brain_ingest::dirwatch::DirWatchRegistry::new(dirwatch_sink));

            // Task 7.1 / gap flagged in Phase 4's own report: nothing before
            // this spawned a periodic drain, so enrichment (including this
            // phase's session_summary jobs) only ever ran via a manual
            // `brain drain` CLI call. This thread is what makes the
            // feedback loop — and project/community summaries — actually
            // run unattended, per PLAN.md Task 7.1's own wording.
            let drain_data_dir = data_dir;
            std::thread::spawn(move || {
                let engine = brain_ingest::enrich::ClaudeEngine;
                loop {
                    std::thread::sleep(DRAIN_INTERVAL);
                    // Panic isolation (founder-visible gap: a panic in
                    // here used to kill this thread silently and
                    // permanently, stopping all future enrichment with
                    // only an unobserved stderr line). `AssertUnwindSafe`
                    // is sound here: `drain_tick` only ever touches its
                    // `Store`/`EnrichEngine` through calls that are fully
                    // scoped to this one tick — nothing is held across the
                    // `catch_unwind` boundary itself, so there's no
                    // partially-mutated state left dangling by an
                    // interrupted tick for the *next* tick to trip over; a
                    // fresh `Store::open` next time around starts clean
                    // regardless.
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        drain_tick(&drain_data_dir, &engine);
                    }));
                    if let Err(payload) = result {
                        eprintln!(
                            "omniagent-ade: PANIC in enrichment drain loop iteration (caught, \
                             thread continues on the next {DRAIN_INTERVAL:?} tick): {}",
                            panic_message(&payload)
                        );
                    }
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            greet,
            commands::session_create,
            commands::session_write,
            commands::session_resize,
            commands::session_kill,
            commands::session_status,
            commands::git_branch,
            commands::list_dir,
            commands::rename_path,
            commands::move_path,
            commands::duplicate_path,
            commands::delete_to_trash,
            commands::create_file,
            commands::create_dir,
            commands::watch_dir,
            commands::unwatch_dir,
            commands::detect_importable_tools,
            commands::list_import_candidates,
            commands::brain_query,
            commands::brain_get_context,
            commands::brain_briefing,
            commands::settings_get,
            commands::settings_set,
            map_feed::map_graph,
            map_feed::map_node_detail,
            feedback::pending_notes_list,
            feedback::pending_notes_approve,
            feedback::pending_notes_discard,
            roots::roots_start_ingest,
            roots::add_project,
            roots::rename_project,
            roots::ingestion_status,
            roots::roots_list,
            roots::roots_biggest_project,
            roots::roots_paused_projects,
            roots::roots_set_paused,
            roots::roots_staleness,
            roots::roots_reingest_project,
            roots::roots_rebuild,
            commands::enrich_queue_pending_count,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_ingest::enrich::{EngineError, EnrichEngine};
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Test double for `EnrichEngine` that panics on its first call and
    /// succeeds on every call after that — stands in for "something inside
    /// one drain tick genuinely panics" (a malformed payload, a buggy
    /// engine, ...) without needing a real `claude` CLI.
    struct PanicOnceEngine {
        calls: AtomicUsize,
    }

    impl PanicOnceEngine {
        fn new() -> Self {
            Self { calls: AtomicUsize::new(0) }
        }
    }

    impl EnrichEngine for PanicOnceEngine {
        fn run(&self, _prompt: &str) -> Result<String, EngineError> {
            let n = self.calls.fetch_add(1, Ordering::SeqCst);
            if n == 0 {
                panic!("simulated panic on the first drain_tick's engine call");
            }
            Ok("fine".to_string())
        }
    }

    /// Bug: a panic anywhere inside one drain-loop tick (the real thread
    /// loop in `run()`'s `.setup()`) used to kill that background thread
    /// silently and permanently — stopping all future enrichment forever
    /// with only an unobserved stderr line, and nothing telling the user.
    ///
    /// Reproduces "one iteration panics, the loop keeps running
    /// afterward" without spinning up the real infinite background thread:
    /// `drain_tick` is invoked directly, wrapped in exactly the same
    /// `catch_unwind(AssertUnwindSafe(...))` the real loop body wraps it
    /// in, twice in a row against the same store/queue — first call
    /// panics (caught), second call must still succeed normally, proving
    /// nothing about the panic left the "loop" (here: repeated direct
    /// calls) permanently broken.
    #[test]
    fn drain_loop_panic_in_one_iteration_is_caught_and_the_next_iteration_still_runs() {
        let dir = tempfile::tempdir().unwrap();
        let store = brain_core::Store::open(dir.path()).unwrap();
        store
            .upsert_node(&brain_core::Node {
                id: "p1".into(),
                kind: brain_core::NodeKind::Project,
                project: "p1".into(),
                label: "p1".into(),
                path: Some(dir.path().to_string_lossy().into_owned()),
                summary: None,
                origin: brain_core::Origin::Extracted,
                updated: brain_core::now_ts(),
            })
            .unwrap();
        store
            .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
            .unwrap();

        let engine = PanicOnceEngine::new();

        // Iteration 1 (mirrors one real drain-loop tick): the engine
        // panics mid-drain.
        let first = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            drain_tick(dir.path(), &engine);
        }));
        assert!(first.is_err(), "the first tick's engine call must have panicked");

        // Iteration 2: proves the loop is still alive and functional
        // afterward -- a second tick against the *same* store/queue
        // succeeds normally, which would be impossible if the panic had
        // actually killed the (simulated) thread.
        let second = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            drain_tick(dir.path(), &engine);
        }));
        assert!(second.is_ok(), "the loop must keep running after a caught panic");

        // And the job that was pending during the panicked tick actually
        // got drained on the next go-around -- not silently lost.
        assert!(store.pending_jobs(10).unwrap().is_empty());
    }

    #[test]
    fn panic_message_extracts_str_and_string_payloads_with_a_sensible_fallback() {
        let str_payload: Box<dyn std::any::Any + Send> = Box::new("boom");
        assert_eq!(panic_message(&str_payload), "boom");

        let string_payload: Box<dyn std::any::Any + Send> = Box::new("boom".to_string());
        assert_eq!(panic_message(&string_payload), "boom");

        let other_payload: Box<dyn std::any::Any + Send> = Box::new(42i32);
        assert_eq!(panic_message(&other_payload), "non-string panic payload");
    }
}

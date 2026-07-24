pub mod commands;
pub mod feedback;
pub mod map_feed;
pub mod roots;
pub mod sessions;

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

            let sink: sessions::OutputSink = std::sync::Arc::new(move |id: &str, chunk: &[u8]| {
                let payload = STANDARD.encode(chunk);
                let _ = handle.emit(&format!("session-output:{id}"), payload);
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
            app.manage(SessionManager::new(data_dir.clone(), sink).with_end_hook(end_hook));

            // Task 8.1: onboarding/rebuild ingestion progress, polled by the
            // frontend via `roots::ingestion_status` every ~2s.
            app.manage(IngestionState::new());

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
                    match brain_core::Store::open(&drain_data_dir) {
                        Ok(store) => {
                            match brain_ingest::enrich::drain_queue(&store, &drain_data_dir, &engine)
                            {
                                Ok(n) if n > 0 => {
                                    eprintln!("omniagent-ade: drained {n} enrichment job(s)")
                                }
                                Ok(_) => {}
                                Err(e) => eprintln!("omniagent-ade: drain_queue error: {e}"),
                            }
                        }
                        Err(e) => eprintln!(
                            "omniagent-ade: failed to open brain store for the drain loop: {e}"
                        ),
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

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

/// The app's native menu bar: Tauri's standard macOS menu with **every
/// `close_window` item removed**.
///
/// Founder bug (Bruno, 2026-07-26): *"cmd+w is closing the full app instead of
/// confirming closing the current terminal"*. In this app a pane is the unit a
/// user closes, not the window — the window holds every project, every session
/// and every tab, so the native "Close Window" is a destructive
/// button-with-no-undo sitting on the most reflexive shortcut on macOS.
///
/// It has to be removed *here* rather than swallowed in JS: a native menu
/// accelerator is handled by AppKit before the key event ever reaches the
/// webview, so a `preventDefault` in the React handler cannot win a race it is
/// never entered into. With no menu item bound to ⌘W, the keystroke falls
/// through to the webview like any other and `App.tsx`'s keydown handler owns
/// it (`ui/src/App.tsx`, "⌘T new tab / ⌘K palette / ⌘W close pane").
///
/// This mirrors `tauri::menu::Menu::default` (tauri 2.11.5) item for item, so
/// ⌘Q/⌘M/⌘H/⌘Z/⌘C/⌘V and the rest keep behaving exactly like a normal Mac
/// app, with two deliberate differences:
/// - the **File** submenu is dropped entirely — on macOS its only item *was*
///   `close_window`, so keeping it would leave an empty menu;
/// - the **Window** submenu keeps Minimize/Maximize but loses `close_window`.
///
/// Both had to go: `Menu::default` binds ⌘W in *two* places, and leaving
/// either one would keep closing the window out from under the JS handler.
fn build_menu<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
) -> tauri::Result<tauri::menu::Menu<R>> {
    use tauri::menu::{AboutMetadata, Menu, PredefinedMenuItem, Submenu};

    let pkg_info = app.package_info();
    let config = app.config();
    let about_metadata = AboutMetadata {
        name: Some(pkg_info.name.clone()),
        version: Some(pkg_info.version.to_string()),
        copyright: config.bundle.copyright.clone(),
        authors: config.bundle.publisher.clone().map(|p| vec![p]),
        ..Default::default()
    };

    let mut submenus = Vec::new();
    for (title, entries) in MENU_BAR {
        let mut items: Vec<PredefinedMenuItem<R>> = Vec::with_capacity(entries.len());
        for entry in *entries {
            items.push(match entry {
                MenuEntry::About => {
                    PredefinedMenuItem::about(app, None, Some(about_metadata.clone()))?
                }
                MenuEntry::Separator => PredefinedMenuItem::separator(app)?,
                MenuEntry::Services => PredefinedMenuItem::services(app, None)?,
                MenuEntry::Hide => PredefinedMenuItem::hide(app, None)?,
                MenuEntry::HideOthers => PredefinedMenuItem::hide_others(app, None)?,
                MenuEntry::Quit => PredefinedMenuItem::quit(app, None)?,
                MenuEntry::Undo => PredefinedMenuItem::undo(app, None)?,
                MenuEntry::Redo => PredefinedMenuItem::redo(app, None)?,
                MenuEntry::Cut => PredefinedMenuItem::cut(app, None)?,
                MenuEntry::Copy => PredefinedMenuItem::copy(app, None)?,
                MenuEntry::Paste => PredefinedMenuItem::paste(app, None)?,
                MenuEntry::SelectAll => PredefinedMenuItem::select_all(app, None)?,
                MenuEntry::Fullscreen => PredefinedMenuItem::fullscreen(app, None)?,
                MenuEntry::Minimize => PredefinedMenuItem::minimize(app, None)?,
                MenuEntry::Maximize => PredefinedMenuItem::maximize(app, None)?,
            });
        }
        let refs: Vec<&dyn tauri::menu::IsMenuItem<R>> =
            items.iter().map(|i| i as &dyn tauri::menu::IsMenuItem<R>).collect();
        let title = if *title == APP_SUBMENU {
            pkg_info.name.clone()
        } else {
            (*title).to_string()
        };
        submenus.push(Submenu::with_items(app, title, true, &refs)?);
    }

    let refs: Vec<&dyn tauri::menu::IsMenuItem<R>> = submenus
        .iter()
        .map(|s| s as &dyn tauri::menu::IsMenuItem<R>)
        .collect();
    Menu::with_items(app, &refs)
}

/// Placeholder for the leftmost submenu, whose real title is the app's own
/// name (`package_info().name`) rather than a literal.
const APP_SUBMENU: &str = "<app>";

/// Every predefined item this app's menu bar is allowed to contain.
///
/// **There is deliberately no `CloseWindow` variant.** That is the fix, stated
/// in the type system rather than as an item somebody remembered to delete:
/// ⌘W belongs to the focused pane (see [`build_menu`]), so a native menu item
/// that closes the window cannot be expressed here at all.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum MenuEntry {
    About,
    Separator,
    Services,
    Hide,
    HideOthers,
    Quit,
    Undo,
    Redo,
    Cut,
    Copy,
    Paste,
    SelectAll,
    Fullscreen,
    Minimize,
    Maximize,
}

/// The menu bar, as data: `Menu::default`'s macOS layout minus every
/// `close_window`. The **File** submenu is absent entirely because on macOS
/// `close_window` was the only thing in it.
///
/// One description, read both by [`build_menu`] (which materializes it) and by
/// this module's tests (which assert on it) — so the two cannot drift, and the
/// assertion doesn't need a main-thread AppKit menu to run against.
const MENU_BAR: &[(&str, &[MenuEntry])] = &[
    (
        APP_SUBMENU,
        &[
            MenuEntry::About,
            MenuEntry::Separator,
            MenuEntry::Services,
            MenuEntry::Separator,
            MenuEntry::Hide,
            MenuEntry::HideOthers,
            MenuEntry::Separator,
            MenuEntry::Quit,
        ],
    ),
    (
        "Edit",
        &[
            MenuEntry::Undo,
            MenuEntry::Redo,
            MenuEntry::Separator,
            MenuEntry::Cut,
            MenuEntry::Copy,
            MenuEntry::Paste,
            MenuEntry::SelectAll,
        ],
    ),
    ("View", &[MenuEntry::Fullscreen]),
    ("Window", &[MenuEntry::Minimize, MenuEntry::Maximize]),
];

/// The window title, with the shipped version in it (founder ask, Bruno,
/// 2026-07-26: *"Add on the title of the app OmniAgent - {number of version,
/// example: v2.3}"*).
///
/// Built from `package_info().version` and set at runtime rather than written
/// into `tauri.conf.json`'s static `windows[0].title`, so there is exactly one
/// version string in the repo. That call is genuinely the shipped version and
/// not a second copy of it: `tauri::generate_context!` compiles
/// `PackageInfo::version` **from `tauri.conf.json`'s own `version` field**
/// (falling back to `CARGO_PKG_VERSION` only when the config omits it —
/// `tauri-codegen` 2.6.3, `context.rs`), which is the same value the bundler
/// stamps into the `.app`. Bump the config, and the title, the bundle and the
/// About panel all move together.
///
/// `productName` deliberately stays plain `OmniAgent`: it names the `.app`
/// bundle and the menu-bar item, where a version number would be noise.
fn window_title(version: &str) -> String {
    format!("OmniAgent — v{version}")
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        // Task 8.1: FirstRun's native folder picker ("Where do your
        // projects live?").
        .plugin(tauri_plugin_dialog::init())
        // Standard macOS app menu, minus ⌘W — see [`build_menu`].
        .menu(build_menu)
        .setup(|app| {
            let handle = app.handle().clone();
            let data_dir = brain_core::Store::default_data_dir();

            // Founder ask: the window title carries the version. Set here
            // rather than in `tauri.conf.json` so the version lives in exactly
            // one place — see [`window_title`].
            let title = window_title(&app.package_info().version.to_string());
            for (_, window) in app.webview_windows() {
                let _ = window.set_title(&title);
            }

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
            // Founder brief (Bruno, 2026-07-26), revised the same day from
            // three states to five: white/blue thinking · green ready · amber
            // awaiting approval · red error · cyan tool execution — "but only
            // green, yellow or red generate a notification". Same thin
            // Tauri-emit adapter shape as `sink`/`attention_sink` above, same
            // event-naming convention (`session-status:{id}`).
            //
            // The payload is the whole `SessionStatusEvent` struct
            // (`{id, status, notify, engine}`) rather than a bare state
            // string: `notify` is the backend's answer to Bruno's
            // notification rule, so the notifications panel consumes a
            // decision instead of re-deriving one (see
            // `sessions::SessionStatus::notifies`). `sessions.rs` only calls
            // this when a session's state actually *changes*, so this is a
            // handful of events per session per minute, not a per-frame feed.
            // The pull counterpart is `commands::session_status`, which
            // returns the identical shape for a pane that just mounted.
            let status_handle = handle.clone();
            let status_sink: sessions::StatusSink =
                std::sync::Arc::new(move |event: &sessions::SessionStatusEvent| {
                    let _ = status_handle.emit(&format!("session-status:{}", event.id), event);
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
            commands::folder_stats,
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
            commands::review_status,
            commands::review_file_diff,
            commands::review_commit,
            commands::review_revert_file,
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
            commands::agents::agents_check_installed,
            commands::agents::agents_install,
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

    // -- ⌘W belongs to the focused pane, not to the window (founder bug,
    // 2026-07-26) --------------------------------------------------------

    /// The menu must not contain a **Close Window** item anywhere.
    ///
    /// This is the whole fix: `Menu::default` binds `close_window` — and with
    /// it ⌘W — in *two* submenus (File and Window), AppKit handles a native
    /// accelerator before the webview ever sees the key, and so the React
    /// handler could never have won. Asserted structurally rather than by
    /// reading accelerators, because `muda` exposes no accelerator getter:
    /// the top-level submenus are pinned exactly (no **File**, which on macOS
    /// held nothing but `close_window`), and **Window** is pinned to exactly
    /// its two survivors.
    #[test]
    fn the_native_menu_binds_no_close_window_item_anywhere() {
        // Asserted against [`MENU_BAR`], the same data `build_menu`
        // materializes, because a real `muda` menu can only be constructed on
        // the main thread — which a test thread never is.
        let titles: Vec<&str> = MENU_BAR.iter().map(|(t, _)| *t).collect();
        assert_eq!(
            titles,
            vec![APP_SUBMENU, "Edit", "View", "Window"],
            "the File submenu must stay gone — on macOS its only item was Close Window"
        );

        let window = MENU_BAR
            .iter()
            .find(|(t, _)| *t == "Window")
            .map(|(_, items)| *items)
            .expect("a Window submenu");
        assert_eq!(
            window,
            [MenuEntry::Minimize, MenuEntry::Maximize],
            "Window must hold only Minimize and Maximize; anything else here is a \
             window-closing item creeping back in and taking ⌘W with it"
        );

        // And nothing anywhere else sneaks one in. `MenuEntry` has no
        // `CloseWindow` variant to begin with, so this is really a statement
        // that no *other* entry acquired that behaviour — kept as an explicit
        // sweep so the intent survives someone adding a variant.
        for (title, entries) in MENU_BAR {
            for entry in *entries {
                assert!(
                    !format!("{entry:?}").to_lowercase().contains("close"),
                    "{title} contains a closing item: {entry:?}"
                );
            }
        }
    }

    /// The window title carries the shipped version, and carries it in the
    /// shape the founder asked for (`OmniAgent — v0.1.0`).
    #[test]
    fn the_window_title_carries_the_version() {
        assert_eq!(window_title("0.1.0"), "OmniAgent — v0.1.0");
        assert_eq!(window_title("2.3"), "OmniAgent — v2.3");
    }

    /// …and that version is the one `tauri.conf.json` declares, not a second
    /// copy of it living in Rust. `mock_app` is built from this crate's real
    /// `tauri.conf.json` via `generate_context!`, so this compares the title
    /// the app will actually show against the config file on disk.
    #[test]
    fn the_titles_version_is_the_one_tauri_conf_json_declares() {
        let config: serde_json::Value =
            serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        let declared = config["version"].as_str().expect("tauri.conf.json version");

        let app = tauri::test::mock_app();
        assert_eq!(
            window_title(&app.handle().package_info().version.to_string()),
            window_title(declared),
            "the runtime version and tauri.conf.json have drifted apart"
        );
        // And productName stays plain — it names the .app bundle and the
        // menu-bar item, where a version number would just be noise.
        assert_eq!(config["productName"].as_str(), Some("OmniAgent"));
        assert_eq!(config["app"]["windows"][0]["title"].as_str(), Some("OmniAgent"));
    }

    // -- the window hands its title bar to the web content (founder ask,
    // 2026-07-26: "The user and notification menu must be on the title of
    // the application, just like warp does") ----------------------------

    /// The account badge and the notifications bell can only sit *in* the
    /// title bar if the window is configured to let web content draw there.
    ///
    /// The real `tauri.conf.json` is deserialized here through Tauri's own
    /// `WindowConfig` — deliberately not compared as JSON strings, because
    /// `TitleBarStyle`'s `Deserialize` falls back to `Visible` for
    /// *anything* it doesn't recognise (tauri-utils 2.9.3, `lib.rs`): no
    /// error, no warning. A typo like `"overlays"` would silently restore
    /// the opaque native title bar, push the whole app back down 28px and
    /// strand the chrome underneath it — and a string assertion would
    /// happily pass while that happened. Running the actual parser is the
    /// only check that can't be fooled.
    ///
    /// (`tauri::test::mock_app()` is no use here: its context is built from
    /// `noop_assets()` and carries Tauri's *default* config, not this
    /// crate's file.)
    #[test]
    fn the_window_hands_its_title_bar_to_the_web_content() {
        use tauri::utils::config::WindowConfig;
        use tauri::utils::TitleBarStyle;

        let config: serde_json::Value =
            serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        let window: WindowConfig =
            serde_json::from_value(config["app"]["windows"][0].clone()).expect("the main window");

        assert_eq!(
            window.title_bar_style,
            TitleBarStyle::Overlay,
            "the title bar must be an overlay over the web content — without it the account \
             badge and notifications bell have no title bar to live in, and note that an \
             unrecognised value deserialises to Visible in silence"
        );

        // `Overlay` keeps the *native* traffic lights; turning decorations
        // off would remove them (and would mean reimplementing close/
        // minimise/zoom by hand, plus lose the native title). It is also a
        // documented precondition for `trafficLightPosition`.
        assert!(
            window.decorations,
            "decorations must stay on — they are what draws the real traffic lights"
        );

        // The window title (`window_title` above, set at runtime with the
        // shipped version) is drawn by AppKit over our chrome. Hiding it
        // would mean re-presenting the version somewhere by hand.
        assert!(
            !window.hidden_title,
            "the title must stay visible — it is how the version reaches the title bar"
        );

        // …and it must be legible against our own dark chrome. With a
        // transparent title bar AppKit draws the title in the window's
        // appearance, so a Light-mode Mac would paint dark text onto the
        // near-black strip underneath it. Pinning the window to Dark is what
        // keeps the title readable regardless of the user's system setting —
        // correct for this app in any case, its whole shell is dark.
        assert_eq!(
            window.theme,
            Some(tauri::utils::Theme::Dark),
            "the window must be pinned to the dark appearance or the native title goes \
             dark-on-dark for Light-mode users"
        );
    }

    /// Dragging the window by its title bar has to be *granted*, not just
    /// marked up.
    ///
    /// With `titleBarStyle: Overlay` the webview covers the title bar, so
    /// the only thing that still moves the window is Tauri's
    /// `data-tauri-drag-region` (`AppChrome.tsx`) — and that attribute is
    /// inert on its own: its handler invokes `plugin:window|start_dragging`,
    /// which **`core:window:default` does not include** (checked against
    /// `gen/schemas/acl-manifests.json`: the default set grants
    /// `allow-internal-toggle-maximize` but not `allow-start-dragging`).
    /// Without the explicit grant the window simply stops being draggable,
    /// with nothing but a rejected IPC call in the console to say why.
    #[test]
    fn the_title_bars_drag_region_is_actually_permitted() {
        let capability: serde_json::Value =
            serde_json::from_str(include_str!("../capabilities/default.json")).unwrap();
        let permissions = capability["permissions"]
            .as_array()
            .expect("the default capability's permission list");

        assert!(
            permissions
                .iter()
                .any(|p| p.as_str() == Some("core:window:allow-start-dragging")),
            "`core:window:allow-start-dragging` must be granted explicitly — it is NOT part \
             of `core:window:default`, and without it the title bar's drag region is dead"
        );
    }
}

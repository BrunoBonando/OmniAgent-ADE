pub mod commands;
pub mod map_feed;
pub mod sessions;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use tauri::{Emitter, Manager};

use commands::BrainState;
use sessions::SessionManager;

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
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
            app.manage(SessionManager::new(data_dir, sink));
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
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

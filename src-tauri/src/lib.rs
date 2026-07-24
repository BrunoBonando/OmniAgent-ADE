pub mod commands;
pub mod sessions;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use tauri::{Emitter, Manager};

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
        .setup(|app| {
            let handle = app.handle().clone();
            let data_dir = brain_core::Store::default_data_dir();
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
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

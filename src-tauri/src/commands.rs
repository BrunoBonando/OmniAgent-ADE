//! Thin `#[tauri::command]` wrappers around [`crate::sessions::SessionManager`].
//!
//! All the actual PTY logic lives in `sessions.rs` and is independently
//! testable without Tauri; these functions only adapt that API to Tauri's
//! calling convention (`State` extraction, `Result<T, String>` so failures
//! surface as rejected promises on the JS side instead of panics).

use tauri::State;

use crate::sessions::{CreateSessionRequest, SessionInfo, SessionManager};

/// Creates a new PTY session running `engine` ("claude" | "codex" | "shell")
/// in `cwd`. For `engine == "claude"`, `briefing` (if provided) is forwarded
/// verbatim to `claude --append-system-prompt`; ignored for other engines.
/// See `sessions.rs` module docs for the full zero-config MCP wiring.
#[tauri::command]
pub fn session_create(
    project: String,
    engine: String,
    cwd: String,
    briefing: Option<String>,
    manager: State<'_, SessionManager>,
) -> Result<SessionInfo, String> {
    manager
        .create(CreateSessionRequest {
            project,
            engine,
            cwd,
            briefing,
        })
        .map_err(|e| e.to_string())
}

/// Writes raw bytes (keystrokes, pasted text, control sequences) to a
/// session's PTY.
#[tauri::command]
pub fn session_write(
    id: String,
    data: String,
    manager: State<'_, SessionManager>,
) -> Result<(), String> {
    manager.write(&id, &data).map_err(|e| e.to_string())
}

/// Resizes a session's PTY — call whenever the terminal pane's fit-addon
/// recomputes rows/cols.
#[tauri::command]
pub fn session_resize(
    id: String,
    cols: u16,
    rows: u16,
    manager: State<'_, SessionManager>,
) -> Result<(), String> {
    manager.resize(&id, cols, rows).map_err(|e| e.to_string())
}

/// Kills a session's process and synchronously reaps it.
#[tauri::command]
pub fn session_kill(id: String, manager: State<'_, SessionManager>) -> Result<(), String> {
    manager.kill(&id).map_err(|e| e.to_string())
}

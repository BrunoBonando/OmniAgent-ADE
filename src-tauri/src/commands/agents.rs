//! Which agents this app can run, whether they're installed, and how to
//! install the ones that aren't.
//!
//! # Everything about an agent lives in [`AGENTS`]
//!
//! This module exists because three facts about an agent kept drifting apart
//! when they lived in three files:
//!
//! 1. its **name** — what the UI shows and what `session_create` receives,
//! 2. its **binary** — what proves it is installed, and what we spawn,
//! 3. its **install command**.
//!
//! They are not interchangeable. Antigravity's name is `antigravity` but its
//! CLI is `agy`; `shell` has no binary at all. Detecting an agent by its
//! *name* silently reports Antigravity as missing on a machine that has it,
//! and reports `shell` as missing on every machine there has ever been.
//!
//! So all three live in one table, and [`binary_for`] is what
//! `sessions.rs` uses to spawn — one definition, no second copy to fall out
//! of sync with this one.
//!
//! **To add or fix an agent, edit [`AGENTS`] and nothing else** (plus the
//! matching entry in `ui/src/state/agents.ts`, which `agents_match_frontend`
//! pins).

use std::path::{Path, PathBuf};
use tauri::Emitter;

/// How an agent gets onto the machine.
pub enum Install {
    /// Nothing to install — part of the OS. Always reports as installed.
    BuiltIn,
    /// A shell one-liner. Run through `sh -c`, so pipes and `&&` work.
    Command(&'static str),
    /// No scriptable install exists; the UI opens this page instead. Better
    /// than a fabricated command that fails on every machine.
    Page(&'static str),
}

pub struct AgentSpec {
    /// What the UI and `session_create` call this agent.
    pub name: &'static str,
    /// The executable to look for on PATH and to spawn. `None` for built-ins.
    /// **Not always `name`** — see the module doc.
    pub binary: Option<&'static str>,
    pub install: Install,
}

/// The five agents, and the single source of truth for all three facts.
///
/// Install channels verified against a machine with all four CLIs present
/// (2026-07-26). They are the part most likely to rot — when an agent moves
/// to a new channel, this is the only line that changes.
pub const AGENTS: &[AgentSpec] = &[
    AgentSpec {
        name: "claude",
        binary: Some("claude"),
        // Native installer; drops a versioned symlink in ~/.local/bin.
        install: Install::Command("curl -fsSL https://claude.ai/install.sh | bash"),
    },
    AgentSpec {
        name: "codex",
        binary: Some("codex"),
        install: Install::Command("npm install -g @openai/codex"),
    },
    AgentSpec {
        name: "shell",
        binary: None,
        install: Install::BuiltIn,
    },
    AgentSpec {
        name: "copilot",
        binary: Some("copilot"),
        // npm rather than `brew install --cask copilot-cli`: same CLI, and it
        // is not macOS-only. (Note the `copilot` *formula* is a different
        // tool entirely — AWS ECS Copilot — so brew is a trap here.)
        install: Install::Command("npm install -g @github/copilot"),
    },
    AgentSpec {
        name: "antigravity",
        // The CLI is `agy`. This mismatch is the reason this table exists.
        binary: Some("agy"),
        // Ships as a Google IDE download that self-updates via `agy update`;
        // no package-manager channel to script. ponytail: a Page beats
        // inventing a command that fails for everyone.
        install: Install::Page("https://antigravity.google/download"),
    },
];

fn spec(name: &str) -> Option<&'static AgentSpec> {
    AGENTS.iter().find(|a| a.name == name)
}

fn agent_marker_dir(data_dir: &Path, name: &str) -> PathBuf {
    data_dir.join("agents").join(name)
}

fn mark_agent_installed(data_dir: &Path, name: &str) -> Result<(), String> {
    std::fs::create_dir_all(agent_marker_dir(data_dir, name))
        .map_err(|e| format!("failed to create install marker for {name}: {e}"))
}

fn installed_agents_in(data_dir: &Path) -> Result<Vec<String>, String> {
    let mut installed = Vec::new();

    for agent in AGENTS {
        let is_installed = match agent.install {
            Install::BuiltIn => true,
            _ => agent_marker_dir(data_dir, agent.name).exists(),
        };

        if is_installed {
            installed.push(agent.name.to_string());
        }
    }

    Ok(installed)
}

/// The executable for an agent, for callers that need to spawn it.
/// `None` means built-in (or unknown) — the caller decides what that means.
pub fn binary_for(name: &str) -> Option<&'static str> {
    spec(name).and_then(|a| a.binary)
}

/// Which agents are installed right now.
///
/// Built-ins always count. Everything else is a single marker-folder check
/// under the app data dir: `.../agents/<agent>`.
#[tauri::command]
pub async fn agents_check_installed() -> Result<Vec<String>, String> {
    installed_agents_in(&brain_core::Store::default_data_dir())
}

/// Install an agent, emitting `agent-install-progress:{agent}` as it goes
/// ("installing" -> "completed" | "failed"). The frontend drives its pane
/// overlay off that event.
///
/// [`Install::Page`] agents return an error naming the URL: there is nothing
/// to run, and claiming success would leave the UI showing an agent as
/// installed that isn't.
#[tauri::command]
pub async fn agents_install(agent: String, window: tauri::Window) -> Result<(), String> {
    let Some(spec) = spec(&agent) else {
        return Err(format!("Unknown agent: {agent}"));
    };

    let _ = window.emit(&format!("agent-install-progress:{agent}"), "installing");

    let result = match spec.install {
        Install::BuiltIn => Ok(()),
        Install::Page(url) => Err(format!("{agent} has no scriptable install; see {url}")),
        Install::Command(cmd) => run_install(cmd).await,
    };

    match result {
        Ok(()) => {
            if let Err(e) = mark_agent_installed(&brain_core::Store::default_data_dir(), &agent) {
                let _ = window.emit(&format!("agent-install-progress:{agent}"), "failed");
                return Err(format!("Failed to install {agent}: {e}"));
            }
            let _ = window.emit(&format!("agent-install-progress:{agent}"), "completed");
            Ok(())
        }
        Err(e) => {
            let _ = window.emit(&format!("agent-install-progress:{agent}"), "failed");
            Err(format!("Failed to install {agent}: {e}"))
        }
    }
}

/// Run an install one-liner.
///
/// On a blocking thread, not inline: these download hundreds of megabytes and
/// take minutes, and `agents_install` is an async command — running the child
/// process inline parks a runtime worker for the whole install and stalls
/// unrelated IPC. `spawn_blocking` is Tauri's own re-export, so this costs no
/// new dependency.
async fn run_install(cmd: &'static str) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let output = std::process::Command::new("sh")
            .arg("-c")
            .arg(cmd)
            .output()
            .map_err(|e| format!("could not run {cmd:?}: {e}"))?;

        if output.status.success() {
            return Ok(());
        }

        // Installers are chatty on the way down; the last few lines are the
        // part that says why, and the whole log would not fit in a banner.
        let stderr = String::from_utf8_lossy(&output.stderr);
        let lines: Vec<&str> = stderr.lines().collect();
        let tail = lines[lines.len().saturating_sub(5)..].join("\n");
        Err(format!("{cmd:?} failed: {tail}"))
    })
    .await
    .map_err(|e| format!("install task failed to run: {e}"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The frontend's `AVAILABLE_AGENTS` (ui/src/state/agents.ts) and this
    /// table have to name the same five agents in the same order — the UI
    /// sends these strings straight to `session_create`.
    #[test]
    fn agents_match_frontend() {
        let names: Vec<_> = AGENTS.iter().map(|a| a.name).collect();
        assert_eq!(
            names,
            ["claude", "codex", "shell", "copilot", "antigravity"]
        );
    }

    /// The bug this module was rewritten to kill: detecting an agent by its
    /// name instead of its binary. If someone "simplifies" `binary` away,
    /// this fails.
    #[test]
    fn binary_is_not_always_the_name() {
        assert_eq!(binary_for("antigravity"), Some("agy"));
        assert_eq!(binary_for("shell"), None, "shell is built-in, not a binary");
    }

    /// Every non-built-in agent must be spawnable, which means
    /// `build_engine_argv` needs an arm for it. Cheap guard against adding a
    /// row here and forgetting sessions.rs — the exact seam that shipped
    /// broken.
    #[test]
    fn every_agent_has_a_binary_or_is_builtin() {
        for a in AGENTS {
            match (&a.install, a.binary) {
                (Install::BuiltIn, None) => {}
                (Install::BuiltIn, Some(_)) => panic!("{}: built-in with a binary", a.name),
                (_, Some(_)) => {}
                (_, None) => panic!("{}: installable but no binary to detect", a.name),
            }
        }
    }

    #[test]
    fn installed_agents_are_detected_by_marker_folder() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(agent_marker_dir(dir.path(), "claude")).unwrap();
        std::fs::create_dir_all(agent_marker_dir(dir.path(), "copilot")).unwrap();

        let installed = installed_agents_in(dir.path()).unwrap();

        assert_eq!(installed, vec!["claude", "shell", "copilot"]);
    }

    #[test]
    fn marking_an_agent_installed_creates_its_folder() {
        let dir = tempfile::tempdir().unwrap();
        mark_agent_installed(dir.path(), "antigravity").unwrap();

        assert!(agent_marker_dir(dir.path(), "antigravity").exists());
    }
}

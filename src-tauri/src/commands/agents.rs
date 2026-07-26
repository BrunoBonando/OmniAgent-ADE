//! Agent management commands: checking which agents are installed and
//! installing new agents. Agents are executables that can be detected on PATH
//! and installed via platform-specific package managers.

use tauri::Emitter;

/// The five supported agents in this deployment.
const SUPPORTED_AGENTS: &[&str] = &["claude", "codex", "shell", "copilot", "antigravity"];

/// Checks which agents are currently installed by testing if their binaries
/// are available on the system PATH using the `which` crate.
///
/// Returns a list of installed agent names. Always returns `Ok` — failures to
/// detect individual agents are silent (the agent simply doesn't appear in the
/// list).
#[tauri::command]
pub async fn agents_check_installed() -> Result<Vec<String>, String> {
    let mut installed = Vec::new();

    for agent in SUPPORTED_AGENTS {
        if which::which(agent).is_ok() {
            installed.push(agent.to_string());
        }
    }

    Ok(installed)
}

/// Installs an agent by downloading/installing it via the appropriate method
/// for that agent. Emits `agent-install-progress:{agent}` events during the
/// installation process with status updates ("installing", "completed", or
/// "failed").
///
/// The installation method varies by agent:
/// - `claude`: via `pip install` (Claude Code CLI)
/// - `codex`: via `pip install` (Codex CLI)
/// - `shell`: via system package manager or direct installation
/// - `copilot`: via `pip install` (GitHub Copilot CLI)
/// - `antigravity`: via `pip install` (Antigravity agent)
///
/// If installation fails, emits a "failed" event before returning an error.
#[tauri::command]
pub async fn agents_install(agent: String, window: tauri::Window) -> Result<(), String> {
    // Validate the agent name
    if !SUPPORTED_AGENTS.contains(&agent.as_str()) {
        return Err(format!("Unknown agent: {agent}"));
    }

    // Emit "installing" status
    let _ = window.emit(&format!("agent-install-progress:{agent}"), "installing");

    // Execute the installation command based on the agent
    let result = match agent.as_str() {
        "claude" => {
            install_via_pip(&agent, "claude-code").await
        }
        "codex" => {
            install_via_pip(&agent, "codex").await
        }
        "shell" => {
            install_shell_agent().await
        }
        "copilot" => {
            install_via_pip(&agent, "github-copilot-cli").await
        }
        "antigravity" => {
            install_via_pip(&agent, "antigravity").await
        }
        _ => unreachable!(), // Protected by the check above
    };

    match result {
        Ok(_) => {
            // Emit "completed" status
            let _ = window.emit(&format!("agent-install-progress:{agent}"), "completed");
            Ok(())
        }
        Err(e) => {
            // Emit "failed" status before returning error
            let _ = window.emit(&format!("agent-install-progress:{agent}"), "failed");
            Err(format!("Failed to install {agent}: {e}"))
        }
    }
}

/// Helper: install an agent via `pip install`
async fn install_via_pip(_agent: &str, package: &str) -> Result<(), String> {
    let output = std::process::Command::new("pip")
        .args(&["install", package])
        .output()
        .map_err(|e| format!("Failed to run pip: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("pip install {package} failed: {stderr}"));
    }

    Ok(())
}

/// Helper: install the shell agent
/// The shell agent is typically a built-in feature of the terminal environment,
/// so this just ensures it's available and returns success if it is.
async fn install_shell_agent() -> Result<(), String> {
    // Check if shell is already available
    if which::which("sh").is_ok() || which::which("bash").is_ok() {
        return Ok(());
    }

    // If neither sh nor bash is available, this is a critical system issue
    Err("Neither sh nor bash found on system".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supported_agents_contains_expected_agents() {
        assert_eq!(SUPPORTED_AGENTS.len(), 5);
        assert!(SUPPORTED_AGENTS.contains(&"claude"));
        assert!(SUPPORTED_AGENTS.contains(&"codex"));
        assert!(SUPPORTED_AGENTS.contains(&"shell"));
        assert!(SUPPORTED_AGENTS.contains(&"copilot"));
        assert!(SUPPORTED_AGENTS.contains(&"antigravity"));
    }
}

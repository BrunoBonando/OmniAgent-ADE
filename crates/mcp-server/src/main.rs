//! `omniagent-mcp`: thin binary entry point. All behavior lives in the
//! `mcp_server` library (`protocol` for the JSON-RPC stdio loop, `tools`
//! for the frozen v1 tool contract) so it's unit- and contract-testable
//! without spawning a process for every case.
//!
//! Data dir resolution matches every other OmniAgent ADE binary:
//! `brain_core::Store::default_data_dir()` honors `OMNIAGENT_ADE_DATA_DIR`
//! and otherwise falls back to `~/Library/Application Support/OmniAgent-ADE`.
//! Phase 5 spawns this binary per-session with that env var already set to
//! the app's data dir (no CLI flags needed for v1).

use anyhow::{Context, Result};
use brain_core::Store;
use std::io::{self, BufReader};

fn main() -> Result<()> {
    let data_dir = Store::default_data_dir();
    let store = Store::open(&data_dir)
        .with_context(|| format!("failed to open brain store at {}", data_dir.display()))?;

    eprintln!(
        "omniagent-mcp: serving MCP over stdio (data_dir={})",
        data_dir.display()
    );

    let stdin = io::stdin();
    let stdout = io::stdout();
    mcp_server::protocol::serve(
        BufReader::new(stdin.lock()),
        stdout.lock(),
        &store,
        &data_dir,
    )
    .context("MCP stdio loop failed")
}

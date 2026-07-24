//! `omniagent-mcp` (PLAN.md Phase 3, Task 3.1): the frozen v1 MCP tool
//! contract — `search_brain`, `get_context`, `related`, `record_decision`,
//! `record_note`, `list_projects` — exposed over stdio to any MCP client
//! (Claude Code, Cursor, etc.), reading and writing through the shared
//! `brain_core::{Store, Memory}` retrieval crate.
//!
//! ## Why hand-rolled JSON-RPC instead of `rmcp`
//!
//! PLAN.md's Task 3.1 names `rmcp` (the official Rust MCP SDK) as the
//! default choice, with an explicit escape hatch to hand-roll the stdio
//! loop if SDK friction exceeds the session budget. `rmcp`'s server/macro
//! surface (`#[tool_router]`/`#[tool_handler]`, `transport-io`'s
//! `stdio()`) is async-first and built on Tokio, while every dependency
//! this server touches (`brain_core::Store` over `rusqlite`,
//! `brain_core::Memory` over `std::fs`) is synchronous. Pulling in Tokio +
//! `rmcp` + its macro/schema machinery just to wrap six small,
//! already-synchronous functions is real added weight (compile time,
//! transitive deps, a whole async runtime living inside a stdio pipe
//! filter) for no behavioral gain — the MCP stdio transport itself is
//! just newline-delimited JSON-RPC 2.0, and the protocol surface this
//! server needs (`initialize`, `notifications/initialized`, `tools/list`,
//! `tools/call`) is small and stable. Hand-rolling also gives exact control
//! over the response JSON shapes, which matters here because those shapes
//! are the frozen contract Phase 5 depends on. See `protocol` for the loop.
pub mod protocol;
pub mod tools;

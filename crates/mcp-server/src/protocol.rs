//! Hand-rolled MCP transport: newline-delimited JSON-RPC 2.0 over stdio
//! (see `lib.rs` module docs for why this is hand-rolled instead of
//! `rmcp`). Implements exactly the three methods a `tools`-only MCP
//! server needs — `initialize`, `notifications/initialized`, `tools/list`,
//! `tools/call` — plus `ping` for client liveness checks, and returns a
//! well-formed JSON-RPC error for anything else rather than hanging or
//! crashing the process (a client probing `resources/list` on a
//! tools-only server should get "method not found", not silence).
//!
//! `serve` is generic over `BufRead`/`Write` so it can be unit-tested
//! in-process against an in-memory buffer; `tests/contract_test.rs`
//! additionally exercises it black-box by spawning the real binary.

use crate::tools::{self, ToolContext, ToolError};
use brain_core::Store;
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::Path;

const PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "omniagent-mcp";

/// Reads one JSON-RPC message per line from `input` until EOF, dispatching
/// each to the MCP handshake/tool-call handlers below and writing exactly
/// one JSON-RPC response line to `output` per *request* (never for
/// notifications, which have no `id`). Returns `Ok(())` on clean EOF.
pub fn serve<R: BufRead, W: Write>(
    mut input: R,
    mut output: W,
    store: &Store,
    data_dir: &Path,
) -> io::Result<()> {
    let mut line = String::new();
    loop {
        line.clear();
        let bytes_read = input.read_line(&mut line)?;
        if bytes_read == 0 {
            return Ok(()); // EOF: client closed stdin.
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let message: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(e) => {
                send_error(
                    &mut output,
                    Value::Null,
                    -32700,
                    format!("parse error: {e}"),
                )?;
                continue;
            }
        };

        // Per JSON-RPC 2.0: a member named "id" present (even if null)
        // means this is a request expecting a response; its absence means
        // a notification, which must never get a reply.
        let id = message.get("id").cloned();
        let method = message.get("method").and_then(|v| v.as_str());
        let params = message.get("params").cloned().unwrap_or_else(|| json!({}));

        let Some(method) = method else {
            if let Some(id) = id {
                send_error(
                    &mut output,
                    id,
                    -32600,
                    "invalid request: missing method".into(),
                )?;
            }
            continue;
        };

        dispatch(&mut output, method, params, id, store, data_dir)?;
    }
}

fn dispatch<W: Write>(
    output: &mut W,
    method: &str,
    params: Value,
    id: Option<Value>,
    store: &Store,
    data_dir: &Path,
) -> io::Result<()> {
    match method {
        "initialize" => {
            let Some(id) = id else { return Ok(()) };
            let client_protocol_version = params
                .get("protocolVersion")
                .and_then(|v| v.as_str())
                .unwrap_or(PROTOCOL_VERSION);
            let result = json!({
                "protocolVersion": client_protocol_version,
                "capabilities": { "tools": {} },
                "serverInfo": { "name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION") },
            });
            send_result(output, id, result)
        }
        "notifications/initialized" | "initialized" => {
            // Notification: no response, regardless of whether the client
            // (incorrectly) sent an id.
            Ok(())
        }
        "ping" => match id {
            Some(id) => send_result(output, id, json!({})),
            None => Ok(()),
        },
        "tools/list" => {
            let Some(id) = id else { return Ok(()) };
            send_result(output, id, json!({ "tools": tools::tool_defs() }))
        }
        "tools/call" => {
            let Some(id) = id else { return Ok(()) }; // tools/call must be a request.
            handle_tools_call(output, id, params, store, data_dir)
        }
        other => {
            if let Some(id) = id {
                send_error(output, id, -32601, format!("method not found: {other}"))?;
            }
            Ok(())
        }
    }
}

fn handle_tools_call<W: Write>(
    output: &mut W,
    id: Value,
    params: Value,
    store: &Store,
    data_dir: &Path,
) -> io::Result<()> {
    let Some(name) = params.get("name").and_then(|v| v.as_str()) else {
        return send_error(
            output,
            id,
            -32602,
            "invalid params: missing tool name".into(),
        );
    };
    let arguments = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));

    let ctx = ToolContext { store, data_dir };
    match tools::call(&ctx, name, &arguments) {
        None => send_error(output, id, -32602, format!("unknown tool: {name}")),
        Some(Ok(value)) => send_result(output, id, call_tool_ok(&value)),
        Some(Err(ToolError::MissingField(field))) => send_error(
            output,
            id,
            -32602,
            format!("invalid params: missing required field '{field}'"),
        ),
        Some(Err(ToolError::Internal(msg))) => send_result(output, id, call_tool_err(&msg)),
    }
}

/// A successful `CallToolResult`: human-readable `content` (pretty JSON
/// text — always present, and the authoritative carrier of the frozen
/// tool-result shape for every tool) plus, when the value is a JSON
/// *object*, `structuredContent` carrying that same value again for
/// clients that prefer it.
///
/// `structuredContent` is only ever attached for object-shaped results
/// (`get_context`, `record_decision`/`record_note`). The MCP spec types
/// `structuredContent` as a JSON *object*, not an arbitrary value (see
/// rmcp's `CallToolResult::structured_content: Option<Value>`, documented
/// as "an optional JSON object"); `search_brain`/`related`/`list_projects`
/// are array-shaped per the frozen contract, so putting the array there
/// is spec-invalid. This was caught live: the real Claude Code MCP client
/// rejected `search_brain`'s array `structuredContent` with a schema
/// validation error before this fix — see the Task 3.1 report for detail.
fn call_tool_ok(value: &Value) -> Value {
    let mut result = json!({
        "content": [{
            "type": "text",
            "text": serde_json::to_string_pretty(value).unwrap_or_default(),
        }],
        "isError": false,
    });
    if value.is_object() {
        result["structuredContent"] = value.clone();
    }
    result
}

fn call_tool_err(message: &str) -> Value {
    json!({
        "content": [{ "type": "text", "text": message }],
        "isError": true,
    })
}

fn send_result<W: Write>(output: &mut W, id: Value, result: Value) -> io::Result<()> {
    write_message(
        output,
        &json!({ "jsonrpc": "2.0", "id": id, "result": result }),
    )
}

fn send_error<W: Write>(output: &mut W, id: Value, code: i64, message: String) -> io::Result<()> {
    write_message(
        output,
        &json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }),
    )
}

fn write_message<W: Write>(output: &mut W, value: &Value) -> io::Result<()> {
    let line = serde_json::to_string(value).expect("JSON-RPC response always serializes");
    output.write_all(line.as_bytes())?;
    output.write_all(b"\n")?;
    output.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufReader;
    use tempfile::tempdir;

    fn run(store: &Store, data_dir: &Path, requests: &[Value]) -> Vec<Value> {
        let mut input = String::new();
        for r in requests {
            input.push_str(&serde_json::to_string(r).unwrap());
            input.push('\n');
        }
        let mut output = Vec::new();
        serve(
            BufReader::new(input.as_bytes()),
            &mut output,
            store,
            data_dir,
        )
        .unwrap();
        String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    #[test]
    fn initialize_echoes_protocol_version_and_lists_tools_capability() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let responses = run(
            &store,
            dir.path(),
            &[json!({
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": { "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"} }
            })],
        );
        assert_eq!(responses.len(), 1);
        assert_eq!(responses[0]["result"]["protocolVersion"], "2024-11-05");
        assert_eq!(
            responses[0]["result"]["serverInfo"]["name"],
            "omniagent-mcp"
        );
        assert!(responses[0]["result"]["capabilities"]["tools"].is_object());
    }

    #[test]
    fn notification_gets_no_response() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let responses = run(
            &store,
            dir.path(),
            &[
                json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }),
                json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }),
            ],
        );
        // Only the tools/list request gets a response line.
        assert_eq!(responses.len(), 1);
        assert_eq!(responses[0]["id"], 1);
    }

    #[test]
    fn tools_list_returns_all_six_frozen_tools() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let responses = run(
            &store,
            dir.path(),
            &[json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" })],
        );
        let tools = responses[0]["result"]["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 6);
    }

    #[test]
    fn tools_call_unknown_tool_is_json_rpc_error() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let responses = run(
            &store,
            dir.path(),
            &[json!({
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": { "name": "nope", "arguments": {} }
            })],
        );
        assert_eq!(responses[0]["error"]["code"], -32602);
    }

    #[test]
    fn unknown_method_with_id_is_method_not_found() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let responses = run(
            &store,
            dir.path(),
            &[json!({ "jsonrpc": "2.0", "id": 1, "method": "resources/list" })],
        );
        assert_eq!(responses[0]["error"]["code"], -32601);
    }

    #[test]
    fn malformed_json_line_does_not_kill_the_loop() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let mut input = String::new();
        input.push_str("not json at all\n");
        input.push_str(
            &serde_json::to_string(&json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }))
                .unwrap(),
        );
        input.push('\n');
        let mut output = Vec::new();
        serve(
            BufReader::new(input.as_bytes()),
            &mut output,
            &store,
            dir.path(),
        )
        .unwrap();
        let lines: Vec<Value> = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0]["error"]["code"], -32700);
        assert!(lines[1]["result"]["tools"].is_array());
    }

    #[test]
    fn tools_call_search_brain_returns_result_in_content_text_not_structured_content() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&brain_core::Node {
                id: "p1:helpers.py#parse_config".into(),
                kind: brain_core::NodeKind::CodeEntity,
                project: "p1".into(),
                label: "parse_config".into(),
                path: Some("helpers.py".into()),
                summary: None,
                origin: brain_core::Origin::Extracted,
                updated: brain_core::now_ts(),
            })
            .unwrap();

        let responses = run(
            &store,
            dir.path(),
            &[json!({
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": { "name": "search_brain", "arguments": { "query": "parse_config" } }
            })],
        );
        let result = &responses[0]["result"];
        assert_eq!(result["isError"], false);
        // Array-shaped results must NOT carry structuredContent: the MCP
        // spec types that field as a JSON object, and the real Claude Code
        // client rejects an array there (caught via live verification —
        // see call_tool_ok's doc comment).
        assert!(result.get("structuredContent").is_none());
        let text = result["content"][0]["text"].as_str().unwrap();
        let parsed: Value = serde_json::from_str(text).unwrap();
        assert_eq!(parsed[0]["id"], "p1:helpers.py#parse_config");
    }

    #[test]
    fn tools_call_get_context_object_result_does_carry_structured_content() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let responses = run(
            &store,
            dir.path(),
            &[json!({
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": { "name": "get_context", "arguments": { "project": "does-not-exist" } }
            })],
        );
        let result = &responses[0]["result"];
        assert!(result.get("structuredContent").is_some());
        assert_eq!(result["structuredContent"]["summary"], "");
    }
}

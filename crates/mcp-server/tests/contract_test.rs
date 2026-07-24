//! Black-box contract tests (PLAN.md Task 3.1's exact ask): spawn the real
//! built `omniagent-mcp` binary and speak MCP 2.0 JSON-RPC over its actual
//! stdin/stdout — `initialize` -> `notifications/initialized` ->
//! `tools/list` -> `tools/call` — asserting on real process output against
//! a store seeded directly through `brain_core` before the process starts.
//! Complements the in-process unit tests in `src/protocol.rs` and
//! `src/tools.rs`, which cover edge cases faster without a subprocess per
//! case; this file is the proof the actual binary honors the wire
//! contract end to end.

use brain_core::{now_ts, Edge, EdgeKind, Node, NodeKind, Origin, Store};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use tempfile::TempDir;

struct McpProcess {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: i64,
}

impl McpProcess {
    fn spawn(data_dir: &std::path::Path) -> McpProcess {
        let mut child = Command::new(env!("CARGO_BIN_EXE_omniagent-mcp"))
            .env("OMNIAGENT_ADE_DATA_DIR", data_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn omniagent-mcp binary");
        let stdin = child.stdin.take().expect("child stdin");
        let stdout = BufReader::new(child.stdout.take().expect("child stdout"));
        McpProcess {
            child,
            stdin,
            stdout,
            next_id: 1,
        }
    }

    fn write(&mut self, value: &Value) {
        let line = serde_json::to_string(value).unwrap();
        self.stdin.write_all(line.as_bytes()).unwrap();
        self.stdin.write_all(b"\n").unwrap();
        self.stdin.flush().unwrap();
    }

    fn read_response(&mut self) -> Value {
        let mut line = String::new();
        self.stdout
            .read_line(&mut line)
            .expect("read a response line from the child process");
        assert!(
            !line.trim().is_empty(),
            "got an empty line back from omniagent-mcp (did it exit early?)"
        );
        serde_json::from_str(line.trim()).expect("response line is valid JSON")
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        self.write(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        self.read_response()
    }

    fn notify(&mut self, method: &str, params: Value) {
        self.write(&json!({ "jsonrpc": "2.0", "method": method, "params": params }));
    }

    /// Full MCP handshake: initialize request + notifications/initialized.
    fn initialize(&mut self) {
        let resp = self.request(
            "initialize",
            json!({
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": { "name": "contract-test", "version": "0.0.0" }
            }),
        );
        assert_eq!(resp["result"]["serverInfo"]["name"], "omniagent-mcp");
        assert_eq!(resp["result"]["protocolVersion"], "2024-11-05");
        self.notify("notifications/initialized", json!({}));
    }

    fn call_tool(&mut self, name: &str, arguments: Value) -> Value {
        self.request(
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        )
    }
}

impl Drop for McpProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Extracts a tool's frozen-contract result value from a `tools/call`
/// response the way a spec-correct client does: prefer `structuredContent`
/// when present (only ever set for object-shaped results — see
/// `protocol::call_tool_ok`), otherwise fall back to parsing
/// `content[0].text`, which every tool call always populates.
fn tool_result(resp: &Value) -> Value {
    let result = &resp["result"];
    if let Some(structured) = result.get("structuredContent") {
        if !structured.is_null() {
            return structured.clone();
        }
    }
    let text = result["content"][0]["text"]
        .as_str()
        .expect("content[0].text present");
    serde_json::from_str(text).expect("content text is valid JSON")
}

/// Seeds a small fixture graph directly through `brain_core::Store`,
/// mirroring how a real `brain ingest` run would have populated it:
/// one project, one file, one code entity, one file->entity edge.
fn seed(dir: &std::path::Path) {
    let store = Store::open(dir).unwrap();
    store
        .upsert_node(&Node {
            id: "sample-project".into(),
            kind: NodeKind::Project,
            project: "sample-project".into(),
            label: "sample-project".into(),
            path: Some("/tmp/sample-project".into()),
            summary: Some("A sample project.".into()),
            origin: Origin::Extracted,
            updated: now_ts(),
        })
        .unwrap();
    store
        .upsert_node(&Node {
            id: "sample-project:helpers.py#parse_config".into(),
            kind: NodeKind::CodeEntity,
            project: "sample-project".into(),
            label: "parse_config".into(),
            path: Some("helpers.py".into()),
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        })
        .unwrap();
    store
        .upsert_node(&Node {
            id: "sample-project:main.py".into(),
            kind: NodeKind::File,
            project: "sample-project".into(),
            label: "main.py".into(),
            path: Some("main.py".into()),
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        })
        .unwrap();
    store
        .upsert_edge(&Edge {
            src: "sample-project:main.py".into(),
            dst: "sample-project:helpers.py#parse_config".into(),
            kind: EdgeKind::References,
            weight: 1.0,
        })
        .unwrap();
}

#[test]
fn initialize_then_tools_list_returns_exact_frozen_tool_names() {
    let dir = TempDir::new().unwrap();
    seed(dir.path());
    let mut proc = McpProcess::spawn(dir.path());
    proc.initialize();

    let resp = proc.request("tools/list", json!({}));
    let tools = resp["result"]["tools"].as_array().expect("tools array");
    let mut names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    names.sort();
    assert_eq!(
        names,
        vec![
            "get_context",
            "list_projects",
            "record_decision",
            "record_note",
            "related",
            "search_brain",
        ]
    );
}

#[test]
fn search_brain_finds_seeded_node_with_frozen_shape() {
    let dir = TempDir::new().unwrap();
    seed(dir.path());
    let mut proc = McpProcess::spawn(dir.path());
    proc.initialize();

    let resp = proc.call_tool("search_brain", json!({ "query": "parse_config" }));
    // Array-shaped results must NOT carry structuredContent (MCP spec types
    // it as a JSON object; a real Claude Code client rejects it otherwise —
    // this broke live verification once, see protocol.rs's call_tool_ok).
    assert!(
        resp["result"].get("structuredContent").is_none(),
        "{resp:?}"
    );
    let value = tool_result(&resp);
    let hits = value.as_array().expect("array result");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0]["id"], "sample-project:helpers.py#parse_config");
    assert_eq!(hits[0]["kind"], "code_entity");
    assert_eq!(hits[0]["project"], "sample-project");
    assert_eq!(hits[0]["label"], "parse_config");
    assert_eq!(hits[0]["path"], "helpers.py");
    assert_eq!(resp["result"]["isError"], false);
}

#[test]
fn search_brain_respects_scope() {
    let dir = TempDir::new().unwrap();
    seed(dir.path());
    let mut proc = McpProcess::spawn(dir.path());
    proc.initialize();

    let resp = proc.call_tool(
        "search_brain",
        json!({ "query": "parse_config", "scope": "other-project" }),
    );
    let value = tool_result(&resp);
    let hits = value.as_array().unwrap();
    assert!(
        hits.is_empty(),
        "scope should have excluded the sample-project hit"
    );
}

#[test]
fn list_projects_returns_frozen_shape() {
    let dir = TempDir::new().unwrap();
    seed(dir.path());
    let mut proc = McpProcess::spawn(dir.path());
    proc.initialize();

    let resp = proc.call_tool("list_projects", json!({}));
    let value = tool_result(&resp);
    let projects = value.as_array().unwrap();
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0]["id"], "sample-project");
    assert_eq!(projects[0]["label"], "sample-project");
    assert_eq!(projects[0]["path"], "/tmp/sample-project");
}

#[test]
fn related_returns_typed_edge_and_node() {
    let dir = TempDir::new().unwrap();
    seed(dir.path());
    let mut proc = McpProcess::spawn(dir.path());
    proc.initialize();

    let resp = proc.call_tool("related", json!({ "node_id": "sample-project:main.py" }));
    let value = tool_result(&resp);
    let neighbors = value.as_array().unwrap();
    assert_eq!(neighbors.len(), 1);
    assert_eq!(neighbors[0]["edge_kind"], "references");
    assert_eq!(
        neighbors[0]["node"]["id"],
        "sample-project:helpers.py#parse_config"
    );
}

#[test]
fn record_decision_and_record_note_write_files_and_appear_in_get_context() {
    let dir = TempDir::new().unwrap();
    seed(dir.path());
    let mut proc = McpProcess::spawn(dir.path());
    proc.initialize();

    let decision_resp = proc.call_tool(
        "record_decision",
        json!({ "project": "sample-project", "text": "Use SQLite for local storage." }),
    );
    let decision_value = tool_result(&decision_resp);
    let decision_path = decision_value["path"]
        .as_str()
        .expect("path field")
        .to_string();
    assert!(std::path::Path::new(&decision_path).exists());
    let decision_contents = std::fs::read_to_string(&decision_path).unwrap();
    assert!(decision_contents.contains("Use SQLite for local storage."));
    assert!(decision_contents.contains("Decision:"));

    let note_resp = proc.call_tool(
        "record_note",
        json!({ "project": "sample-project", "text": "Remember to redact secrets." }),
    );
    let note_value = tool_result(&note_resp);
    let note_path = note_value["path"].as_str().unwrap().to_string();
    assert!(std::path::Path::new(&note_path).exists());
    let note_contents = std::fs::read_to_string(&note_path).unwrap();
    assert!(note_contents.contains("Note:"));
    assert!(!note_contents.contains("Decision:"));

    let ctx_resp = proc.call_tool("get_context", json!({ "project": "sample-project" }));
    let ctx = tool_result(&ctx_resp);
    assert_eq!(ctx["summary"], "A sample project.");

    let decisions = ctx["recent_decisions"].as_array().unwrap();
    assert_eq!(decisions.len(), 1, "{ctx:?}");
    assert!(decisions[0]["label"]
        .as_str()
        .unwrap()
        .starts_with("Decision:"));

    // memory_notes carries both the decision and the plain note.
    let notes = ctx["memory_notes"].as_array().unwrap();
    assert_eq!(notes.len(), 2, "{ctx:?}");

    assert!(ctx["related_projects"].as_array().unwrap().is_empty());
}

#[test]
fn get_context_on_unknown_project_returns_empty_briefing_not_an_error() {
    let dir = TempDir::new().unwrap();
    seed(dir.path());
    let mut proc = McpProcess::spawn(dir.path());
    proc.initialize();

    let resp = proc.call_tool("get_context", json!({ "project": "does-not-exist" }));
    assert_eq!(resp["result"]["isError"], false);
    let ctx = tool_result(&resp);
    assert_eq!(ctx["summary"], "");
    assert!(ctx["recent_decisions"].as_array().unwrap().is_empty());
    assert!(ctx["memory_notes"].as_array().unwrap().is_empty());
    assert!(ctx["related_projects"].as_array().unwrap().is_empty());
}

#[test]
fn tools_call_with_missing_required_field_returns_json_rpc_invalid_params_error() {
    let dir = TempDir::new().unwrap();
    seed(dir.path());
    let mut proc = McpProcess::spawn(dir.path());
    proc.initialize();

    let resp = proc.call_tool("search_brain", json!({}));
    assert_eq!(resp["error"]["code"], -32602, "{resp:?}");
    assert!(resp.get("result").is_none());
}

#[test]
fn tools_call_with_unknown_tool_name_returns_json_rpc_error() {
    let dir = TempDir::new().unwrap();
    seed(dir.path());
    let mut proc = McpProcess::spawn(dir.path());
    proc.initialize();

    let resp = proc.call_tool("delete_everything", json!({}));
    assert!(resp.get("error").is_some(), "{resp:?}");
    assert!(resp.get("result").is_none());
}

#[test]
fn unrecognized_method_gets_method_not_found_not_a_hang() {
    let dir = TempDir::new().unwrap();
    seed(dir.path());
    let mut proc = McpProcess::spawn(dir.path());
    proc.initialize();

    let resp = proc.request("resources/list", json!({}));
    assert_eq!(resp["error"]["code"], -32601, "{resp:?}");
}

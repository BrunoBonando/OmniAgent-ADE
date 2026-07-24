use brain_core::store::{now_ts, EdgeKind, NodeKind, Origin};
use brain_core::{Edge, Node, Store};
use tempfile::tempdir;

fn node(id: &str, kind: NodeKind, project: &str, label: &str) -> Node {
    Node {
        id: id.to_string(),
        kind,
        project: project.to_string(),
        label: label.to_string(),
        path: None,
        summary: None,
        origin: Origin::Extracted,
        updated: now_ts(),
    }
}

#[test]
fn open_creates_db_file() {
    let dir = tempdir().unwrap();
    let _store = Store::open(dir.path()).unwrap();
    assert!(dir.path().join("brain.db").exists());
}

#[test]
fn upsert_and_search_round_trip() {
    let store = Store::open_in_memory().unwrap();
    store
        .upsert_node(&node(
            "p1:helpers.py#parse_config",
            NodeKind::CodeEntity,
            "p1",
            "parse_config",
        ))
        .unwrap();

    let hits = store.search("parse", None, 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].label, "parse_config");
}

#[test]
fn neighbors_returns_typed_edges() {
    let store = Store::open_in_memory().unwrap();
    store
        .upsert_node(&node("p1:a.ts", NodeKind::File, "p1", "a.ts"))
        .unwrap();
    store
        .upsert_node(&node("p1:b.ts", NodeKind::File, "p1", "b.ts"))
        .unwrap();
    store
        .upsert_edge(&Edge {
            src: "p1:a.ts".into(),
            dst: "p1:b.ts".into(),
            kind: EdgeKind::Imports,
            weight: 1.0,
        })
        .unwrap();

    let neighbors = store.neighbors("p1:a.ts", 10).unwrap();
    assert_eq!(neighbors.len(), 1);
    assert_eq!(neighbors[0].0.kind, EdgeKind::Imports);
    assert_eq!(neighbors[0].1.id, "p1:b.ts");
}

#[test]
fn delete_project_extracted_keeps_user_authored() {
    let store = Store::open_in_memory().unwrap();
    let mut extracted = node("p1:a.ts", NodeKind::File, "p1", "a.ts");
    extracted.origin = Origin::Extracted;
    store.upsert_node(&extracted).unwrap();

    let mut decision = node("p1:decision-1", NodeKind::Decision, "p1", "Use SQLite");
    decision.origin = Origin::UserAuthored;
    store.upsert_node(&decision).unwrap();

    store.delete_project_extracted("p1").unwrap();

    assert!(store.get_node("p1:a.ts").unwrap().is_none());
    assert!(store.get_node("p1:decision-1").unwrap().is_some());
}

#[test]
fn nodes_and_edges_for_project_scope_correctly() {
    let store = Store::open_in_memory().unwrap();
    store
        .upsert_node(&node("p1:a.ts", NodeKind::File, "p1", "a.ts"))
        .unwrap();
    store
        .upsert_node(&node("p1:b.ts", NodeKind::File, "p1", "b.ts"))
        .unwrap();
    store
        .upsert_node(&node("p2:c.ts", NodeKind::File, "p2", "c.ts"))
        .unwrap();
    store
        .upsert_edge(&Edge {
            src: "p1:a.ts".into(),
            dst: "p1:b.ts".into(),
            kind: EdgeKind::Imports,
            weight: 1.0,
        })
        .unwrap();

    let p1_nodes = store.nodes_for_project("p1").unwrap();
    assert_eq!(p1_nodes.len(), 2);
    assert!(p1_nodes.iter().all(|n| n.project == "p1"));

    let p1_edges = store.edges_for_project("p1").unwrap();
    assert_eq!(p1_edges.len(), 1);

    let p2_edges = store.edges_for_project("p2").unwrap();
    assert!(p2_edges.is_empty());
}

#[test]
fn default_data_dir_honors_env_override_and_falls_back() {
    // Both branches live in one test to avoid a cross-test race on the
    // process-global env var (tests in this binary run concurrently).
    std::env::set_var("OMNIAGENT_ADE_DATA_DIR", "/tmp/ade-test-xyz-123");
    assert_eq!(
        brain_core::Store::default_data_dir(),
        std::path::PathBuf::from("/tmp/ade-test-xyz-123")
    );

    std::env::remove_var("OMNIAGENT_ADE_DATA_DIR");
    let fallback = brain_core::Store::default_data_dir();
    assert!(
        fallback.ends_with("Library/Application Support/OmniAgent-ADE"),
        "{fallback:?}"
    );
}

#[test]
fn fts_survives_reopen() {
    let dir = tempdir().unwrap();
    {
        let store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&node(
                "p1:helpers.py#parse_config",
                NodeKind::CodeEntity,
                "p1",
                "parse_config",
            ))
            .unwrap();
    }
    let store = Store::open(dir.path()).unwrap();
    let hits = store.search("parse", None, 10).unwrap();
    assert_eq!(hits.len(), 1);
}

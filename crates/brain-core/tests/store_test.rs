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

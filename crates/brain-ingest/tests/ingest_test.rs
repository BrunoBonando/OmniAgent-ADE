//! Task 2.1 integration tests: walk + tree-sitter extraction against the
//! golden `fixtures/sample-project` fixture. (Task 2.2 appends docs/git/
//! community assertions to this same file since they all exercise the same
//! `ingest_project` entry point on the same fixture.)

use brain_core::{EdgeKind, NodeKind, Origin, Store};
use std::path::PathBuf;

fn fixture_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap() // crates/
        .parent()
        .unwrap() // repo root
        .join("fixtures/sample-project")
}

#[test]
fn ingest_fixture_creates_file_and_entity_nodes() {
    let store = Store::open_in_memory().unwrap();
    let stats = brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();

    assert!(stats.files >= 6, "{stats:?}");
    assert!(stats.entities >= 4, "{stats:?}");

    let nodes = store.nodes_for_project("sample-project").unwrap();

    // "File nodes for source/docs only": README.md and docs/notes.md count
    // here too even though Task 2.2's docs.rs later reclassifies them from
    // File to the more specific Doc kind (same node, same path) — so we
    // count both kinds together to stay true regardless of whether docs.rs
    // has run yet.
    let file_like = nodes
        .iter()
        .filter(|n| matches!(n.kind, NodeKind::File | NodeKind::Doc))
        .count();
    assert!(
        file_like >= 6,
        "expected >=6 file-like nodes, got {file_like}: {nodes:?}"
    );

    for expected in ["login", "hashPassword", "fetch_data", "parse_config"] {
        assert!(
            nodes
                .iter()
                .any(|n| n.kind == NodeKind::CodeEntity && n.label == expected),
            "missing entity {expected} in {nodes:?}"
        );
    }

    assert!(
        nodes.iter().all(|n| n.origin == Origin::Extracted),
        "ingest should only ever write Extracted-origin nodes"
    );
}

#[test]
fn ingest_fixture_creates_import_edge_auth_to_util() {
    let store = Store::open_in_memory().unwrap();
    brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();

    let neighbors = store.neighbors("sample-project:src/auth.ts", 20).unwrap();
    let has_import = neighbors.iter().any(|(edge, node)| {
        edge.kind == EdgeKind::Imports && node.id == "sample-project:src/util.ts"
    });
    assert!(has_import, "{neighbors:?}");
}

#[test]
fn ingest_fixture_creates_python_import_edge_main_to_helpers() {
    let store = Store::open_in_memory().unwrap();
    brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();

    let neighbors = store.neighbors("sample-project:main.py", 20).unwrap();
    let has_import = neighbors.iter().any(|(edge, node)| {
        edge.kind == EdgeKind::Imports && node.id == "sample-project:helpers.py"
    });
    assert!(has_import, "{neighbors:?}");
}

#[test]
fn ingest_fixture_contains_edges_link_files_to_their_entities() {
    let store = Store::open_in_memory().unwrap();
    brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();

    let neighbors = store.neighbors("sample-project:helpers.py", 20).unwrap();
    let contains_parse_config = neighbors.iter().any(|(edge, node)| {
        edge.kind == EdgeKind::Contains && node.id == "sample-project:helpers.py#parse_config"
    });
    assert!(contains_parse_config, "{neighbors:?}");
}

#[test]
fn reingesting_is_idempotent() {
    let store = Store::open_in_memory().unwrap();
    let root = fixture_root();

    let first = brain_ingest::ingest_project(&store, &root, "sample-project").unwrap();
    let nodes_after_first = store.nodes_for_project("sample-project").unwrap().len();

    let second = brain_ingest::ingest_project(&store, &root, "sample-project").unwrap();
    let nodes_after_second = store.nodes_for_project("sample-project").unwrap().len();

    assert_eq!(first, second);
    assert_eq!(nodes_after_first, nodes_after_second);
}

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
fn ingest_fixture_links_readme_to_notes_doc() {
    let store = Store::open_in_memory().unwrap();
    brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();

    let readme = store.get_node("sample-project:README.md").unwrap().unwrap();
    assert_eq!(readme.kind, NodeKind::Doc, "{readme:?}");

    let neighbors = store.neighbors("sample-project:README.md", 20).unwrap();
    assert!(
        neighbors
            .iter()
            .any(|(e, n)| e.kind == EdgeKind::LinksTo && n.id == "sample-project:docs/notes.md"),
        "{neighbors:?}"
    );
}

#[test]
fn ingest_fixture_mines_git_cochange_between_auth_and_util() {
    // Requires the fixture's own git history (fixtures/sample-project/.git),
    // set up once locally per PLAN.md Task 2.2 (co-commits auth.ts + util.ts).
    // gitmine::mine skips silently on a non-git root, so if that history is
    // ever missing this assertion — not a panic — is the signal.
    let store = Store::open_in_memory().unwrap();
    brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();

    let neighbors = store.neighbors("sample-project:src/auth.ts", 20).unwrap();
    let has_reference = neighbors
        .iter()
        .any(|(e, n)| e.kind == EdgeKind::References && n.id == "sample-project:src/util.ts");
    assert!(
        has_reference,
        "expected a References co-change edge between auth.ts and util.ts; \
         is fixtures/sample-project/.git present with the seed commits? {neighbors:?}"
    );
}

#[test]
fn ingest_fixture_groups_auth_and_util_into_the_same_community() {
    let store = Store::open_in_memory().unwrap();
    let stats = brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();
    assert!(stats.communities >= 1, "{stats:?}");

    let auth_communities: Vec<String> = store
        .neighbors("sample-project:src/auth.ts", 20)
        .unwrap()
        .into_iter()
        .filter(|(e, n)| e.kind == EdgeKind::MemberOf && n.kind == NodeKind::Community)
        .map(|(_, n)| n.id)
        .collect();
    let util_communities: Vec<String> = store
        .neighbors("sample-project:src/util.ts", 20)
        .unwrap()
        .into_iter()
        .filter(|(e, n)| e.kind == EdgeKind::MemberOf && n.kind == NodeKind::Community)
        .map(|(_, n)| n.id)
        .collect();

    assert!(
        auth_communities
            .iter()
            .any(|c| util_communities.contains(c)),
        "auth={auth_communities:?} util={util_communities:?}"
    );
}

#[test]
fn reingesting_twice_produces_identical_community_assignment() {
    let store = Store::open_in_memory().unwrap();
    let root = fixture_root();

    brain_ingest::ingest_project(&store, &root, "sample-project").unwrap();
    let mut first: Vec<(String, String)> = store
        .nodes_for_project("sample-project")
        .unwrap()
        .into_iter()
        .filter(|n| n.kind == NodeKind::File || n.kind == NodeKind::CodeEntity)
        .flat_map(|n| {
            store
                .neighbors(&n.id, 20)
                .unwrap()
                .into_iter()
                .filter(|(e, target)| {
                    e.kind == EdgeKind::MemberOf && target.kind == NodeKind::Community
                })
                .map(move |(_, target)| (n.id.clone(), target.id))
        })
        .collect();
    first.sort();

    brain_ingest::ingest_project(&store, &root, "sample-project").unwrap();
    let mut second: Vec<(String, String)> = store
        .nodes_for_project("sample-project")
        .unwrap()
        .into_iter()
        .filter(|n| n.kind == NodeKind::File || n.kind == NodeKind::CodeEntity)
        .flat_map(|n| {
            store
                .neighbors(&n.id, 20)
                .unwrap()
                .into_iter()
                .filter(|(e, target)| {
                    e.kind == EdgeKind::MemberOf && target.kind == NodeKind::Community
                })
                .map(move |(_, target)| (n.id.clone(), target.id))
        })
        .collect();
    second.sort();

    assert_eq!(first, second);
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

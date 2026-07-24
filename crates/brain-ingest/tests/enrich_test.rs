//! Task 4.1 integration tests: `ingest_project` enqueues enrichment jobs,
//! and `drain_queue` (with a `Fake` engine — no real `claude` calls here)
//! processes them against the golden `fixtures/sample-project` fixture.

use brain_core::{NodeKind, Origin, Store};
use brain_ingest::enrich::{drain_queue, FakeEngine};
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
fn ingesting_the_fixture_enqueues_a_project_summary_job() {
    let store = Store::open_in_memory().unwrap();
    brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();

    let pending = store.pending_jobs(50).unwrap();
    assert!(
        pending
            .iter()
            .any(|j| j.kind == "project_summary" && j.payload.contains("sample-project")),
        "{pending:?}"
    );
}

#[test]
fn ingesting_the_fixture_enqueues_community_summary_jobs() {
    let store = Store::open_in_memory().unwrap();
    let stats = brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();
    assert!(stats.communities >= 1, "{stats:?}");

    let pending = store.pending_jobs(50).unwrap();
    let community_jobs = pending
        .iter()
        .filter(|j| j.kind == "community_summary")
        .count();
    assert!(community_jobs >= 1, "{pending:?}");
}

#[test]
fn draining_with_fake_engine_writes_project_summary_with_machine_origin() {
    let store = Store::open_in_memory().unwrap();
    brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();

    let engine = FakeEngine::always_ok("A sample project used to test ingestion.");
    let done = drain_queue(&store, &engine).unwrap();
    assert!(done >= 1);

    let project_node = store.get_node("sample-project").unwrap().unwrap();
    assert_eq!(
        project_node.summary.as_deref(),
        Some("A sample project used to test ingestion.")
    );
    assert_eq!(project_node.origin, Origin::MachineSummary);
}

#[test]
fn draining_with_fake_engine_also_summarizes_communities() {
    let store = Store::open_in_memory().unwrap();
    brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();

    let engine = FakeEngine::always_ok("Auth-related files working together.");
    drain_queue(&store, &engine).unwrap();

    let community_nodes: Vec<_> = store
        .nodes_for_project("sample-project")
        .unwrap()
        .into_iter()
        .filter(|n| n.kind == NodeKind::Community)
        .collect();
    assert!(!community_nodes.is_empty());
    assert!(
        community_nodes
            .iter()
            .all(|n| n.origin == Origin::MachineSummary && n.summary.is_some()),
        "{community_nodes:?}"
    );
}

#[test]
fn missing_engine_leaves_ingested_jobs_pending_and_never_errors() {
    let store = Store::open_in_memory().unwrap();
    brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();

    let pending_before = store.pending_jobs(50).unwrap().len();
    assert!(pending_before >= 1);

    let engine = FakeEngine::always_unavailable();
    let done = drain_queue(&store, &engine).unwrap();

    assert_eq!(done, 0);
    assert_eq!(store.pending_jobs(50).unwrap().len(), pending_before);

    let project_node = store.get_node("sample-project").unwrap().unwrap();
    assert_eq!(project_node.origin, Origin::Extracted);
    assert!(project_node.summary.is_none());
}

#[test]
fn reingesting_between_drains_does_not_duplicate_pending_jobs() {
    let store = Store::open_in_memory().unwrap();
    let root = fixture_root();

    brain_ingest::ingest_project(&store, &root, "sample-project").unwrap();
    let after_first = store.pending_jobs(50).unwrap().len();

    brain_ingest::ingest_project(&store, &root, "sample-project").unwrap();
    let after_second = store.pending_jobs(50).unwrap().len();

    assert_eq!(
        after_first, after_second,
        "re-ingesting before a drain should dedupe, not pile up duplicate jobs"
    );
}

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
fn search_with_hyphens_and_operator_characters_does_not_error() {
    // Regression: FTS5's query grammar treats bare -, :, (, " as operators
    // (NOT / column-filter / grouping) independent of the content tokenizer,
    // so an unsanitized query like "co-change" used to crash with a raw SQL
    // parse error ("no such column: change") instead of just finding
    // nothing or matching sensibly.
    let store = Store::open_in_memory().unwrap();
    store
        .upsert_node(&node(
            "p1:a.ts",
            NodeKind::File,
            "p1",
            "co-change candidate",
        ))
        .unwrap();

    let no_match = store
        .search("nothing-will-ever-match-this-xyz", None, 10)
        .unwrap();
    assert!(no_match.is_empty());

    let punctuation_only = store.search("---:::(((", None, 10).unwrap();
    assert!(punctuation_only.is_empty());

    let multi_word = store.search("co change", None, 10).unwrap();
    assert_eq!(multi_word.len(), 1);
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
fn all_nodes_and_all_edges_span_every_project() {
    let store = Store::open_in_memory().unwrap();
    store
        .upsert_node(&node("p1:a.ts", NodeKind::File, "p1", "a.ts"))
        .unwrap();
    store
        .upsert_node(&node("p2:c.ts", NodeKind::File, "p2", "c.ts"))
        .unwrap();
    store
        .upsert_edge(&Edge {
            src: "p1:a.ts".into(),
            dst: "p2:c.ts".into(),
            kind: EdgeKind::References,
            weight: 1.0,
        })
        .unwrap();

    let all_nodes = store.all_nodes().unwrap();
    assert_eq!(all_nodes.len(), 2);
    assert!(all_nodes.iter().any(|n| n.project == "p1"));
    assert!(all_nodes.iter().any(|n| n.project == "p2"));

    // Unlike edges_for_project (which requires both endpoints in the same
    // project), all_edges returns every edge regardless of project scope —
    // this cross-project edge would be invisible to edges_for_project.
    let all_edges = store.all_edges().unwrap();
    assert_eq!(all_edges.len(), 1);
    assert_eq!(all_edges[0].src, "p1:a.ts");
    assert_eq!(all_edges[0].dst, "p2:c.ts");
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
fn enqueue_job_round_trips_through_pending_jobs() {
    let store = Store::open_in_memory().unwrap();
    let id = store
        .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
        .unwrap();

    let pending = store.pending_jobs(10).unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, id);
    assert_eq!(pending[0].kind, "project_summary");
    assert_eq!(pending[0].payload, r#"{"node_id":"p1"}"#);
    assert_eq!(pending[0].status, "pending");
}

#[test]
fn enqueue_job_dedupes_against_an_existing_pending_job() {
    let store = Store::open_in_memory().unwrap();
    let first = store
        .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
        .unwrap();
    let second = store
        .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
        .unwrap();

    assert_eq!(
        first, second,
        "should return the existing pending job, not a duplicate"
    );
    assert_eq!(store.pending_jobs(10).unwrap().len(), 1);
}

#[test]
fn enqueue_job_allows_a_new_job_once_the_prior_one_is_no_longer_pending() {
    let store = Store::open_in_memory().unwrap();
    let first = store
        .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
        .unwrap();
    store
        .set_job_status(first, "done", r#"{"node_id":"p1"}"#)
        .unwrap();

    let second = store
        .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
        .unwrap();
    assert_ne!(first, second);
    assert_eq!(store.pending_jobs(10).unwrap().len(), 1);
    assert_eq!(store.jobs_with_status("done", 10).unwrap().len(), 1);
}

#[test]
fn set_job_status_updates_status_and_payload() {
    let store = Store::open_in_memory().unwrap();
    let id = store
        .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
        .unwrap();

    store
        .set_job_status(id, "failed", r#"{"node_id":"p1","error":"boom"}"#)
        .unwrap();

    assert!(store.pending_jobs(10).unwrap().is_empty());
    let failed = store.jobs_with_status("failed", 10).unwrap();
    assert_eq!(failed.len(), 1);
    assert_eq!(failed[0].payload, r#"{"node_id":"p1","error":"boom"}"#);
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

#[test]
fn settings_round_trip() {
    let store = Store::open_in_memory().unwrap();
    assert_eq!(store.get_setting("default_engine:demo").unwrap(), None);

    store.set_setting("default_engine:demo", "codex").unwrap();
    assert_eq!(
        store.get_setting("default_engine:demo").unwrap(),
        Some("codex".to_string())
    );

    // Upsert overwrites rather than duplicating/erroring.
    store.set_setting("default_engine:demo", "shell").unwrap();
    assert_eq!(
        store.get_setting("default_engine:demo").unwrap(),
        Some("shell".to_string())
    );
}

#[test]
fn pending_notes_round_trip_mark_list_approve_discard() {
    let store = Store::open_in_memory().unwrap();
    store
        .upsert_node(&node(
            "p1:memory:note-1.md",
            NodeKind::Memory,
            "p1",
            "Session: add auth",
        ))
        .unwrap();

    assert!(!store.is_pending("p1:memory:note-1.md").unwrap());
    store.mark_pending("p1:memory:note-1.md", "p1").unwrap();
    assert!(store.is_pending("p1:memory:note-1.md").unwrap());

    let pending = store.pending_notes(Some("p1")).unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].node_id, "p1:memory:note-1.md");
    assert_eq!(pending[0].title, "Session: add auth");

    // Scoped to a different project -> empty.
    assert!(store.pending_notes(Some("p2")).unwrap().is_empty());
    // Unscoped -> still finds it.
    assert_eq!(store.pending_notes(None).unwrap().len(), 1);

    let approved = store.approve_pending("p1:memory:note-1.md").unwrap();
    assert!(approved);
    assert!(!store.is_pending("p1:memory:note-1.md").unwrap());
    assert!(store.pending_notes(Some("p1")).unwrap().is_empty());
    // Node itself survives approval untouched.
    assert!(store.get_node("p1:memory:note-1.md").unwrap().is_some());
}

#[test]
fn approve_pending_on_a_non_pending_id_returns_false_not_an_error() {
    let store = Store::open_in_memory().unwrap();
    assert!(!store.approve_pending("does-not-exist").unwrap());
}

#[test]
fn discard_pending_deletes_node_edges_and_the_pending_row() {
    let store = Store::open_in_memory().unwrap();
    store
        .upsert_node(&node(
            "p1:memory:note-1.md",
            NodeKind::Memory,
            "p1",
            "Session: add auth",
        ))
        .unwrap();
    store
        .upsert_node(&node("p1:a.ts", NodeKind::File, "p1", "a.ts"))
        .unwrap();
    store
        .upsert_edge(&Edge {
            src: "p1:memory:note-1.md".into(),
            dst: "p1:a.ts".into(),
            kind: EdgeKind::Touched,
            weight: 1.0,
        })
        .unwrap();
    store.mark_pending("p1:memory:note-1.md", "p1").unwrap();

    let deleted = store.discard_pending("p1:memory:note-1.md").unwrap();
    assert!(deleted.is_some());
    assert_eq!(deleted.unwrap().id, "p1:memory:note-1.md");

    assert!(store.get_node("p1:memory:note-1.md").unwrap().is_none());
    assert!(store.pending_notes(Some("p1")).unwrap().is_empty());
    // The Touched edge is gone too (its src no longer exists).
    assert!(store.neighbors("p1:a.ts", 10).unwrap().is_empty());
}

#[test]
fn discard_pending_on_a_non_pending_id_returns_none_and_deletes_nothing() {
    let store = Store::open_in_memory().unwrap();
    store
        .upsert_node(&node("p1:a.ts", NodeKind::File, "p1", "a.ts"))
        .unwrap();

    let deleted = store.discard_pending("p1:a.ts").unwrap();
    assert!(deleted.is_none());
    assert!(
        store.get_node("p1:a.ts").unwrap().is_some(),
        "must not delete a non-pending node"
    );
}

#[test]
fn search_excludes_pending_notes() {
    let store = Store::open_in_memory().unwrap();
    store
        .upsert_node(&node(
            "p1:memory:note-1.md",
            NodeKind::Memory,
            "p1",
            "unique-search-term",
        ))
        .unwrap();
    store.mark_pending("p1:memory:note-1.md", "p1").unwrap();

    assert!(store
        .search("unique-search-term", None, 10)
        .unwrap()
        .is_empty());

    store.approve_pending("p1:memory:note-1.md").unwrap();
    assert_eq!(
        store.search("unique-search-term", None, 10).unwrap().len(),
        1
    );
}

#[test]
fn pending_job_count_reflects_only_pending_status() {
    let store = Store::open_in_memory().unwrap();
    assert_eq!(store.pending_job_count().unwrap(), 0);

    let a = store
        .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
        .unwrap();
    store
        .enqueue_job("project_summary", r#"{"node_id":"p2"}"#)
        .unwrap();
    assert_eq!(store.pending_job_count().unwrap(), 2);

    store
        .set_job_status(a, "done", r#"{"node_id":"p1"}"#)
        .unwrap();
    assert_eq!(store.pending_job_count().unwrap(), 1);
}

#[test]
fn all_settings_lists_every_row() {
    let store = Store::open_in_memory().unwrap();
    assert!(store.all_settings().unwrap().is_empty());

    store.set_setting("project_roots", r#"["/tmp/x"]"#).unwrap();
    store.set_setting("review_memory", "true").unwrap();

    let mut rows = store.all_settings().unwrap();
    rows.sort();
    assert_eq!(
        rows,
        vec![
            ("project_roots".to_string(), r#"["/tmp/x"]"#.to_string()),
            ("review_memory".to_string(), "true".to_string()),
        ]
    );
}

#[test]
fn with_transaction_commits_all_writes_together() {
    let store = Store::open_in_memory().unwrap();
    let result: Result<(), rusqlite::Error> = store.with_transaction(|s| {
        s.upsert_node(&node("p1:a.ts", NodeKind::File, "p1", "a.ts"))?;
        s.upsert_node(&node("p1:b.ts", NodeKind::File, "p1", "b.ts"))?;
        s.upsert_edge(&Edge {
            src: "p1:a.ts".into(),
            dst: "p1:b.ts".into(),
            kind: EdgeKind::Imports,
            weight: 1.0,
        })?;
        Ok(())
    });
    assert!(result.is_ok());

    assert_eq!(store.nodes_for_project("p1").unwrap().len(), 2);
    assert_eq!(store.neighbors("p1:a.ts", 10).unwrap().len(), 1);
}

#[test]
fn with_transaction_rolls_back_every_write_on_error() {
    let store = Store::open_in_memory().unwrap();
    // Pre-existing state, untouched by the failed transaction below.
    store
        .upsert_node(&node(
            "p1:pre-existing.ts",
            NodeKind::File,
            "p1",
            "pre-existing.ts",
        ))
        .unwrap();

    let result: Result<(), Box<dyn std::error::Error>> = store.with_transaction(|s| {
        s.upsert_node(&node("p1:a.ts", NodeKind::File, "p1", "a.ts"))?;
        s.upsert_node(&node("p1:b.ts", NodeKind::File, "p1", "b.ts"))?;
        Err("simulated failure partway through a batch".into())
    });
    assert!(result.is_err());

    // Neither write from the failed closure landed...
    assert!(store.get_node("p1:a.ts").unwrap().is_none());
    assert!(store.get_node("p1:b.ts").unwrap().is_none());
    // ...and the pre-existing row is untouched (rollback didn't nuke the DB).
    assert!(store.get_node("p1:pre-existing.ts").unwrap().is_some());
}

#[test]
fn with_transaction_batches_many_writes_and_they_all_land() {
    let store = Store::open_in_memory().unwrap();
    store
        .with_transaction::<_, _, rusqlite::Error>(|s| {
            for i in 0..500 {
                s.upsert_node(&node(
                    &format!("p1:f{i}.ts"),
                    NodeKind::File,
                    "p1",
                    &format!("f{i}.ts"),
                ))?;
            }
            Ok(())
        })
        .unwrap();

    assert_eq!(store.nodes_for_project("p1").unwrap().len(), 500);
}

#[test]
fn settings_survive_reopen() {
    let dir = tempdir().unwrap();
    {
        let store = Store::open(dir.path()).unwrap();
        store.set_setting("layout", r#"{"tabs":[]}"#).unwrap();
    }
    let store = Store::open(dir.path()).unwrap();
    assert_eq!(
        store.get_setting("layout").unwrap(),
        Some(r#"{"tabs":[]}"#.to_string())
    );
}

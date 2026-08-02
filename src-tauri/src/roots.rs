//! Task 8.1 — Onboarding + degradation: everything backing `FirstRun.tsx`
//! plus the sidebar/settings degradation surfaces.
//!
//! ## Onboarding
//! "No projects roots configured yet" is read straight off the `settings`
//! table's `PROJECT_ROOTS_KEY` (PLAN.md's own suggested convention) — a
//! JSON array of absolute paths the user has pointed the app at via the
//! native folder picker (`@tauri-apps/plugin-dialog`, wired in `lib.rs`).
//! [`roots_start_ingest`] persists the chosen root and kicks off ingestion
//! on a background thread — the exact same `brain_ingest::discover_projects`
//! + `ingest_project` calls the `brain` CLI uses (never a second
//! implementation, never shelling out to the CLI binary itself), so the app
//! never requires the user to run anything outside it. [`ingestion_status`]
//! is polled by the frontend (~2s, PLAN.md's own cadence) while it runs;
//! `IngestionState` is a plain `Arc<Mutex<..>>` (not routed through
//! `BrainState`'s `Store` mutex) so a slow ingest never blocks unrelated
//! Tauri commands (session I/O, map queries) that also lock `BrainState`.
//!
//! ## Degradation
//! - **Enrichment backlog**: [`Store::pending_job_count`] straight through —
//!   the map pane's "enrichment queued (N)" badge.
//! - **Staleness**: [`roots_staleness`] compares each project's
//!   `last_ingested:<project>` setting (written by every successful
//!   ingest) against a threshold. A project with no such setting at all
//!   (e.g. ingested earlier by the `brain` CLI, before this task existed)
//!   is reported *not* stale rather than flagged on first launch — the
//!   signal is "hasn't been refreshed in a while", not "we've never
//!   personally watched it," which would false-positive on every
//!   pre-Phase-8 project the instant this ships.
//! - **Per-project pause**: `ingest_paused:<project>` in `settings`, checked
//!   before touching a project — paused projects are skipped on both
//!   first-run ingestion and "Rebuild brain".
//! - **Rebuild brain**: [`roots_rebuild`] deletes `brain.db` (+ WAL/SHM/
//!   journal siblings) and re-ingests every persisted root from scratch.
//!   Markdown memory (`brain/<project>/*.md`) lives entirely outside
//!   `brain.db` and this function never touches that directory — DESIGN.md
//!   5's line: the DB is derived/rebuildable, memory is not. Settings
//!   (roots, pause flags, review mode, tab layout, default engines) are
//!   captured before the delete and replayed into the fresh database so
//!   "rebuild the derived graph" doesn't also mean "forget every
//!   preference."
//!
//! ## Task 6a-2 — this module is now a thin Tauri wrapper
//!
//! Every actual behavior in this file — the `IngestionState` state machine,
//! `add_root`/`get_roots`, pause/staleness bookkeeping, `add_project`/
//! `rename_project`'s bodies, and "Rebuild brain" — has moved to
//! [`brain_ingest::roots`], a Tauri-independent module `omniagent-pty-daemon`
//! now also calls into (so onboarding/project-management operations can be
//! routed through the daemon exactly like Task 6a routed `list_projects`/
//! `get_context`). This file keeps every `#[tauri::command]`'s exact
//! signature and behavior — it only locks `BrainState`'s `Store` and
//! delegates. The `use brain_ingest::roots::{...}` import below re-exposes
//! the moved private helpers under their old names so this file's original
//! `#[cfg(test)]` module (below) keeps compiling and passing completely
//! unchanged — it is the non-regression guard for this refactor.

use anyhow::Result;
// Only the names this file's own `#[tauri::command]` bodies actually call
// are imported at module scope — the rest of `brain_ingest::roots`'s surface
// (the pure helpers this file used to define itself) is imported directly
// inside `mod tests` below, purely to keep that test module's original
// source compiling unchanged; importing them here too would just be an
// unused-import warning outside `cfg(test)` builds.
pub use brain_ingest::roots::IngestionState;
use brain_ingest::roots::{
    biggest_project, get_roots, staleness, IngestionStatus, ProjectStaleness, ProjectSummary,
};
use tauri::State;

use crate::commands::BrainState;

/// The pure body behind [`add_project`] — takes plain `&BrainState`/
/// `&IngestionState` rather than Tauri's `State<'_, T>` so it's directly
/// unit-testable (this module's established split, e.g. [`rebuild_store`]
/// behind [`roots_rebuild`]). Delegates to `brain_ingest::roots::add_project`
/// (Task 6a-2) — the store lock is taken and dropped here, at the Tauri
/// boundary, exactly as before.
fn add_project_impl(
    brain: &BrainState,
    ingestion: &IngestionState,
    path: &str,
    name: Option<&str>,
) -> Result<ProjectSummary> {
    let store = brain
        .store
        .lock()
        .map_err(|_| anyhow::anyhow!("brain store mutex poisoned"))?;
    brain_ingest::roots::add_project(&store, &brain.data_dir, ingestion, path, name)
}

/// Adds exactly one project at `path` (Bruno's "open one terminal, and
/// start from there" — the sidebar's persistent "+"). `name` is the
/// optional user-edited display name/id (defaults to `path`'s folder
/// basename). Returns as soon as the `Project` node exists and is
/// queryable via `list_projects` — never waits for ingestion, which
/// continues on a background thread.
#[tauri::command]
pub fn add_project(
    path: String,
    name: Option<String>,
    brain: State<'_, BrainState>,
    ingestion: State<'_, IngestionState>,
) -> Result<ProjectSummary, String> {
    add_project_impl(brain.inner(), ingestion.inner(), &path, name.as_deref())
        .map_err(|e| e.to_string())
}

/// The pure body behind [`rename_project`] — same `&BrainState`-not-`State`
/// split every other command in this module uses for direct unit-testing.
/// Delegates to `brain_ingest::roots::rename_project` (Task 6a-2).
fn rename_project_impl(brain: &BrainState, id: &str, new_label: &str) -> Result<()> {
    let store = brain
        .store
        .lock()
        .map_err(|_| anyhow::anyhow!("brain store mutex poisoned"))?;
    brain_ingest::roots::rename_project(&store, id, new_label)
}

/// Renames a project's *display* label only — closes the root cause of a
/// project's sidebar/pane-header label defaulting to its folder basename
/// forever (e.g. this very repo's own project entry always showing
/// "OmniAgent-ADE"). `id`/`project` — the key every session/setting/cwd
/// lookup elsewhere actually uses — never changes; only what
/// `mcp_server::tools::list_projects` (and therefore `brain_query` /
/// the sidebar / every pane header) *displays* for it does, immediately,
/// everywhere that reads it. See [`mcp_server::tools::project_label_key`]'s
/// doc for why this writes to the settings table rather than the node's own
/// `label` column.
#[tauri::command]
pub fn rename_project(
    id: String,
    new_label: String,
    brain: State<'_, BrainState>,
) -> Result<(), String> {
    rename_project_impl(brain.inner(), &id, &new_label).map_err(|e| e.to_string())
}

/// Persists `path` as a known project root and kicks off ingestion for
/// every project discovered under it, in the background — the first-run
/// folder picker's whole job. Rejects a second concurrent run rather than
/// silently interleaving two ingestion passes against the same store.
#[tauri::command]
pub fn roots_start_ingest(
    path: String,
    brain: State<'_, BrainState>,
    ingestion: State<'_, IngestionState>,
) -> Result<(), String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    brain_ingest::roots::start_ingest(brain.data_dir.clone(), &store, ingestion.inner(), &path)
        .map_err(|e| e.to_string())
}

/// The frontend's ~2s poll target while onboarding/rebuild ingestion runs.
#[tauri::command]
pub fn ingestion_status(ingestion: State<'_, IngestionState>) -> Result<IngestionStatus, String> {
    Ok(ingestion.snapshot())
}

/// Every project root the user has ever picked (first-run or a later "add
/// another folder" — the same command handles both, `add_root` dedupes).
#[tauri::command]
pub fn roots_list(brain: State<'_, BrainState>) -> Result<Vec<String>, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    get_roots(&store).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn roots_biggest_project(
    brain: State<'_, BrainState>,
) -> Result<Option<ProjectSummary>, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    biggest_project(&store).map_err(|e| e.to_string())
}

/// Every project id currently marked paused (skipped by future
/// ingest/rebuild passes) — backs the sidebar context menu's checkbox
/// state.
#[tauri::command]
pub fn roots_paused_projects(brain: State<'_, BrainState>) -> Result<Vec<String>, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    brain_ingest::roots::paused_projects(&store).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn roots_set_paused(
    project: String,
    paused: bool,
    brain: State<'_, BrainState>,
) -> Result<(), String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    brain_ingest::roots::set_paused(&store, &project, paused).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn roots_staleness(brain: State<'_, BrainState>) -> Result<Vec<ProjectStaleness>, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    staleness(&store).map_err(|e| e.to_string())
}

/// Manual "re-check" action: re-ingests one already-known project from its
/// recorded path (no directory re-scan needed — the project node's `path`
/// already points at it) and refreshes its `last_ingested` stamp, clearing
/// the stale badge.
#[tauri::command]
pub fn roots_reingest_project(project: String, brain: State<'_, BrainState>) -> Result<(), String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    brain_ingest::roots::reingest_project(&store, &project).map_err(|e| e.to_string())
}

/// "Rebuild brain": deletes `brain.db` (+ WAL/SHM/journal siblings) and
/// re-ingests every persisted, non-paused root from scratch. Settings are
/// captured before the delete and replayed into the fresh database
/// afterward (see module doc — the point is wiping *derived graph data*,
/// not the user's roots/preferences). Never touches `brain/<project>/*.md`
/// memory: that directory lives entirely outside `brain.db` and nothing in
/// this function's path names or opens it.
#[tauri::command]
pub fn roots_rebuild(
    brain: State<'_, BrainState>,
    ingestion: State<'_, IngestionState>,
) -> Result<(), String> {
    brain_ingest::roots::rebuild_and_reingest(&brain.data_dir, &brain.store, ingestion.inner())
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_core::{now_ts, Node, NodeKind, Origin, Store};
    use brain_ingest::roots::{
        add_project_path, add_root, get_project_paths, ingest_one, ingest_roots_in_background,
        is_paused, last_ingested_key, pause_key, rebuild_store, PROJECT_ROOTS_KEY,
        STALE_THRESHOLD_SECS,
    };
    use std::path::{Path, PathBuf};
    use tempfile::tempdir;

    fn project_node(id: &str, root: &Path) -> Node {
        Node {
            id: id.to_string(),
            kind: NodeKind::Project,
            project: id.to_string(),
            label: id.to_string(),
            path: Some(root.to_string_lossy().to_string()),
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        }
    }

    #[test]
    fn get_roots_starts_empty_and_add_root_persists_and_dedupes() {
        let store = Store::open_in_memory().unwrap();
        assert!(get_roots(&store).unwrap().is_empty());

        add_root(&store, "/tmp/a").unwrap();
        add_root(&store, "/tmp/b").unwrap();
        add_root(&store, "/tmp/a").unwrap(); // dup, no-op

        assert_eq!(
            get_roots(&store).unwrap(),
            vec!["/tmp/a".to_string(), "/tmp/b".to_string()]
        );
    }

    #[test]
    fn roots_survive_reopen() {
        let dir = tempdir().unwrap();
        {
            let store = Store::open(dir.path()).unwrap();
            add_root(&store, "/tmp/a").unwrap();
        }
        let store = Store::open(dir.path()).unwrap();
        assert_eq!(get_roots(&store).unwrap(), vec!["/tmp/a".to_string()]);
    }

    #[test]
    fn pause_defaults_to_false_and_round_trips() {
        let store = Store::open_in_memory().unwrap();
        assert!(!is_paused(&store, "p1"));
        store.set_setting(&pause_key("p1"), "true").unwrap();
        assert!(is_paused(&store, "p1"));
        store.set_setting(&pause_key("p1"), "false").unwrap();
        assert!(!is_paused(&store, "p1"));
    }

    #[test]
    fn ingest_one_stamps_last_ingested_and_ingests_the_fixture() {
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("fixtures/sample-project");
        let store = Store::open_in_memory().unwrap();

        assert!(store
            .get_setting(&last_ingested_key("sample-project"))
            .unwrap()
            .is_none());
        let stats = ingest_one(&store, "sample-project", &fixture).unwrap();
        assert!(stats.files > 0);

        let stamp = store
            .get_setting(&last_ingested_key("sample-project"))
            .unwrap()
            .expect("last_ingested stamped");
        let stamp: i64 = stamp.parse().unwrap();
        assert!((now_ts() - stamp).abs() < 5);
    }

    #[test]
    fn biggest_project_picks_the_project_with_most_nodes() {
        let store = Store::open_in_memory().unwrap();
        store
            .upsert_node(&project_node("small", Path::new("/tmp/small")))
            .unwrap();
        store
            .upsert_node(&project_node("big", Path::new("/tmp/big")))
            .unwrap();
        for i in 0..5 {
            store
                .upsert_node(&Node {
                    id: format!("big:f{i}.ts"),
                    kind: NodeKind::File,
                    project: "big".to_string(),
                    label: format!("f{i}.ts"),
                    path: None,
                    summary: None,
                    origin: Origin::Extracted,
                    updated: now_ts(),
                })
                .unwrap();
        }

        let best = biggest_project(&store).unwrap().expect("a biggest project");
        assert_eq!(best.id, "big");
    }

    #[test]
    fn staleness_is_false_when_never_stamped_and_true_past_the_threshold() {
        let store = Store::open_in_memory().unwrap();
        store
            .upsert_node(&project_node("never-stamped", Path::new("/tmp/x")))
            .unwrap();
        store
            .upsert_node(&project_node("stale", Path::new("/tmp/y")))
            .unwrap();
        store
            .upsert_node(&project_node("fresh", Path::new("/tmp/z")))
            .unwrap();

        store
            .set_setting(
                &last_ingested_key("stale"),
                &(now_ts() - STALE_THRESHOLD_SECS - 10).to_string(),
            )
            .unwrap();
        store
            .set_setting(&last_ingested_key("fresh"), &now_ts().to_string())
            .unwrap();

        let readings = staleness(&store).unwrap();
        let get = |id: &str| readings.iter().find(|r| r.project == id).unwrap().clone();

        assert!(!get("never-stamped").stale, "{:?}", get("never-stamped"));
        assert!(get("never-stamped").last_ingested.is_none());
        assert!(get("stale").stale);
        assert!(!get("fresh").stale);
    }

    #[test]
    fn rebuild_store_wipes_extracted_data_but_replays_preserved_settings() {
        let dir = tempdir().unwrap();
        {
            let store = Store::open(dir.path()).unwrap();
            store
                .upsert_node(&project_node("p1", Path::new("/tmp/p1")))
                .unwrap();
            store
                .set_setting(PROJECT_ROOTS_KEY, r#"["/tmp/p1"]"#)
                .unwrap();
        }

        let mut preserved = std::collections::HashMap::new();
        preserved.insert(PROJECT_ROOTS_KEY.to_string(), r#"["/tmp/p1"]"#.to_string());
        preserved.insert("review_memory".to_string(), "true".to_string());

        let fresh = rebuild_store(dir.path(), &preserved).unwrap();

        assert!(
            fresh.get_node("p1").unwrap().is_none(),
            "extracted graph data must be wiped by a rebuild"
        );
        assert_eq!(
            fresh.get_setting(PROJECT_ROOTS_KEY).unwrap(),
            Some(r#"["/tmp/p1"]"#.to_string()),
            "preserved settings must survive the rebuild"
        );
        assert_eq!(
            fresh.get_setting("review_memory").unwrap(),
            Some("true".to_string())
        );
    }

    #[test]
    fn rebuild_store_works_even_while_an_old_connection_to_the_same_file_is_still_open() {
        let dir = tempdir().unwrap();
        let old_store = Store::open(dir.path()).unwrap();
        old_store
            .upsert_node(&project_node("p1", Path::new("/tmp/p1")))
            .unwrap();

        // The old connection (`old_store`) is deliberately kept alive here —
        // this is exactly the situation `roots_rebuild`'s command body is
        // in: the `MutexGuard` still holds the old `Store` while this runs.
        let fresh = rebuild_store(dir.path(), &std::collections::HashMap::new()).unwrap();
        assert!(fresh.get_node("p1").unwrap().is_none());

        // The old handle is still perfectly usable against its own
        // (unlinked-but-open) file — proves this doesn't corrupt anything
        // it's still holding.
        assert!(old_store.get_node("p1").unwrap().is_some());
    }

    #[test]
    fn ingestion_state_snapshot_reflects_updates() {
        let state = IngestionState::new();
        assert!(!state.snapshot().running);
        state.update(|s| {
            s.running = true;
            s.projects_total = 3;
        });
        let snap = state.snapshot();
        assert!(snap.running);
        assert_eq!(snap.projects_total, 3);
    }

    /// Bug: `IngestionState` had incompatible update semantics between the
    /// bulk-ingest path (`ingest_roots_in_background`, which used to
    /// destructively reset the whole struct at start and unconditionally
    /// clear `running` at the end) and the per-project `add_project` path
    /// (`ingest_project_in_background`, which additively bumped counters
    /// and only conditionally cleared `running`). Exact failure scenario
    /// named in the bug report: a bulk ingest starts, an `add_project`
    /// ingest starts concurrently, the bulk one finishes first -- with the
    /// old code this incorrectly reported `running: false` (re-enabling
    /// `roots_start_ingest`/`roots_rebuild` while the `add_project` ingest
    /// was still actually running), and a bulk ingest starting mid-flight
    /// would destructively reset the other operation's counters.
    ///
    /// Simulated directly at the state-transition level (`begin`/`end`)
    /// rather than through real background threads/timing, since the
    /// actual bug is entirely about the state machine's semantics, not
    /// about scheduling -- this is deterministic and non-flaky where a
    /// real-thread race would not be.
    #[test]
    fn running_stays_true_and_counters_are_not_clobbered_while_a_second_ingestion_is_still_active_after_the_first_finishes(
    ) {
        let status = IngestionState::new();
        assert!(!status.snapshot().running, "idle at start");

        // Bulk-style ingest starts: discovers 2 projects.
        status.begin(2);
        assert!(status.snapshot().running);
        assert_eq!(status.snapshot().projects_total, 2);

        // One of the bulk run's two projects finishes.
        status.update(|s| s.projects_done += 1);

        // An add_project-style ingest starts *concurrently* -- must be
        // additive, not a destructive reset: the bulk run's
        // already-accumulated counters must survive.
        status.begin(1);
        let mid = status.snapshot();
        assert!(mid.running);
        assert_eq!(
            mid.projects_total, 3,
            "2 from bulk + 1 from add_project, additive"
        );
        assert_eq!(
            mid.projects_done, 1,
            "must not have been reset by the second begin()"
        );

        // The bulk ingest's second (and last) project finishes, then the
        // bulk operation itself ends.
        status.update(|s| s.projects_done += 1);
        status.end();

        // The add_project ingestion is STILL active -- `running` must
        // stay true. This is the exact bug: the old bulk path always did
        // an unconditional `running = false` here regardless of any
        // other still-active ingestion.
        let after_bulk_ends = status.snapshot();
        assert!(
            after_bulk_ends.running,
            "running must stay true while the add_project ingestion is still active"
        );
        assert_eq!(after_bulk_ends.projects_done, 2);

        // The add_project ingestion's own project finishes, and it ends
        // too -- only now should `running` correctly flip to false.
        status.update(|s| s.projects_done += 1);
        status.end();
        let final_snap = status.snapshot();
        assert!(!final_snap.running, "both ingestions are done now");
        assert_eq!(final_snap.projects_done, 3);
    }

    #[test]
    fn ingest_roots_in_background_ingests_discovered_projects_and_flips_running_false() {
        let data_dir = tempdir().unwrap();
        let projects_root = tempdir().unwrap();
        let proj_dir = projects_root.path().join("demo-project");
        std::fs::create_dir_all(proj_dir.join(".git")).unwrap();
        std::fs::write(proj_dir.join("a.ts"), "export const a = 1;\n").unwrap();

        let status = IngestionState::new();
        ingest_roots_in_background(
            data_dir.path().to_path_buf(),
            vec![projects_root.path().to_string_lossy().into_owned()],
            Vec::new(),
            status.clone(),
        );

        // The background thread runs fast against this tiny fixture; poll
        // briefly rather than assume a fixed sleep is long enough on a
        // loaded CI box.
        let mut snap = status.snapshot();
        for _ in 0..200 {
            if !snap.running && snap.projects_total > 0 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
            snap = status.snapshot();
        }

        assert!(!snap.running, "{snap:?}");
        assert_eq!(snap.projects_total, 1);
        assert_eq!(snap.projects_done, 1);
        assert!(snap.total_nodes > 0);

        let store = Store::open(data_dir.path()).unwrap();
        assert!(store.get_node("demo-project").unwrap().is_some());
        assert!(store
            .get_setting(&last_ingested_key("demo-project"))
            .unwrap()
            .is_some());
    }

    #[test]
    fn ingest_roots_in_background_skips_paused_projects() {
        let data_dir = tempdir().unwrap();
        let projects_root = tempdir().unwrap();
        let proj_dir = projects_root.path().join("paused-project");
        std::fs::create_dir_all(proj_dir.join(".git")).unwrap();
        std::fs::write(proj_dir.join("a.ts"), "export const a = 1;\n").unwrap();

        // Pre-seed the pause flag in the store the background thread will
        // open (same data_dir).
        {
            let store = Store::open(data_dir.path()).unwrap();
            store
                .set_setting(&pause_key("paused-project"), "true")
                .unwrap();
        }

        let status = IngestionState::new();
        ingest_roots_in_background(
            data_dir.path().to_path_buf(),
            vec![projects_root.path().to_string_lossy().into_owned()],
            Vec::new(),
            status.clone(),
        );

        let mut snap = status.snapshot();
        for _ in 0..200 {
            if !snap.running && snap.projects_total > 0 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
            snap = status.snapshot();
        }

        assert_eq!(
            snap.projects_done, 1,
            "paused project still counts toward progress"
        );
        let store = Store::open(data_dir.path()).unwrap();
        assert!(
            store.get_node("paused-project").unwrap().is_none(),
            "paused project must not actually be ingested"
        );
    }

    #[test]
    fn ingest_roots_in_background_also_ingests_extra_projects_outside_any_root() {
        let data_dir = tempdir().unwrap();
        let standalone = tempdir().unwrap();
        std::fs::create_dir_all(standalone.path().join(".git")).unwrap();
        std::fs::write(standalone.path().join("a.ts"), "export const a = 1;\n").unwrap();

        let status = IngestionState::new();
        ingest_roots_in_background(
            data_dir.path().to_path_buf(),
            Vec::new(), // no bulk roots at all — proves `extra_projects` alone is enough
            vec![("standalone".to_string(), standalone.path().to_path_buf())],
            status.clone(),
        );

        let mut snap = status.snapshot();
        for _ in 0..200 {
            if !snap.running && snap.projects_total > 0 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
            snap = status.snapshot();
        }

        assert_eq!(snap.projects_total, 1);
        assert_eq!(snap.projects_done, 1);

        let store = Store::open(data_dir.path()).unwrap();
        assert!(store.get_node("standalone").unwrap().is_some());
    }

    #[test]
    fn project_paths_round_trip_and_overwrite_by_id() {
        let store = Store::open_in_memory().unwrap();
        assert!(get_project_paths(&store).unwrap().is_empty());

        add_project_path(&store, "p1", "/tmp/p1").unwrap();
        add_project_path(&store, "p2", "/tmp/p2").unwrap();
        add_project_path(&store, "p1", "/tmp/p1-moved").unwrap(); // overwrite by id

        let paths = get_project_paths(&store).unwrap();
        assert_eq!(paths.get("p1").map(String::as_str), Some("/tmp/p1-moved"));
        assert_eq!(paths.get("p2").map(String::as_str), Some("/tmp/p2"));
    }

    #[test]
    fn add_project_creates_the_node_and_records_the_path_immediately() {
        let data_dir = tempdir().unwrap();
        let project_dir = tempdir().unwrap();
        let brain = BrainState::open(data_dir.path().to_path_buf()).unwrap();
        let ingestion = IngestionState::new();

        let path = project_dir.path().to_string_lossy().into_owned();
        let summary = add_project_impl(&brain, &ingestion, &path, Some("My Project")).unwrap();

        assert_eq!(summary.id, "My Project");
        assert_eq!(summary.label, "My Project");
        assert_eq!(summary.path.as_deref(), Some(path.as_str()));

        // Queryable RIGHT AWAY — no waiting on ingestion.
        let store = brain.store.lock().unwrap();
        let node = store
            .get_node("My Project")
            .unwrap()
            .expect("node created synchronously");
        assert_eq!(node.kind, NodeKind::Project);
        assert_eq!(node.path.as_deref(), Some(path.as_str()));

        let paths = get_project_paths(&store).unwrap();
        assert_eq!(
            paths.get("My Project").map(String::as_str),
            Some(path.as_str())
        );
    }

    #[test]
    fn add_project_defaults_the_id_to_the_folder_basename_when_no_name_given() {
        let data_dir = tempdir().unwrap();
        let project_dir = tempdir().unwrap();
        let expected_id = project_dir
            .path()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let brain = BrainState::open(data_dir.path().to_path_buf()).unwrap();
        let ingestion = IngestionState::new();

        let summary = add_project_impl(
            &brain,
            &ingestion,
            &project_dir.path().to_string_lossy(),
            None,
        )
        .unwrap();

        assert_eq!(summary.id, expected_id);
    }

    #[test]
    fn add_project_rejects_a_path_that_is_not_a_directory() {
        let data_dir = tempdir().unwrap();
        let brain = BrainState::open(data_dir.path().to_path_buf()).unwrap();
        let ingestion = IngestionState::new();

        let err = add_project_impl(
            &brain,
            &ingestion,
            "/definitely/not/a/real/path-xyz-nope",
            None,
        )
        .unwrap_err();
        assert!(err.to_string().contains("not a directory"), "{err}");
    }

    #[test]
    fn add_project_kicks_off_background_ingestion_without_blocking_the_caller() {
        let data_dir = tempdir().unwrap();
        let project_root = tempdir().unwrap();
        std::fs::create_dir_all(project_root.path().join(".git")).unwrap();
        std::fs::write(project_root.path().join("a.ts"), "export const a = 1;\n").unwrap();
        let project_name = project_root
            .path()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();

        let brain = BrainState::open(data_dir.path().to_path_buf()).unwrap();
        let ingestion = IngestionState::new();

        let started = std::time::Instant::now();
        let summary = add_project_impl(
            &brain,
            &ingestion,
            &project_root.path().to_string_lossy(),
            None,
        )
        .unwrap();
        // Returns essentially immediately — well before a real ingest (even
        // of this tiny fixture) could plausibly have completed if this were
        // synchronous.
        assert!(
            started.elapsed() < std::time::Duration::from_millis(200),
            "{:?}",
            started.elapsed()
        );
        assert_eq!(summary.id, project_name);

        let mut snap = ingestion.snapshot();
        for _ in 0..200 {
            if !snap.running && snap.projects_done > 0 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
            snap = ingestion.snapshot();
        }

        assert!(!snap.running, "{snap:?}");
        assert_eq!(snap.projects_done, 1);

        // The background ingest actually ran to completion (stamped
        // last_ingested via ingest_one) using its OWN store connection —
        // proves this didn't just fake it by relying on the synchronous
        // upsert alone.
        let store = Store::open(data_dir.path()).unwrap();
        assert!(store
            .get_setting(&last_ingested_key(&project_name))
            .unwrap()
            .is_some());
    }

    #[test]
    fn rename_project_sets_the_label_override_and_list_projects_reflects_it() {
        let data_dir = tempdir().unwrap();
        let project_dir = tempdir().unwrap();
        let brain = BrainState::open(data_dir.path().to_path_buf()).unwrap();
        {
            let store = brain.store.lock().unwrap();
            store
                .upsert_node(&project_node("OmniAgent-ADE", project_dir.path()))
                .unwrap();
        }

        rename_project_impl(&brain, "OmniAgent-ADE", "OmniAgent").unwrap();

        let store = brain.store.lock().unwrap();
        // The node's own id/label columns are untouched — only the
        // settings-table override is written (see rename_project's doc for
        // why: ingestion unconditionally resets the node's own label).
        let node = store.get_node("OmniAgent-ADE").unwrap().unwrap();
        assert_eq!(node.id, "OmniAgent-ADE");
        assert_eq!(node.label, "OmniAgent-ADE");
        assert_eq!(
            store
                .get_setting(&mcp_server::tools::project_label_key("OmniAgent-ADE"))
                .unwrap()
                .as_deref(),
            Some("OmniAgent")
        );
    }

    #[test]
    fn rename_project_survives_a_simulated_reingest_that_resets_the_nodes_own_label() {
        let data_dir = tempdir().unwrap();
        let project_dir = tempdir().unwrap();
        let brain = BrainState::open(data_dir.path().to_path_buf()).unwrap();
        {
            let store = brain.store.lock().unwrap();
            store
                .upsert_node(&project_node("OmniAgent-ADE", project_dir.path()))
                .unwrap();
        }
        rename_project_impl(&brain, "OmniAgent-ADE", "OmniAgent").unwrap();

        // Simulate a re-ingest pass (`ingest_project`'s own unconditional
        // Project-node upsert) landing after the rename.
        {
            let store = brain.store.lock().unwrap();
            store
                .upsert_node(&project_node("OmniAgent-ADE", project_dir.path()))
                .unwrap();
        }

        let ctx = mcp_server::tools::ToolContext {
            store: &brain.store.lock().unwrap(),
            data_dir: data_dir.path(),
        };
        let projects = mcp_server::tools::list_projects(&ctx, &serde_json::json!({})).unwrap();
        assert_eq!(
            projects[0]["label"], "OmniAgent",
            "rename must survive a re-ingest"
        );
    }

    #[test]
    fn rename_project_rejects_a_blank_name() {
        let data_dir = tempdir().unwrap();
        let project_dir = tempdir().unwrap();
        let brain = BrainState::open(data_dir.path().to_path_buf()).unwrap();
        {
            let store = brain.store.lock().unwrap();
            store
                .upsert_node(&project_node("p1", project_dir.path()))
                .unwrap();
        }

        let err = rename_project_impl(&brain, "p1", "   ").unwrap_err();
        assert!(err.to_string().contains("empty"), "{err}");
    }

    #[test]
    fn rename_project_rejects_an_unknown_project_id() {
        let data_dir = tempdir().unwrap();
        let brain = BrainState::open(data_dir.path().to_path_buf()).unwrap();

        let err = rename_project_impl(&brain, "does-not-exist", "New Name").unwrap_err();
        assert!(err.to_string().contains("unknown project"), "{err}");
    }
}

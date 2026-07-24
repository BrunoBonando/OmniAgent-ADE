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
//!   [`ingest_one`] call) against [`STALE_THRESHOLD_SECS`]. A project with
//!   no such setting at all (e.g. ingested earlier by the `brain` CLI,
//!   before this task existed) is reported *not* stale rather than flagged
//!   on first launch — the signal is "hasn't been refreshed in a while",
//!   not "we've never personally watched it," which would false-positive on
//!   every pre-Phase-8 project the instant this ships.
//! - **Per-project pause**: `ingest_paused:<project>` in `settings`, checked
//!   by [`ingest_roots_in_background`] before touching a project — paused
//!   projects are skipped on both first-run ingestion and "Rebuild brain".
//! - **Rebuild brain**: [`rebuild_brain`] deletes `brain.db` (+ WAL/SHM/
//!   journal siblings) and re-ingests every persisted root from scratch.
//!   Markdown memory (`brain/<project>/*.md`) lives entirely outside
//!   `brain.db` and this function never touches that directory — DESIGN.md
//!   5's line: the DB is derived/rebuildable, memory is not. Settings
//!   (roots, pause flags, review mode, tab layout, default engines) are
//!   captured before the delete and replayed into the fresh database so
//!   "rebuild the derived graph" doesn't also mean "forget every
//!   preference."

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::Result;
use brain_core::{now_ts, Store};
use serde::Serialize;
use tauri::State;

use crate::commands::BrainState;

const PROJECT_ROOTS_KEY: &str = "project_roots";
const PAUSE_PREFIX: &str = "ingest_paused:";
const LAST_INGESTED_PREFIX: &str = "last_ingested:";

/// A project not (re)ingested by the app in this long is reported "stale" by
/// [`roots_staleness`]. `ponytail:` a flat constant rather than a settings
/// toggle — tune once real dogfood usage says otherwise.
const STALE_THRESHOLD_SECS: i64 = 24 * 60 * 60;

// --------------------------------------------------------------- settings

fn get_roots(store: &Store) -> Result<Vec<String>> {
    let raw = store.get_setting(PROJECT_ROOTS_KEY)?;
    Ok(match raw {
        Some(s) => serde_json::from_str(&s).unwrap_or_default(),
        None => Vec::new(),
    })
}

fn add_root(store: &Store, path: &str) -> Result<()> {
    let mut roots = get_roots(store)?;
    if !roots.iter().any(|r| r == path) {
        roots.push(path.to_string());
        store.set_setting(PROJECT_ROOTS_KEY, &serde_json::to_string(&roots)?)?;
    }
    Ok(())
}

fn pause_key(project: &str) -> String {
    format!("{PAUSE_PREFIX}{project}")
}

fn is_paused(store: &Store, project: &str) -> bool {
    store
        .get_setting(&pause_key(project))
        .ok()
        .flatten()
        .as_deref()
        == Some("true")
}

fn last_ingested_key(project: &str) -> String {
    format!("{LAST_INGESTED_PREFIX}{project}")
}

/// Ingests one already-known project directory and stamps its
/// `last_ingested:<project>` setting on success. Shared by first-run
/// ingestion, "Rebuild brain", and the single-project "re-check" action —
/// one place that both does the ingest and records when it happened.
fn ingest_one(store: &Store, name: &str, dir: &Path) -> Result<brain_ingest::IngestStats> {
    let stats = brain_ingest::ingest_project(store, dir, name)?;
    store.set_setting(&last_ingested_key(name), &now_ts().to_string())?;
    Ok(stats)
}

// ------------------------------------------------------------- ingestion

/// Snapshot of an in-flight (or just-finished) ingestion run — polled by
/// the frontend every ~2s while `running` is true (PLAN.md Task 8.1: "poll
/// ingestion progress ... let the already-built BrainMap component visually
/// reflect growth in near-real-time").
#[derive(Debug, Clone, Default, Serialize)]
pub struct IngestionStatus {
    pub running: bool,
    pub projects_total: usize,
    pub projects_done: usize,
    pub current_project: Option<String>,
    /// Total node count across the whole brain, refreshed after each
    /// project finishes — the number the map pane's live growth is really
    /// standing in for.
    pub total_nodes: usize,
    pub error: Option<String>,
}

/// `Arc<Mutex<..>>`-backed Tauri-managed state, cloneable so a background
/// `std::thread::spawn` closure can hold its own handle without borrowing
/// from a `tauri::State` (which isn't `'static`) — same reasoning `lib.rs`'s
/// existing drain-loop thread already applies to `data_dir`.
#[derive(Clone)]
pub struct IngestionState(Arc<Mutex<IngestionStatus>>);

impl IngestionState {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(IngestionStatus::default())))
    }

    fn snapshot(&self) -> IngestionStatus {
        self.0.lock().expect("ingestion status mutex poisoned").clone()
    }

    fn update(&self, f: impl FnOnce(&mut IngestionStatus)) {
        let mut guard = self.0.lock().expect("ingestion status mutex poisoned");
        f(&mut guard);
    }
}

impl Default for IngestionState {
    fn default() -> Self {
        Self::new()
    }
}

/// Runs on a background thread (spawned by [`roots_start_ingest`] /
/// [`rebuild_brain`]): discovers projects under `roots` (skipping any
/// already-known project marked paused) and ingests each in turn, updating
/// `status` as it goes so [`ingestion_status`] has something fresh to
/// report. Opens its own `Store` connection rather than sharing
/// `BrainState`'s — same rationale as `lib.rs`'s drain-loop thread: SQLite
/// handles multiple local connections to one `brain.db` fine at this write
/// volume, and it avoids threading a `'static` reference to `BrainState`
/// through here.
fn ingest_roots_in_background(data_dir: PathBuf, roots: Vec<String>, status: IngestionState) {
    std::thread::spawn(move || {
        let store = match Store::open(&data_dir) {
            Ok(s) => s,
            Err(e) => {
                status.update(|s| {
                    s.running = false;
                    s.error = Some(format!("failed to open brain store: {e}"));
                });
                return;
            }
        };

        let mut discovered: Vec<(String, PathBuf)> = Vec::new();
        for root in &roots {
            discovered.extend(brain_ingest::discover_projects(Path::new(root)));
        }

        status.update(|s| {
            *s = IngestionStatus {
                running: true,
                projects_total: discovered.len(),
                ..Default::default()
            };
        });

        for (name, dir) in &discovered {
            if is_paused(&store, name) {
                status.update(|s| s.projects_done += 1);
                continue;
            }
            status.update(|s| s.current_project = Some(name.clone()));
            if let Err(e) = ingest_one(&store, name, dir) {
                eprintln!("omniagent-ade: ingest of {name} failed: {e}");
                status.update(|s| s.error = Some(format!("{name}: {e}")));
            }
            let total_nodes = store.all_nodes().map(|n| n.len()).unwrap_or(0);
            status.update(|s| {
                s.projects_done += 1;
                s.total_nodes = total_nodes;
            });
        }

        status.update(|s| {
            s.running = false;
            s.current_project = None;
        });
    });
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
    let root = PathBuf::from(&path);
    if !root.is_dir() {
        return Err(format!("{path} is not a directory"));
    }
    if ingestion.snapshot().running {
        return Err("ingestion is already running".to_string());
    }

    {
        let store = brain.store.lock().map_err(|e| e.to_string())?;
        add_root(&store, &path).map_err(|e| e.to_string())?;
    }

    ingest_roots_in_background(brain.data_dir.clone(), vec![path], ingestion.inner().clone());
    Ok(())
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

/// The project with the most nodes in the store — Task 8.1's "offer a first
/// terminal tab on the project with the most files/entities." Mirrors the
/// `{id, label, path}` shape `list_projects`/`ProjectInfo` already use on
/// the frontend, so the same `sessionCreate`/`requestNewTab` flow can
/// consume it directly.
#[derive(Debug, Clone, Serialize)]
pub struct ProjectSummary {
    pub id: String,
    pub label: String,
    pub path: Option<String>,
}

#[tauri::command]
pub fn roots_biggest_project(brain: State<'_, BrainState>) -> Result<Option<ProjectSummary>, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    biggest_project(&store).map_err(|e| e.to_string())
}

fn biggest_project(store: &Store) -> Result<Option<ProjectSummary>> {
    let projects = store.list_projects()?;
    let mut best: Option<(ProjectSummary, usize)> = None;
    for p in projects {
        let count = store.nodes_for_project(&p.project)?.len();
        let bigger = best.as_ref().map(|(_, c)| count > *c).unwrap_or(true);
        if bigger {
            best = Some((
                ProjectSummary {
                    id: p.id,
                    label: p.label,
                    path: p.path,
                },
                count,
            ));
        }
    }
    Ok(best.map(|(p, _)| p))
}

// -------------------------------------------------------- pause / staleness

/// Every project id currently marked paused (skipped by future
/// ingest/rebuild passes) — backs the sidebar context menu's checkbox
/// state.
#[tauri::command]
pub fn roots_paused_projects(brain: State<'_, BrainState>) -> Result<Vec<String>, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    let settings = store.all_settings().map_err(|e| e.to_string())?;
    Ok(settings
        .into_iter()
        .filter_map(|(k, v)| {
            (v == "true")
                .then(|| k.strip_prefix(PAUSE_PREFIX).map(str::to_string))
                .flatten()
        })
        .collect())
}

#[tauri::command]
pub fn roots_set_paused(project: String, paused: bool, brain: State<'_, BrainState>) -> Result<(), String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    store
        .set_setting(&pause_key(&project), if paused { "true" } else { "false" })
        .map_err(|e| e.to_string())
}

/// One project's staleness reading — [`roots_staleness`]'s response shape.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ProjectStaleness {
    pub project: String,
    pub last_ingested: Option<i64>,
    pub stale: bool,
}

#[tauri::command]
pub fn roots_staleness(brain: State<'_, BrainState>) -> Result<Vec<ProjectStaleness>, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    staleness(&store).map_err(|e| e.to_string())
}

fn staleness(store: &Store) -> Result<Vec<ProjectStaleness>> {
    let now = now_ts();
    let projects = store.list_projects()?;
    let mut out = Vec::with_capacity(projects.len());
    for p in projects {
        let last_ingested: Option<i64> = store
            .get_setting(&last_ingested_key(&p.project))?
            .and_then(|s| s.parse().ok());
        // Missing timestamp = never (re)ingested by this app version (e.g. a
        // project the `brain` CLI ingested pre-Phase-8) — not stale, per the
        // module doc: absence of evidence isn't evidence of staleness here.
        let stale = last_ingested
            .map(|t| now - t > STALE_THRESHOLD_SECS)
            .unwrap_or(false);
        out.push(ProjectStaleness {
            project: p.project,
            last_ingested,
            stale,
        });
    }
    Ok(out)
}

/// Manual "re-check" action: re-ingests one already-known project from its
/// recorded path (no directory re-scan needed — the project node's `path`
/// already points at it) and refreshes its `last_ingested` stamp, clearing
/// the stale badge.
#[tauri::command]
pub fn roots_reingest_project(project: String, brain: State<'_, BrainState>) -> Result<(), String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    let node = store
        .get_node(&project)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("unknown project: {project}"))?;
    let path = node
        .path
        .ok_or_else(|| format!("project {project} has no recorded path"))?;
    ingest_one(&store, &project, Path::new(&path)).map_err(|e| e.to_string())?;
    Ok(())
}

// -------------------------------------------------------------- rebuild

/// "Rebuild brain": deletes `brain.db` (+ WAL/SHM/journal siblings) and
/// re-ingests every persisted, non-paused root from scratch. Settings are
/// captured before the delete and replayed into the fresh database
/// afterward (see module doc — the point is wiping *derived graph data*,
/// not the user's roots/preferences). Never touches `brain/<project>/*.md`
/// memory: that directory lives entirely outside `brain.db` and nothing in
/// this function's path names or opens it.
#[tauri::command]
pub fn roots_rebuild(brain: State<'_, BrainState>, ingestion: State<'_, IngestionState>) -> Result<(), String> {
    if ingestion.snapshot().running {
        return Err("ingestion is already running".to_string());
    }

    let roots = {
        let mut guard = brain.store.lock().map_err(|e| e.to_string())?;
        let preserved: HashMap<String, String> = guard.all_settings().map_err(|e| e.to_string())?.into_iter().collect();
        let roots = get_roots(&guard).map_err(|e| e.to_string())?;
        let fresh = rebuild_store(&brain.data_dir, &preserved).map_err(|e| e.to_string())?;
        *guard = fresh;
        roots
    };

    ingest_roots_in_background(brain.data_dir.clone(), roots, ingestion.inner().clone());
    Ok(())
}

/// Deletes `brain.db` (+ WAL/SHM/journal siblings) under `data_dir` and
/// opens a fresh `Store`, replaying every `(key, value)` in `preserved` into
/// it. Factored out of the `#[tauri::command]` above so it's directly
/// unit-testable against a tempdir, independent of Tauri's `State`
/// plumbing (this codebase's established split — see `map_feed.rs`'s
/// `build_map_graph`/command pair for the same pattern). Safe to call while
/// another `Store`/`Connection` still has the old file open: `remove_file`
/// is a POSIX `unlink`, which only removes the directory entry — the old
/// connection keeps working against the (now-nameless) inode until it's
/// dropped, and `Store::open` right after creates a brand new file at the
/// same path.
fn rebuild_store(data_dir: &Path, preserved: &HashMap<String, String>) -> Result<Store> {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut name = data_dir.join("brain.db").into_os_string();
        name.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(name));
    }

    let fresh = Store::open(data_dir)?;
    for (k, v) in preserved {
        fresh.set_setting(k, v)?;
    }
    Ok(fresh)
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_core::{Node, NodeKind, Origin};
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

        assert!(store.get_setting(&last_ingested_key("sample-project")).unwrap().is_none());
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
        store.upsert_node(&project_node("small", Path::new("/tmp/small"))).unwrap();
        store.upsert_node(&project_node("big", Path::new("/tmp/big"))).unwrap();
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
        store.upsert_node(&project_node("never-stamped", Path::new("/tmp/x"))).unwrap();
        store.upsert_node(&project_node("stale", Path::new("/tmp/y"))).unwrap();
        store.upsert_node(&project_node("fresh", Path::new("/tmp/z"))).unwrap();

        store
            .set_setting(&last_ingested_key("stale"), &(now_ts() - STALE_THRESHOLD_SECS - 10).to_string())
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
            store.upsert_node(&project_node("p1", Path::new("/tmp/p1"))).unwrap();
            store.set_setting(PROJECT_ROOTS_KEY, r#"["/tmp/p1"]"#).unwrap();
        }

        let mut preserved = HashMap::new();
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
        assert_eq!(fresh.get_setting("review_memory").unwrap(), Some("true".to_string()));
    }

    #[test]
    fn rebuild_store_works_even_while_an_old_connection_to_the_same_file_is_still_open() {
        let dir = tempdir().unwrap();
        let old_store = Store::open(dir.path()).unwrap();
        old_store.upsert_node(&project_node("p1", Path::new("/tmp/p1"))).unwrap();

        // The old connection (`old_store`) is deliberately kept alive here —
        // this is exactly the situation `roots_rebuild`'s command body is
        // in: the `MutexGuard` still holds the old `Store` while this runs.
        let fresh = rebuild_store(dir.path(), &HashMap::new()).unwrap();
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
            store.set_setting(&pause_key("paused-project"), "true").unwrap();
        }

        let status = IngestionState::new();
        ingest_roots_in_background(
            data_dir.path().to_path_buf(),
            vec![projects_root.path().to_string_lossy().into_owned()],
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

        assert_eq!(snap.projects_done, 1, "paused project still counts toward progress");
        let store = Store::open(data_dir.path()).unwrap();
        assert!(
            store.get_node("paused-project").unwrap().is_none(),
            "paused project must not actually be ingested"
        );
    }
}

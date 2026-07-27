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
use brain_core::{now_ts, Node, NodeKind, Origin, Store};
use serde::Serialize;
use tauri::State;

use crate::commands::BrainState;

const PROJECT_ROOTS_KEY: &str = "project_roots";
const PAUSE_PREFIX: &str = "ingest_paused:";
const LAST_INGESTED_PREFIX: &str = "last_ingested:";
/// Individually-added projects (Bruno's founder-feedback fast path, task
/// [`add_project`]): `{id: path}` JSON, distinct from [`PROJECT_ROOTS_KEY`]
/// because the two have different walk semantics — a "root" is a parent
/// folder `discover_projects` scans for *many* project subdirectories,
/// while an entry here is already one exact project directory that must be
/// re-ingested directly (via [`ingest_one`]), never walked. Read by
/// [`roots_rebuild`] so a project added this way survives "Rebuild brain"
/// instead of silently vanishing because it isn't under any known root.
const PROJECT_PATHS_KEY: &str = "project_paths";

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

/// Every individually-added project (`add_project`), `id -> path`.
fn get_project_paths(store: &Store) -> Result<HashMap<String, String>> {
    let raw = store.get_setting(PROJECT_PATHS_KEY)?;
    Ok(match raw {
        Some(s) => serde_json::from_str(&s).unwrap_or_default(),
        None => HashMap::new(),
    })
}

/// Records (or overwrites, keyed by `id`) one individually-added project's
/// path so a future "Rebuild brain" knows to re-ingest it directly.
fn add_project_path(store: &Store, id: &str, path: &str) -> Result<()> {
    let mut paths = get_project_paths(store)?;
    paths.insert(id.to_string(), path.to_string());
    store.set_setting(PROJECT_PATHS_KEY, &serde_json::to_string(&paths)?)?;
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
    /// How many independent ingestion operations (bulk root scans from
    /// [`ingest_roots_in_background`], individual `add_project` ingests
    /// from [`ingest_project_in_background`]) are currently active.
    /// `running` is always *derived* from this being `> 0` (see
    /// [`IngestionState::begin`]/[`IngestionState::end`]) rather than
    /// being an independently-set bool — this is the fix for the bug
    /// where the two paths disagreed about who "owned" clearing it: one
    /// ingestion finishing can no longer incorrectly clear `running`
    /// while a different one is still in flight. Not part of the public
    /// snapshot contract the frontend polls (`ingestion_status`'s JSON
    /// shape is unchanged).
    #[serde(skip)]
    active_workers: usize,
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
        self.0
            .lock()
            .expect("ingestion status mutex poisoned")
            .clone()
    }

    fn update(&self, f: impl FnOnce(&mut IngestionStatus)) {
        let mut guard = self.0.lock().expect("ingestion status mutex poisoned");
        f(&mut guard);
    }

    /// Marks one independent ingestion operation (a bulk root scan or a
    /// single `add_project` ingest) as starting: bumps the active-worker
    /// count (deriving `running = true`) and *additively* grows
    /// `projects_total` by `additional_projects` — never a destructive
    /// reset, so a second operation starting while the first is still
    /// running never clobbers its in-flight counters (the bug: the old
    /// bulk path unconditionally did `*status = IngestionStatus { .. }`
    /// here, wiping out anything an already-running `add_project` ingest
    /// had accumulated).
    fn begin(&self, additional_projects: usize) {
        self.update(|s| {
            s.active_workers += 1;
            s.running = true;
            s.projects_total += additional_projects;
        });
    }

    /// Marks one independent ingestion operation as finished: decrements
    /// the active-worker count and derives `running` from whether any
    /// other operation is still active — never unconditionally clears it
    /// (the bug: both paths used to set `running = false` at their own
    /// end regardless of whether a sibling operation was still going).
    /// `current_project` is only cleared once nothing is active anymore,
    /// so it doesn't flicker to `None` while a sibling ingestion is still
    /// working through its own projects.
    fn end(&self) {
        self.update(|s| {
            s.active_workers = s.active_workers.saturating_sub(1);
            s.running = s.active_workers > 0;
            if s.active_workers == 0 {
                s.current_project = None;
            }
        });
    }
}

impl Default for IngestionState {
    fn default() -> Self {
        Self::new()
    }
}

/// Ingests one project and folds the result into `status` — the
/// per-project body shared by the bulk discovery loop
/// ([`ingest_roots_in_background`]) and the single-project fast path
/// ([`ingest_project_in_background`]).
fn run_one_ingest(store: &Store, name: &str, dir: &Path, status: &IngestionState) {
    status.update(|s| s.current_project = Some(name.to_string()));
    if let Err(e) = ingest_one(store, name, dir) {
        eprintln!("omniagent-ade: ingest of {name} failed: {e}");
        status.update(|s| s.error = Some(format!("{name}: {e}")));
    }
    let total_nodes = store.all_nodes().map(|n| n.len()).unwrap_or(0);
    status.update(|s| {
        s.projects_done += 1;
        s.total_nodes = total_nodes;
    });
}

/// Runs on a background thread (spawned by [`roots_start_ingest`] /
/// [`rebuild_brain`]): discovers projects under `roots` (skipping any
/// already-known project marked paused), adds `extra_projects` (already-
/// known exact project directories — [`add_project`]'s individually-tracked
/// projects, re-ingested on rebuild without being walked/rediscovered), and
/// ingests each in turn, updating `status` as it goes so [`ingestion_status`]
/// has something fresh to report. Opens its own `Store` connection rather
/// than sharing `BrainState`'s — same rationale as `lib.rs`'s drain-loop
/// thread: SQLite handles multiple local connections to one `brain.db` fine
/// at this write volume, and it avoids threading a `'static` reference to
/// `BrainState` through here.
fn ingest_roots_in_background(
    data_dir: PathBuf,
    roots: Vec<String>,
    extra_projects: Vec<(String, PathBuf)>,
    status: IngestionState,
) {
    std::thread::spawn(move || {
        let store = match Store::open(&data_dir) {
            Ok(s) => s,
            Err(e) => {
                // `begin()` was never called (nothing to compose with yet),
                // so there's no active-worker count to unwind here — just
                // record the error. `running` is left exactly as `begin()`
                // would have found it (untouched by this failed attempt).
                status.update(|s| {
                    s.error = Some(format!("failed to open brain store: {e}"));
                });
                return;
            }
        };

        let mut discovered: Vec<(String, PathBuf)> = Vec::new();
        for root in &roots {
            discovered.extend(brain_ingest::discover_projects(Path::new(root)));
        }
        discovered.extend(extra_projects);

        status.begin(discovered.len());

        for (name, dir) in &discovered {
            if is_paused(&store, name) {
                status.update(|s| s.projects_done += 1);
                continue;
            }
            // Panic isolation: one project's ingest panicking (a
            // malformed file, an unexpected parser edge case, ...) must
            // not kill this whole background thread and leave every
            // *other* discovered project un-ingested with `running`
            // stuck `true` forever. `AssertUnwindSafe` is sound here —
            // `run_one_ingest` only ever touches `store`/`status` through
            // calls fully scoped to this one project; nothing is held
            // across the boundary for a caught panic to leave dangling.
            if let Err(payload) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                run_one_ingest(&store, name, dir, &status);
            })) {
                eprintln!(
                    "omniagent-ade: PANIC while ingesting project {name} (caught, bulk \
                     ingestion continues with the next project): {}",
                    crate::panic_message(&payload)
                );
                status.update(|s| {
                    s.projects_done += 1;
                    s.error = Some(format!("{name}: panicked during ingestion"));
                });
            }
        }

        status.end();
    });
}

/// [`add_project`]'s "return immediately, ingest invisibly after" half:
/// spawns a background thread (own `Store` connection, same reasoning as
/// [`ingest_roots_in_background`]) that ingests exactly one already-known
/// project directory. Updates the *same* shared [`IngestionState`] the bulk
/// onboarding/rebuild flows use — so the frontend's existing
/// `ingestion_status` poll picks this up for free, no second channel — via
/// the same [`IngestionState::begin`]/[`IngestionState::end`] pair
/// [`ingest_roots_in_background`] uses, so it composes safely (active-
/// worker counted, counters additive) if a bulk ingest happens to be
/// running at the same moment.
fn ingest_project_in_background(
    data_dir: PathBuf,
    name: String,
    dir: PathBuf,
    status: IngestionState,
) {
    std::thread::spawn(move || {
        let store = match Store::open(&data_dir) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("omniagent-ade: add_project background ingest failed to open store: {e}");
                return;
            }
        };

        status.begin(1);
        // Panic isolation, same reasoning as `ingest_roots_in_background`'s
        // loop: `status.end()` below must always run so `running` doesn't
        // get stuck `true` forever if the ingest itself panics.
        if let Err(payload) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run_one_ingest(&store, &name, &dir, &status);
        })) {
            eprintln!(
                "omniagent-ade: PANIC while ingesting project {name} (caught): {}",
                crate::panic_message(&payload)
            );
            status.update(|s| {
                s.projects_done += 1;
                s.error = Some(format!("{name}: panicked during ingestion"));
            });
        }
        status.end();
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

    ingest_roots_in_background(
        brain.data_dir.clone(),
        vec![path],
        Vec::new(),
        ingestion.inner().clone(),
    );
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
pub fn roots_biggest_project(
    brain: State<'_, BrainState>,
) -> Result<Option<ProjectSummary>, String> {
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

// ----------------------------------------------------------- add project
//
// Founder feedback, 2026-07-24 (Bruno, verbatim): "Open one terminal, and
// start from there. The overall graph is done always internally, not per
// folder. That means that the user can add multiple sessions within one
// project or add a new project (item on the left) with a new number of
// terminals / agents." Before this, the sidebar's project list came ENTIRELY
// from `list_projects()` — i.e. from nodes ingestion itself created — so a
// user could not add a project and get a terminal without first triggering
// and waiting on a full ingest. [`add_project`] fixes that: it upserts the
// `Project` node and records the path *synchronously* (so it's in the
// sidebar the instant this command returns), then kicks off [`ingest_one`]
// on a background thread and returns immediately — ingestion fills in the
// richer graph data invisibly afterward via the same upsert-by-id the rest
// of this module already relies on (a later `ingest_one` re-upsert is a
// no-op from the user's point of view: same id, richer `summary`/edges).
//
// Deliberately does NOT reuse [`discover_projects`]/[`add_root`]: those walk
// a ROOT folder's *immediate subdirectories* looking for many projects
// (Phase 8's bulk "point at a parent folder full of repos" onboarding flow,
// kept as-is here) — feeding `add_project`'s exact single project directory
// into that machinery would make it misread the project's own
// subdirectories as separate projects. [`PROJECT_PATHS_KEY`] is the small,
// parallel extension that keeps this project rediscoverable by "Rebuild
// brain" without conflating the two shapes.

/// Derives a project id from an optional user-supplied `name`, falling back
/// to `dir`'s folder basename — the same "the directory name is the project
/// name" convention [`discover_projects`]/[`ingest_one`] already use
/// elsewhere, so an added project ingests under one consistent id whether
/// it's named explicitly or left at its default.
fn project_id_for(dir: &Path, name: Option<&str>) -> Result<String> {
    if let Some(trimmed) = name.map(str::trim) {
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
    }
    dir.file_name()
        .and_then(|n| n.to_str())
        .map(str::to_string)
        .ok_or_else(|| anyhow::anyhow!("{} has no usable folder name", dir.display()))
}

/// The pure body behind [`add_project`] — takes plain `&BrainState`/
/// `&IngestionState` rather than Tauri's `State<'_, T>` so it's directly
/// unit-testable (this module's established split, e.g. [`rebuild_store`]
/// behind [`roots_rebuild`]).
fn add_project_impl(
    brain: &BrainState,
    ingestion: &IngestionState,
    path: &str,
    name: Option<&str>,
) -> Result<ProjectSummary> {
    let dir = PathBuf::from(path);
    if !dir.is_dir() {
        anyhow::bail!("{path} is not a directory");
    }
    let id = project_id_for(&dir, name)?;

    let summary = {
        let store = brain
            .store
            .lock()
            .map_err(|_| anyhow::anyhow!("brain store mutex poisoned"))?;
        store.upsert_node(&Node {
            id: id.clone(),
            kind: NodeKind::Project,
            project: id.clone(),
            label: id.clone(),
            path: Some(path.to_string()),
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        })?;
        add_project_path(&store, &id, path)?;
        ProjectSummary {
            id: id.clone(),
            label: id.clone(),
            path: Some(path.to_string()),
        }
    };

    // Not gated behind the same "ingestion already running" check
    // `roots_start_ingest`/`roots_rebuild` use: this ingest runs on its own
    // `Store` connection and updates `IngestionState` additively (see
    // `ingest_project_in_background`'s doc comment), so it composes safely
    // alongside a concurrent bulk run instead of needing exclusivity with it.
    ingest_project_in_background(brain.data_dir.clone(), id, dir, ingestion.clone());

    Ok(summary)
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

// -------------------------------------------------------------- rename

/// The pure body behind [`rename_project`] — same `&BrainState`-not-`State`
/// split every other command in this module uses for direct unit-testing.
fn rename_project_impl(brain: &BrainState, id: &str, new_label: &str) -> Result<()> {
    let trimmed = new_label.trim();
    if trimmed.is_empty() {
        anyhow::bail!("project name can't be empty");
    }
    let store = brain
        .store
        .lock()
        .map_err(|_| anyhow::anyhow!("brain store mutex poisoned"))?;
    let node = store
        .get_node(id)?
        .ok_or_else(|| anyhow::anyhow!("unknown project: {id}"))?;
    if node.kind != NodeKind::Project {
        anyhow::bail!("{id} is not a project");
    }
    store.set_setting(&mcp_server::tools::project_label_key(id), trimmed)?;
    Ok(())
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
pub fn roots_set_paused(
    project: String,
    paused: bool,
    brain: State<'_, BrainState>,
) -> Result<(), String> {
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
pub fn roots_rebuild(
    brain: State<'_, BrainState>,
    ingestion: State<'_, IngestionState>,
) -> Result<(), String> {
    if ingestion.snapshot().running {
        return Err("ingestion is already running".to_string());
    }

    let (roots, extra_projects) = {
        let mut guard = brain.store.lock().map_err(|e| e.to_string())?;
        let preserved: HashMap<String, String> = guard
            .all_settings()
            .map_err(|e| e.to_string())?
            .into_iter()
            .collect();
        let roots = get_roots(&guard).map_err(|e| e.to_string())?;
        // Individually-added projects (`add_project`) aren't under any
        // known root, so they'd otherwise vanish after a rebuild — carry
        // them forward explicitly. `preserved` already captured
        // `PROJECT_PATHS_KEY` above, so it survives into the fresh store
        // too; this is just what tells the background ingest to actually
        // re-ingest each of them.
        let extra_projects: Vec<(String, PathBuf)> = get_project_paths(&guard)
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(|(id, path)| (id, PathBuf::from(path)))
            .collect();
        let fresh = rebuild_store(&brain.data_dir, &preserved).map_err(|e| e.to_string())?;
        *guard = fresh;
        (roots, extra_projects)
    };

    ingest_roots_in_background(
        brain.data_dir.clone(),
        roots,
        extra_projects,
        ingestion.inner().clone(),
    );
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

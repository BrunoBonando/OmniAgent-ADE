//! Task 6a-2 — the Tauri-independent extraction of `src-tauri/src/roots.rs`'s
//! onboarding/ingestion/degradation orchestration (Task 8.1's original home),
//! so both the Tauri app **and** `omniagent-pty-daemon` can share one
//! implementation of the ingestion state machine and the
//! add/rename/pause/reingest/rebuild/staleness operations against the same
//! `brain_core::Store`, instead of the daemon re-deriving a second copy.
//!
//! This module owns no Tauri types (`tauri::State`, `#[tauri::command]`,
//! `crate::commands::BrainState`) — every function here takes a plain
//! `&Store`/`&Path` (locking/opening is the caller's job), matching this
//! crate's own `ingest_project`/`discover_projects` convention. Both
//! `src-tauri/src/roots.rs` (thin `#[tauri::command]` wrappers, one `Store`
//! guarded by a `std::sync::Mutex` per the Tauri app's own process) and
//! `omniagent-pty-daemon::server` (one dispatch arm per new `MessageKind`,
//! the same `Arc<std::sync::Mutex<Store>>` `GetSetting`/`BrainListProjects`
//! already share) call straight into these functions — see
//! `.superpowers/sdd/native-macos-migration/task-6a-2-report.md` for the
//! full routing table.
//!
//! ## Why some internals are `pub` despite being implementation details
//!
//! [`IngestionState::begin`]/[`IngestionState::end`]/[`IngestionState::update`]
//! are `pub` even though nothing outside this module's own background-thread
//! functions ([`ingest_roots_in_background`]) needs to call them in
//! production — `src-tauri/src/roots.rs`'s pre-existing test suite exercises
//! them directly (its own regression coverage for the "two ingestion
//! operations must compose additively" bug), and that test suite is the
//! non-regression guard this extraction must keep passing unchanged. Treat
//! them as "public for test parity," not as an invitation for a new caller
//! to hand-roll ingestion bookkeeping instead of going through
//! [`add_project`]/[`ingest_roots_in_background`]/[`rebuild`].

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::Result;
use brain_core::{now_ts, Node, NodeKind, Origin, Store};
use serde::Serialize;

use crate::{discover_projects, ingest_project, IngestStats};

pub const PROJECT_ROOTS_KEY: &str = "project_roots";
const PAUSE_PREFIX: &str = "ingest_paused:";
const LAST_INGESTED_PREFIX: &str = "last_ingested:";
/// Individually-added projects (Bruno's founder-feedback fast path, task
/// [`add_project`]): `{id: path}` JSON, distinct from [`PROJECT_ROOTS_KEY`]
/// because the two have different walk semantics — a "root" is a parent
/// folder [`discover_projects`] scans for *many* project subdirectories,
/// while an entry here is already one exact project directory that must be
/// re-ingested directly (via [`ingest_one`]), never walked. Read by
/// [`rebuild`] so a project added this way survives "Rebuild brain" instead
/// of silently vanishing because it isn't under any known root.
const PROJECT_PATHS_KEY: &str = "project_paths";

/// A project not (re)ingested by the app in this long is reported "stale" by
/// [`staleness`]. `ponytail:` a flat constant rather than a settings toggle —
/// tune once real dogfood usage says otherwise.
pub const STALE_THRESHOLD_SECS: i64 = 24 * 60 * 60;

// --------------------------------------------------------------- settings

pub fn get_roots(store: &Store) -> Result<Vec<String>> {
    let raw = store.get_setting(PROJECT_ROOTS_KEY)?;
    Ok(match raw {
        Some(s) => serde_json::from_str(&s).unwrap_or_default(),
        None => Vec::new(),
    })
}

pub fn add_root(store: &Store, path: &str) -> Result<()> {
    let mut roots = get_roots(store)?;
    if !roots.iter().any(|r| r == path) {
        roots.push(path.to_string());
        store.set_setting(PROJECT_ROOTS_KEY, &serde_json::to_string(&roots)?)?;
    }
    Ok(())
}

/// Every individually-added project (`add_project`), `id -> path`.
pub fn get_project_paths(store: &Store) -> Result<HashMap<String, String>> {
    let raw = store.get_setting(PROJECT_PATHS_KEY)?;
    Ok(match raw {
        Some(s) => serde_json::from_str(&s).unwrap_or_default(),
        None => HashMap::new(),
    })
}

/// Records (or overwrites, keyed by `id`) one individually-added project's
/// path so a future "Rebuild brain" knows to re-ingest it directly.
pub fn add_project_path(store: &Store, id: &str, path: &str) -> Result<()> {
    let mut paths = get_project_paths(store)?;
    paths.insert(id.to_string(), path.to_string());
    store.set_setting(PROJECT_PATHS_KEY, &serde_json::to_string(&paths)?)?;
    Ok(())
}

pub fn pause_key(project: &str) -> String {
    format!("{PAUSE_PREFIX}{project}")
}

pub fn is_paused(store: &Store, project: &str) -> bool {
    store
        .get_setting(&pause_key(project))
        .ok()
        .flatten()
        .as_deref()
        == Some("true")
}

pub fn last_ingested_key(project: &str) -> String {
    format!("{LAST_INGESTED_PREFIX}{project}")
}

/// Ingests one already-known project directory and stamps its
/// `last_ingested:<project>` setting on success. Shared by first-run
/// ingestion, "Rebuild brain", and the single-project "re-check" action —
/// one place that both does the ingest and records when it happened.
pub fn ingest_one(store: &Store, name: &str, dir: &Path) -> Result<IngestStats> {
    let stats = ingest_project(store, dir, name)?;
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
    /// How many independent ingestion operations ([`ingest_roots_in_background`]'s
    /// bulk root scans, [`ingest_project_in_background`]'s individual
    /// `add_project` ingests) are currently active. `running` is always
    /// *derived* from this being `> 0` (see [`IngestionState::begin`]/
    /// [`IngestionState::end`]) rather than being an independently-set bool —
    /// this is the fix for the bug where the two paths disagreed about who
    /// "owned" clearing it: one ingestion finishing can no longer
    /// incorrectly clear `running` while a different one is still in
    /// flight. Not part of the public snapshot contract the frontend polls
    /// (`ingestion_status`'s JSON shape is unchanged).
    #[serde(skip)]
    active_workers: usize,
}

/// `Arc<Mutex<..>>`-backed state, cloneable so a background
/// `std::thread::spawn` closure can hold its own handle without borrowing
/// from the caller's stack — the Tauri app manages one as app state
/// (`tauri::State`), the daemon constructs one at startup and clones it into
/// each connection handler; both share this exact same type.
#[derive(Clone)]
pub struct IngestionState(Arc<Mutex<IngestionStatus>>);

impl IngestionState {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(IngestionStatus::default())))
    }

    pub fn snapshot(&self) -> IngestionStatus {
        self.0
            .lock()
            .expect("ingestion status mutex poisoned")
            .clone()
    }

    pub fn update(&self, f: impl FnOnce(&mut IngestionStatus)) {
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
    pub fn begin(&self, additional_projects: usize) {
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
    pub fn end(&self) {
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
        eprintln!("omniagent brain-ingest: ingest of {name} failed: {e}");
        status.update(|s| s.error = Some(format!("{name}: {e}")));
    }
    let total_nodes = store.all_nodes().map(|n| n.len()).unwrap_or(0);
    status.update(|s| {
        s.projects_done += 1;
        s.total_nodes = total_nodes;
    });
}

/// Runs on a background thread (spawned by [`start_ingest`] / [`rebuild`]'s
/// callers): discovers projects under `roots` (skipping any already-known
/// project marked paused), adds `extra_projects` (already-known exact
/// project directories — [`add_project`]'s individually-tracked projects,
/// re-ingested on rebuild without being walked/rediscovered), and ingests
/// each in turn, updating `status` as it goes. Opens its own `Store`
/// connection rather than sharing the caller's — SQLite handles multiple
/// local connections to one `brain.db` fine at this write volume, and it
/// avoids threading a `'static` reference to the caller's state through
/// here.
pub fn ingest_roots_in_background(
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
            discovered.extend(discover_projects(Path::new(root)));
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
                let message = payload
                    .downcast_ref::<&str>()
                    .map(|s| s.to_string())
                    .or_else(|| payload.downcast_ref::<String>().cloned())
                    .unwrap_or_else(|| "unknown panic".to_string());
                eprintln!(
                    "omniagent brain-ingest: PANIC while ingesting project {name} (caught, \
                     bulk ingestion continues with the next project): {message}"
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
/// onboarding/rebuild flows use — so a poll of [`IngestionState::snapshot`]
/// picks this up for free, no second channel — via the same
/// [`IngestionState::begin`]/[`IngestionState::end`] pair
/// [`ingest_roots_in_background`] uses, so it composes safely
/// (active-worker counted, counters additive) if a bulk ingest happens to be
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
                eprintln!(
                    "omniagent brain-ingest: add_project background ingest failed to open \
                     store: {e}"
                );
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
            let message = payload
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic".to_string());
            eprintln!(
                "omniagent brain-ingest: PANIC while ingesting project {name} (caught): {message}"
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
pub fn start_ingest(
    data_dir: PathBuf,
    store: &Store,
    ingestion: &IngestionState,
    path: &str,
) -> Result<()> {
    let root = PathBuf::from(path);
    if !root.is_dir() {
        anyhow::bail!("{path} is not a directory");
    }
    if ingestion.snapshot().running {
        anyhow::bail!("ingestion is already running");
    }

    add_root(store, path)?;
    ingest_roots_in_background(data_dir, vec![path.to_string()], Vec::new(), ingestion.clone());
    Ok(())
}

/// The project with the most nodes in the store — Task 8.1's "offer a first
/// terminal tab on the project with the most files/entities." Mirrors the
/// `{id, label, path}` shape `mcp_server::tools::list_projects`/`ProjectInfo`
/// already use, so the same `sessionCreate`/`requestNewTab` flow can consume
/// it directly.
#[derive(Debug, Clone, Serialize)]
pub struct ProjectSummary {
    pub id: String,
    pub label: String,
    pub path: Option<String>,
}

pub fn biggest_project(store: &Store) -> Result<Option<ProjectSummary>> {
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
// `Project` node and records the path *synchronously* (so it's queryable the
// instant this function returns), then kicks off [`ingest_one`] on a
// background thread and returns immediately — ingestion fills in the richer
// graph data invisibly afterward via the same upsert-by-id the rest of this
// module already relies on (a later `ingest_one` re-upsert is a no-op from
// the caller's point of view: same id, richer `summary`/edges).
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

/// Adds exactly one project at `path` (Bruno's "open one terminal, and
/// start from there" — the sidebar's persistent "+"). `name` is the
/// optional user-edited display name/id (defaults to `path`'s folder
/// basename). Returns as soon as the `Project` node exists and is
/// queryable — never waits for ingestion, which continues on a background
/// thread.
pub fn add_project(
    store: &Store,
    data_dir: &Path,
    ingestion: &IngestionState,
    path: &str,
    name: Option<&str>,
) -> Result<ProjectSummary> {
    let dir = PathBuf::from(path);
    if !dir.is_dir() {
        anyhow::bail!("{path} is not a directory");
    }
    let id = project_id_for(&dir, name)?;

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
    add_project_path(store, &id, path)?;
    let summary = ProjectSummary {
        id: id.clone(),
        label: id.clone(),
        path: Some(path.to_string()),
    };

    // Not gated behind the "ingestion already running" check `start_ingest`/
    // `rebuild`'s callers use: this ingest runs on its own `Store`
    // connection and updates `IngestionState` additively (see
    // `ingest_project_in_background`'s doc comment), so it composes safely
    // alongside a concurrent bulk run instead of needing exclusivity with it.
    ingest_project_in_background(data_dir.to_path_buf(), id, dir, ingestion.clone());

    Ok(summary)
}

// -------------------------------------------------------------- rename

/// Renames a project's *display* label only — closes the root cause of a
/// project's sidebar/pane-header label defaulting to its folder basename
/// forever. `id`/`project` — the key every session/setting/cwd lookup
/// elsewhere actually uses — never changes; only what
/// `mcp_server::tools::list_projects` (and therefore `brain_query` / the
/// sidebar / every pane header) *displays* for it does, immediately,
/// everywhere that reads it. See `mcp_server::tools::project_label_key`'s
/// doc for why this writes to the settings table rather than the node's own
/// `label` column.
pub fn rename_project(store: &Store, id: &str, new_label: &str) -> Result<()> {
    let trimmed = new_label.trim();
    if trimmed.is_empty() {
        anyhow::bail!("project name can't be empty");
    }
    let node = store
        .get_node(id)?
        .ok_or_else(|| anyhow::anyhow!("unknown project: {id}"))?;
    if node.kind != NodeKind::Project {
        anyhow::bail!("{id} is not a project");
    }
    store.set_setting(&mcp_server::tools::project_label_key(id), trimmed)?;
    Ok(())
}

// -------------------------------------------------------- pause / staleness

/// Every project id currently marked paused (skipped by future
/// ingest/rebuild passes) — backs the sidebar context menu's checkbox
/// state.
pub fn paused_projects(store: &Store) -> Result<Vec<String>> {
    let settings = store.all_settings()?;
    Ok(settings
        .into_iter()
        .filter_map(|(k, v)| {
            (v == "true")
                .then(|| k.strip_prefix(PAUSE_PREFIX).map(str::to_string))
                .flatten()
        })
        .collect())
}

pub fn set_paused(store: &Store, project: &str, paused: bool) -> Result<()> {
    store.set_setting(&pause_key(project), if paused { "true" } else { "false" })?;
    Ok(())
}

/// One project's staleness reading — [`staleness`]'s response shape.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ProjectStaleness {
    pub project: String,
    pub last_ingested: Option<i64>,
    pub stale: bool,
}

pub fn staleness(store: &Store) -> Result<Vec<ProjectStaleness>> {
    let now = now_ts();
    let projects = store.list_projects()?;
    let mut out = Vec::with_capacity(projects.len());
    for p in projects {
        let last_ingested: Option<i64> = store
            .get_setting(&last_ingested_key(&p.project))?
            .and_then(|s| s.parse().ok());
        // Missing timestamp = never (re)ingested by this app version (e.g. a
        // project the `brain` CLI ingested before this ever ran) — not
        // stale: absence of evidence isn't evidence of staleness here.
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
pub fn reingest_project(store: &Store, project: &str) -> Result<()> {
    let node = store
        .get_node(project)?
        .ok_or_else(|| anyhow::anyhow!("unknown project: {project}"))?;
    let path = node
        .path
        .ok_or_else(|| anyhow::anyhow!("project {project} has no recorded path"))?;
    ingest_one(store, project, Path::new(&path))?;
    Ok(())
}

// -------------------------------------------------------------- rebuild

/// Deletes `brain.db` (+ WAL/SHM/journal siblings) under `data_dir` and
/// opens a fresh `Store`, replaying every `(key, value)` in `preserved` into
/// it. Safe to call while another `Store`/`Connection` still has the old
/// file open: `remove_file` is a POSIX `unlink`, which only removes the
/// directory entry — the old connection keeps working against the
/// (now-nameless) inode until it's dropped, and `Store::open` right after
/// creates a brand new file at the same path.
pub fn rebuild_store(data_dir: &Path, preserved: &HashMap<String, String>) -> Result<Store> {
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

/// "Rebuild brain": deletes `brain.db` (+ WAL/SHM/journal siblings) and
/// returns every persisted, non-paused root plus individually-added project
/// so the caller can re-ingest them from scratch (via
/// [`ingest_roots_in_background`], run *outside* whatever lock guards
/// `store_slot`, exactly as both the Tauri command and the daemon dispatch
/// arm do). Settings are captured before the delete and replayed into the
/// fresh database afterward — the point is wiping *derived graph data*, not
/// the user's roots/preferences. Never touches `brain/<project>/*.md`
/// memory: that directory lives entirely outside `brain.db` and nothing in
/// this function's path names or opens it.
///
/// `store_slot` is replaced in place (`*store_slot = fresh`) rather than
/// returned, so a caller holding e.g. a `MutexGuard<Store>` can swap the
/// store behind the lock without restructuring how it stores its `Store`.
pub fn rebuild(
    data_dir: &Path,
    store_slot: &mut Store,
) -> Result<(Vec<String>, Vec<(String, PathBuf)>)> {
    let preserved: HashMap<String, String> = store_slot.all_settings()?.into_iter().collect();
    let roots = get_roots(store_slot)?;
    // Individually-added projects (`add_project`) aren't under any known
    // root, so they'd otherwise vanish after a rebuild — carry them forward
    // explicitly. `preserved` already captured `PROJECT_PATHS_KEY` above, so
    // it survives into the fresh store too; this is just what tells the
    // background ingest to actually re-ingest each of them.
    let extra_projects: Vec<(String, PathBuf)> = get_project_paths(store_slot)?
        .into_iter()
        .map(|(id, path)| (id, PathBuf::from(path)))
        .collect();
    let fresh = rebuild_store(data_dir, &preserved)?;
    *store_slot = fresh;
    Ok((roots, extra_projects))
}

#[cfg(test)]
mod tests {
    use super::*;
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
    fn paused_projects_lists_only_ids_marked_true() {
        let store = Store::open_in_memory().unwrap();
        set_paused(&store, "p1", true).unwrap();
        set_paused(&store, "p2", false).unwrap();
        set_paused(&store, "p3", true).unwrap();

        let mut paused = paused_projects(&store).unwrap();
        paused.sort();
        assert_eq!(paused, vec!["p1".to_string(), "p3".to_string()]);
    }

    #[test]
    fn reingest_project_refreshes_the_stamp_for_a_known_project() {
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("fixtures/sample-project");
        let store = Store::open_in_memory().unwrap();
        store
            .upsert_node(&project_node("sample-project", &fixture))
            .unwrap();

        reingest_project(&store, "sample-project").unwrap();

        assert!(store
            .get_setting(&last_ingested_key("sample-project"))
            .unwrap()
            .is_some());
    }

    #[test]
    fn reingest_project_rejects_an_unknown_project() {
        let store = Store::open_in_memory().unwrap();
        let err = reingest_project(&store, "does-not-exist").unwrap_err();
        assert!(err.to_string().contains("unknown project"), "{err}");
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
        // this is exactly the situation the `rebuild`/daemon dispatch arm
        // is in: a `MutexGuard` still holds the old `Store` while this runs.
        let fresh = rebuild_store(dir.path(), &HashMap::new()).unwrap();
        assert!(fresh.get_node("p1").unwrap().is_none());

        // The old handle is still perfectly usable against its own
        // (unlinked-but-open) file — proves this doesn't corrupt anything
        // it's still holding.
        assert!(old_store.get_node("p1").unwrap().is_some());
    }

    #[test]
    fn rebuild_replaces_the_store_in_place_and_returns_roots_and_extra_projects_to_replay() {
        let dir = tempdir().unwrap();
        let mut store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&project_node("p1", Path::new("/tmp/p1")))
            .unwrap();
        add_root(&store, "/tmp/root-a").unwrap();
        add_project_path(&store, "standalone", "/tmp/standalone").unwrap();

        let (roots, extra_projects) = rebuild(dir.path(), &mut store).unwrap();

        assert_eq!(roots, vec!["/tmp/root-a".to_string()]);
        assert_eq!(
            extra_projects,
            vec![("standalone".to_string(), PathBuf::from("/tmp/standalone"))]
        );
        // `store` was swapped in place — the old extracted node is gone,
        // but the roots/project-paths settings (preserved) survive.
        assert!(store.get_node("p1").unwrap().is_none());
        assert_eq!(get_roots(&store).unwrap(), vec!["/tmp/root-a".to_string()]);
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
    /// old code this incorrectly reported `running: false` (re-enabling a
    /// second bulk/rebuild start while the `add_project` ingest was still
    /// actually running), and a bulk ingest starting mid-flight would
    /// destructively reset the other operation's counters.
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
        let store = Store::open(data_dir.path()).unwrap();
        let ingestion = IngestionState::new();

        let path = project_dir.path().to_string_lossy().into_owned();
        let summary = add_project(
            &store,
            data_dir.path(),
            &ingestion,
            &path,
            Some("My Project"),
        )
        .unwrap();

        assert_eq!(summary.id, "My Project");
        assert_eq!(summary.label, "My Project");
        assert_eq!(summary.path.as_deref(), Some(path.as_str()));

        // Queryable RIGHT AWAY — no waiting on ingestion.
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
        let store = Store::open(data_dir.path()).unwrap();
        let ingestion = IngestionState::new();

        let summary = add_project(
            &store,
            data_dir.path(),
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
        let store = Store::open(data_dir.path()).unwrap();
        let ingestion = IngestionState::new();

        let err = add_project(
            &store,
            data_dir.path(),
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

        let store = Store::open(data_dir.path()).unwrap();
        let ingestion = IngestionState::new();

        let started = std::time::Instant::now();
        let summary = add_project(
            &store,
            data_dir.path(),
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
    fn start_ingest_rejects_a_path_that_is_not_a_directory() {
        let data_dir = tempdir().unwrap();
        let store = Store::open_in_memory().unwrap();
        let ingestion = IngestionState::new();

        let err = start_ingest(
            data_dir.path().to_path_buf(),
            &store,
            &ingestion,
            "/definitely/not/a/real/path-xyz-nope",
        )
        .unwrap_err();
        assert!(err.to_string().contains("not a directory"), "{err}");
    }

    #[test]
    fn start_ingest_rejects_a_second_concurrent_run() {
        let data_dir = tempdir().unwrap();
        let project_root = tempdir().unwrap();
        let store = Store::open_in_memory().unwrap();
        let ingestion = IngestionState::new();
        ingestion.begin(1); // simulate an already-running ingestion

        let err = start_ingest(
            data_dir.path().to_path_buf(),
            &store,
            &ingestion,
            &project_root.path().to_string_lossy(),
        )
        .unwrap_err();
        assert!(err.to_string().contains("already running"), "{err}");
    }

    #[test]
    fn start_ingest_persists_the_root_and_kicks_off_ingestion() {
        let data_dir = tempdir().unwrap();
        // `start_ingest` treats `path` as a ROOT folder scanned for project
        // *subdirectories* (`discover_projects`'s semantics) — the actual
        // project must live one level down, not directly at `path` itself.
        let projects_root = tempdir().unwrap();
        let proj_dir = projects_root.path().join("demo-project");
        std::fs::create_dir_all(proj_dir.join(".git")).unwrap();
        std::fs::write(proj_dir.join("a.ts"), "export const a = 1;\n").unwrap();

        let store = Store::open(data_dir.path()).unwrap();
        let ingestion = IngestionState::new();

        start_ingest(
            data_dir.path().to_path_buf(),
            &store,
            &ingestion,
            &projects_root.path().to_string_lossy(),
        )
        .unwrap();

        assert_eq!(
            get_roots(&store).unwrap(),
            vec![projects_root.path().to_string_lossy().into_owned()]
        );

        let mut snap = ingestion.snapshot();
        for _ in 0..200 {
            if !snap.running && snap.projects_total > 0 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
            snap = ingestion.snapshot();
        }
        assert_eq!(snap.projects_done, 1);
    }

    #[test]
    fn rename_project_sets_the_label_override_and_list_projects_reflects_it() {
        let data_dir = tempdir().unwrap();
        let project_dir = tempdir().unwrap();
        let store = Store::open(data_dir.path()).unwrap();
        store
            .upsert_node(&project_node("OmniAgent-ADE", project_dir.path()))
            .unwrap();

        rename_project(&store, "OmniAgent-ADE", "OmniAgent").unwrap();

        // The node's own id/label columns are untouched — only the
        // settings-table override is written (see `rename_project`'s doc
        // for why: ingestion unconditionally resets the node's own label).
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
        let store = Store::open(data_dir.path()).unwrap();
        store
            .upsert_node(&project_node("OmniAgent-ADE", project_dir.path()))
            .unwrap();
        rename_project(&store, "OmniAgent-ADE", "OmniAgent").unwrap();

        // Simulate a re-ingest pass (`ingest_project`'s own unconditional
        // Project-node upsert) landing after the rename.
        store
            .upsert_node(&project_node("OmniAgent-ADE", project_dir.path()))
            .unwrap();

        let ctx = mcp_server::tools::ToolContext {
            store: &store,
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
        let store = Store::open(data_dir.path()).unwrap();
        store
            .upsert_node(&project_node("p1", project_dir.path()))
            .unwrap();

        let err = rename_project(&store, "p1", "   ").unwrap_err();
        assert!(err.to_string().contains("empty"), "{err}");
    }

    #[test]
    fn rename_project_rejects_an_unknown_project_id() {
        let data_dir = tempdir().unwrap();
        let store = Store::open(data_dir.path()).unwrap();

        let err = rename_project(&store, "does-not-exist", "New Name").unwrap_err();
        assert!(err.to_string().contains("unknown project"), "{err}");
    }
}

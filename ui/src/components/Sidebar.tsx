// Project list (Task 5.2): `brain_query{kind:"list_projects"}` -> brain-core
// Store::list_projects() directly, no daemon round trip. Renders a real,
// non-broken empty state when the brain has nothing ingested yet — the
// common case on a fresh dev run.
//
// Task 8.1 degradation surfaces added here: a "stale" dot on any project
// whose last (re)ingest is past the threshold, and the "⋯" context menu
// (pause-ingestion toggle + manual re-check) — see `ProjectMenu.tsx`.
//
// Founder feedback (Bruno, 2026-07-24, verbatim): "Open one terminal, and
// start from there... the user can add multiple sessions within one project
// or add a new project (item on the left)". Before this, the ONLY way a
// project appeared here was via ingestion (either the `brain` CLI or the
// FirstRun bulk-root picker) — the empty state literally told the user to
// run a CLI command and relaunch, which is the opposite of "start from
// there". The persistent "+" trigger below and the rewritten empty state
// are the fix. This does NOT replace the FirstRun bulk "point at a parent
// folder full of repos" flow (kept as-is, still reachable the same way it
// always was); it's a second, faster, single-project path that coexists
// with it.
//
// 2026-07-25: the "+" now opens `NewWorkspaceModal` (a BridgeSpace "New
// Workspace" dialog reference — see that component's own module doc),
// which REPLACED the original `AddProjectModal`. That modal only ever did
// "pick a folder, optionally rename it, call `add_project`"; the new one is
// a strict superset — the same folder-pick/rename step, PLUS choosing which
// engines to boot for the new project's first batch of sessions and how to
// arrange them — so there is no longer a reason to keep two overlapping
// "add a project" entry points in the sidebar. `add_project`
// (`src-tauri/src/roots.rs`) is still exactly what gets called; it still
// creates the sidebar row synchronously and ingests on a background
// thread — see that command's own doc comment for why.
//
// "Import projects from other tools" (founder ask, 2026-07-25, verbatim:
// "detect other dev tools already installed on the user's machine and
// offer to import their known project lists"): a SEPARATE, permanent
// header trigger next to "+" — not folded into `NewWorkspaceModal`. That
// modal creates exactly one project (plus its engines/layout); import
// bulk-creates however many candidates the user checks across up to three
// tools, with no engine/layout step at all, so it doesn't fit that dialog's
// shape without bolting tabs onto a recently-built, reference-matched
// component for a fundamentally different job. It's deliberately NOT
// first-run-only either (`FirstRun.tsx` also offers it, as an alternative
// to its folder-pick step) — a user might install a new tool well after
// their first launch and want to pull from it then, so this lives here,
// reachable any time, exactly like "+" itself.
//
// Attention badge (founder feedback, 2026-07-24 — Bruno, verbatim: "every
// claude session[...] can require attention, generate a badge"): a dot on
// `project-row-main` whenever any session in that project is waiting on the
// user, plus a smaller one on the specific pane row so it's clear which
// session. This is the "visible even if looking at a different project"
// half of the feature.
//
// **2026-07-26 — it is now derived from status, not latched.** It used to
// read `TabInfo.needsAttention`, a boolean set by a separate
// `session-attention:` event and cleared when the tab was clicked. That
// field is gone: the five-state light's `awaiting_approval`/`error` come
// from the same detection and mean the same thing, so the dot now asks
// `statusNeedsAttention(tab.status)` and is tinted with that state's own
// colour. One vocabulary, and a session that unblocks itself stops asking
// for the user immediately instead of holding a stale badge. See
// `state/sessions.ts`'s `TabInfo` doc for the whole reconciliation.
//
// ## Workspace -> session (founder brief, 2026-07-26)
//
// Bruno: *"Inside each workspace (first column) it must show the session
// it's currently on the screen."* A project's panes are no longer a flat
// list under the project row: they're grouped by session
// (`state/sessionGroups.ts`), and the one on screen wears the accent rail.
//
// "On screen" became literal later the same day, when `Workspace.tsx`
// started painting exactly one session's panes: the rail now reads
// `visibleSessionGroupId` — the *same* function the grid paints from — so
// the marked row and the visible panes are guaranteed to be the same
// session. It used to read `SessionGroup.isCurrent`, which only knows about
// the focused pane; selecting a workspace in the sidebar deliberately
// doesn't move focus, so that left a selected workspace showing a session
// with no row marked at all.
//
// **Later the same day, he cut the rest of it away:** *"The menu on the left
// should not show the amount of tabs and their names. Just the session, so
// it's cleaner. Session and current github branch. On hover, it shows full
// details."* Three things left this file in that pass:
//
// - the per-project **tab count** badge (`.project-row-count`);
// - the per-session **"N panes · Claude Code, Shell"** meta line;
// - the nested **list of every terminal** in every session.
//
// What a session row shows now is `SidebarSessionRow`'s whole job: its live
// light, its name (double-click to rename), and the git branch of its own
// root. Everything that was cut is one hover away, in the card that row
// opens — which is also where the card moved *from* the pane header.
//
// ## Closing a workspace (same brief: "add the possibility to close a
// ## workspace, on hover")
//
// The `×` beside the row's other hover controls. It ends every terminal in
// the workspace and takes the row out of the list — and nothing else: see
// `state/closedWorkspaces.ts` for the full "this is a window close, not a
// delete" reasoning, and `CloseWorkspaceConfirm` for what the user is told
// before anything is killed.
import { useCallback, useEffect, useState, type CSSProperties } from "react";
import logo from "../assets/omniagent-logo.png";
import {
  PRESSURE_THRESHOLD,
  isUnderPressure,
  tabsByProject,
  type Engine,
  type ProjectInfo,
  type TabInfo,
} from "../state/sessions";
import { groupTabsBySession, visibleSessionGroupId } from "../state/sessionGroups";
import { statusNeedsAttention } from "../state/sessionStatus";
import { idColor } from "../state/projectColors";
import Icon from "./Icon";
import type { LayoutPreset } from "../state/paneGrid";
import {
  rootsPausedProjects,
  rootsReingestProject,
  rootsSetPaused,
  rootsStaleness,
  type IngestionStatus,
  type ProjectStaleness,
} from "../lib/tauri";
import AboutPanel from "./AboutPanel";
import ReviewPanel from "./ReviewPanel";
import ProjectMenu from "./ProjectMenu";
import NewWorkspaceModal from "./NewWorkspaceModal";
import ImportProjectsFlow from "./ImportProjectsFlow";
import SidebarSessionRow from "./SidebarSessionRow";
import CloseWorkspaceConfirm from "./CloseWorkspaceConfirm";
import CloseSessionConfirm from "./CloseSessionConfirm";
import type { SessionGroup } from "../state/sessionGroups";
import AccountBadge from "./AccountBadge";
import type { ImportBatchResult } from "../state/importState";
import type { AgentsState, Agent } from "../state/agents";

/** How often to refresh pause/staleness state in the background — cheap
 * settings/`list_projects` reads, not worth a live push mechanism for v1. */
const DEGRADATION_POLL_MS = 20000;

interface SidebarProps {
  projects: ProjectInfo[];
  tabs: TabInfo[];
  activeTabId: string | null;
  selectedProjectId: string | null;
  onSelectProject: (project: ProjectInfo) => void;
  onNewTabInProject: (project: ProjectInfo) => void;
  onActivateTab: (id: string) => void;
  /** The "+" New Workspace flow: called the instant `add_project` returns
   * (well before ingestion finishes) with the freshly-created project, the
   * engines the user checked (ENGINES order, always >= 1), and the LAYOUT
   * preset chosen for arranging their sessions — `App.tsx` owns the actual
   * bulk `session_create` orchestration and closes the modal. */
  onWorkspaceCreated: (project: ProjectInfo, engines: Engine[], layout: LayoutPreset) => void;
  /** Whether the New Workspace modal is open — lifted to `App.tsx` (unlike
   * this component's other overlays, e.g. `aboutOpen`/`reviewOpen`/
   * `importOpen` below, which stay local) so ⌘N (founder ask: "Command + N
   * opens a new workspace") can open it from the global keydown handler in
   * `App.tsx`, the same place ⌘T/⌘K already live. */
  newWorkspaceOpen: boolean;
  onOpenNewWorkspace: () => void;
  onCloseNewWorkspace: () => void;
  /** `ProjectMenu`'s rename (founder ask: closing the root cause of a
   * project's label defaulting to its folder basename forever) —
   * `App.tsx` owns the actual `rename_project` Tauri call + reloading
   * `state.projects` afterward (see `ProjectMenu.tsx`'s own module doc). */
  onRenameProject: (project: ProjectInfo, newLabel: string) => void;
  /** The "Import projects" trigger's finished batch — `App.tsx`'s
   * `handleImportCompleted` reloads the project list and shows an
   * error-banner summary for any failures; this component just closes its
   * own overlay first (see the module doc above for why import is a
   * separate entry point from `onWorkspaceCreated`). */
  onImportCompleted: (result: ImportBatchResult) => void;
  /** Owned centrally by `App.tsx` (already polling every ~2s for the
   * degradation badges / FirstRun / BrainMap) and simply forwarded here —
   * backs the small "ingesting…" indicator next to the wordmark, the reuse
   * of that existing poll loop this task asked for rather than a second
   * one. Optional so this component still type-checks for tests that don't
   * care about it. */
  ingestion?: IngestionStatus | null;
  /** Task 6.2: the workspace/map view toggle. Optional so this component
   * still type-checks for any test that doesn't care about it. */
  view?: "workspace" | "map";
  onSetView?: (view: "workspace" | "map") => void;
  /** Founder feedback, 2026-07-25: the file tree panel's show/hide toggle
   * (`App.tsx` owns the persisted state — see `FILE_TREE_VISIBLE_SETTING_KEY`).
   * Optional, same reasoning as `view`/`onSetView` above, so tests that
   * don't care about the file tree don't need to pass it. */
  fileTreeVisible?: boolean;
  onToggleFileTree?: () => void;
  /** "+ New session" under a project's session list — opens
   * `NewSessionModal` for that project (⌘N -> Session reaches the same
   * dialog). Optional, same convention as the props above. */
  onNewSessionInProject?: (project: ProjectInfo) => void;
  /** A session's double-click rename. `App.tsx` owns the dispatch
   * (`session/renamed`), which writes the name onto every pane in the group
   * and persists it with the layout — this component owns only the inline
   * edit UI, the same split `onRenameProject`/`ProjectMenu` uses. */
  onRenameSession?: (project: ProjectInfo, group: string, name: string) => void;
  /** The hover-revealed workspace close. Called only after
   * `CloseWorkspaceConfirm` is accepted — `App.tsx` kills the terminals and
   * drops the row (see `state/closedWorkspaces.ts`). */
  onCloseWorkspace?: (project: ProjectInfo) => void;
  /** The session row's hover-revealed close (founder ask: "I must be able
   * to close a session"). Called only after `CloseSessionConfirm` is
   * accepted — `App.tsx` kills that session's terminals; the workspace row
   * stays. */
  onCloseSession?: (project: ProjectInfo, sessionId: string) => void;
  authSignedIn: string | null;
  authPersona: string | null;
  onResetAuthGate: () => void;
  agentState: AgentsState;
  onInstallAgent: (agent: Agent) => void;
}

export default function Sidebar({
  projects,
  tabs,
  activeTabId,
  selectedProjectId,
  onSelectProject,
  onNewTabInProject,
  onActivateTab,
  onWorkspaceCreated,
  newWorkspaceOpen,
  onOpenNewWorkspace,
  onCloseNewWorkspace,
  onRenameProject,
  onImportCompleted,
  ingestion,
  view = "workspace",
  onSetView,
  fileTreeVisible = false,
  onToggleFileTree,
  onNewSessionInProject,
  onRenameSession,
  onCloseWorkspace,
  onCloseSession,
  authSignedIn,
  authPersona,
  onResetAuthGate,
  agentState,
  onInstallAgent,
}: SidebarProps) {
  const [aboutOpen, setAboutOpen] = useState(false);
  const [reviewOpen, setReviewOpen] = useState(false);
  const [importOpen, setImportOpen] = useState(false);
  /** The workspace whose close is waiting on a confirmation, if any. */
  const [closingProject, setClosingProject] = useState<ProjectInfo | null>(null);
  /** The session whose close is waiting on a confirmation, if any. */
  const [closingSession, setClosingSession] = useState<{
    project: ProjectInfo;
    session: SessionGroup;
  } | null>(null);
  const grouped = tabsByProject(tabs);
  const sessionsByProject = groupTabsBySession(tabs, activeTabId);
  // Which session the pane grid is showing for the selected workspace — the
  // accent rail's answer, taken from the same derivation `Workspace.tsx`
  // paints from so the two columns always agree (see `SidebarSessionRow`'s
  // `isCurrent` prop).
  const onScreenSession =
    selectedProjectId === null ? null : visibleSessionGroupId(tabs, selectedProjectId, activeTabId);
  // Founder feedback (2026-07-24): a session's attention badge must stay
  // visible from the sidebar even while looking at a different project's
  // tabs, or the Map view — this is the whole reason the badge lives at two
  // levels (this per-project one, and the per-pane row below), not just on
  // the pane itself. Derived from the live status since 2026-07-26 (see the
  // module doc), so it can never disagree with the pane's own light.
  const attentionByProject = new Map(
    grouped.map((g) => [g.project, g.tabs.some((t) => statusNeedsAttention(t.status))]),
  );
  const underPressure = isUnderPressure(tabs);
  // Warp-direction reskin: the session-pressure capsule meter's fill —
  // derived from the exact same `tabs.length`/`PRESSURE_THRESHOLD` pair the
  // plain-text badge already used, just also expressed as a 0-100 percent
  // for the bar (capped at 100 so an over-threshold count doesn't overflow
  // the track).
  const sessionPressurePct = Math.min(100, Math.round((tabs.length / PRESSURE_THRESHOLD) * 100));

  const [pausedProjects, setPausedProjects] = useState<Set<string>>(new Set());
  const [staleness, setStaleness] = useState<Map<string, ProjectStaleness>>(new Map());
  const [menuProjectId, setMenuProjectId] = useState<string | null>(null);
  const [menuBusy, setMenuBusy] = useState(false);

  const reloadDegradationState = useCallback(() => {
    rootsPausedProjects()
      .then((ids) => setPausedProjects(new Set(ids)))
      .catch((err) => console.error("roots_paused_projects failed", err));
    rootsStaleness()
      .then((rows) => setStaleness(new Map(rows.map((r) => [r.project, r]))))
      .catch((err) => console.error("roots_staleness failed", err));
  }, []);

  useEffect(() => {
    reloadDegradationState();
    const interval = window.setInterval(reloadDegradationState, DEGRADATION_POLL_MS);
    return () => window.clearInterval(interval);
  }, [reloadDegradationState]);

  const togglePause = useCallback(
    async (project: ProjectInfo) => {
      setMenuBusy(true);
      try {
        await rootsSetPaused(project.id, !pausedProjects.has(project.id));
        reloadDegradationState();
      } catch (err) {
        console.error(`roots_set_paused(${project.id}) failed`, err);
      } finally {
        setMenuBusy(false);
      }
    },
    [pausedProjects, reloadDegradationState],
  );

  const reingest = useCallback(
    async (project: ProjectInfo) => {
      setMenuBusy(true);
      try {
        await rootsReingestProject(project.id);
        reloadDegradationState();
      } catch (err) {
        console.error(`roots_reingest_project(${project.id}) failed`, err);
      } finally {
        setMenuBusy(false);
        setMenuProjectId(null);
      }
    },
    [reloadDegradationState],
  );

  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        <span className="sidebar-wordmark">OMNIAGENT</span>
        <div className="sidebar-header-actions">
          {ingestion?.running && (
            <span
              className="sidebar-ingesting"
              role="status"
              title={`Ingesting${ingestion.current_project ? ` ${ingestion.current_project}` : ""}… runs in the background, terminals stay usable.`}
            >
              <span className="sidebar-ingesting-dot" aria-hidden="true" />
              ingesting
            </span>
          )}
          <button
            className="sidebar-add-project-trigger"
            onClick={onOpenNewWorkspace}
            aria-label="New workspace"
            title="New workspace"
          >
            +
          </button>
          <button
            className="sidebar-import-trigger"
            onClick={() => setImportOpen(true)}
            aria-label="Import projects from other tools"
            title="Import projects from other tools"
          >
            import
          </button>
          {onToggleFileTree && (
            <button
              className={`sidebar-filetree-trigger${fileTreeVisible ? " is-active" : ""}`}
              onClick={onToggleFileTree}
              aria-label="Toggle file browser panel"
              aria-pressed={fileTreeVisible}
              title="Toggle file browser panel"
            >
              files
            </button>
          )}
          <span
            className={`pressure-badge${underPressure ? " is-hot" : ""}`}
            title={`${tabs.length} live session${tabs.length === 1 ? "" : "s"} (pressure badge past ${PRESSURE_THRESHOLD})`}
          >
            {/* Warp-direction reskin: the same session-count this badge
                already showed as plain digits, now ALSO a capsule meter
                (Warp's "Session 17%"-style bar) — no new metric, just the
                existing `tabs.length`/`PRESSURE_THRESHOLD` fraction drawn
                as a fill instead of only text. */}
            <span className="meter-track">
              <span
                className={`meter-fill${underPressure ? " is-hot" : sessionPressurePct >= 60 ? " is-warm" : ""}`}
                style={{ "--pct": sessionPressurePct } as CSSProperties}
              />
            </span>
            {tabs.length}/{PRESSURE_THRESHOLD}
          </span>
        </div>
      </div>

      <div className="sidebar-view-toggle" role="tablist" aria-label="View">
        <button
          role="tab"
          aria-selected={view === "workspace"}
          className={view === "workspace" ? "is-active" : ""}
          onClick={() => onSetView?.("workspace")}
          title="Terminal workspace"
        >
          &gt;_ Workspace
        </button>
        <button
          role="tab"
          aria-selected={view === "map"}
          className={view === "map" ? "is-active" : ""}
          onClick={() => onSetView?.("map")}
          title="Brain map"
        >
          &#10022; Map
        </button>
      </div>

      <div className="sidebar-projects">
        {projects.length === 0 ? (
          <div className="sidebar-empty">
            <img src={logo} alt="" className="sidebar-empty-logo" />
            <p className="sidebar-empty-title">No projects yet</p>
            <p className="sidebar-empty-hint">
              Add a project folder to open your first terminal — ingestion happens quietly in the
              background.
            </p>
            <button className="sidebar-empty-cta" onClick={onOpenNewWorkspace}>
              + New Workspace
            </button>
          </div>
        ) : (
          <ul className="project-list">
            {projects.map((project) => {
              const sessions = sessionsByProject.find((p) => p.project === project.id)?.sessions ?? [];
              const isSelected = project.id === selectedProjectId;
              const isPaused = pausedProjects.has(project.id);
              const isStale = staleness.get(project.id)?.stale ?? false;
              const hasAttention = attentionByProject.get(project.id) ?? false;
              return (
                <li key={project.id} className={`project-row${isSelected ? " is-selected" : ""}`}>
                  <button
                    className="project-row-main"
                    onClick={() => onSelectProject(project)}
                    title={project.path ?? project.id}
                  >
                    {/* Grouped so `.project-row-main`'s `justify-content:
                        space-between` only ever splits "identity" from
                        "meta badges" into two blocks — without this wrapper
                        every child (dot, avatar, label, paused, count)
                        would get spread evenly across the row instead,
                        pulling the avatar away from its own label. */}
                    <span className="project-row-identity">
                      {hasAttention && (
                        <span
                          className="project-row-attention-dot"
                          role="status"
                          title="A session in this project needs your attention"
                        />
                      )}
                      {isStale && <span className="project-row-stale-dot" title="Stale — hasn't been re-ingested in a while" />}
                      <span
                        className="project-row-avatar"
                        aria-hidden="true"
                        style={{ background: idColor(project.id) }}
                      >
                        {project.label.charAt(0).toUpperCase()}
                      </span>
                      <span className="project-row-label">{project.label}</span>
                    </span>
                    {isPaused && <span className="project-row-paused">paused</span>}
                  </button>
                  {/* The row's hover controls, as one cluster that fades in
                      OVER the end of the label rather than a strip the label
                      is permanently shortened to make room for — a workspace
                      called "OmniAgent-ADE" should read as its own name at
                      rest, which reserving space for three buttons made
                      impossible. */}
                  <span className="project-row-actions">
                    <button
                      className="project-row-add"
                      onClick={() => onNewTabInProject(project)}
                      aria-label={`New terminal in ${project.label}`}
                      title="New terminal (⌘T)"
                    >
                      <Icon name="plus" size={14} />
                    </button>
                    <button
                      className="project-row-menu-trigger"
                      onClick={() => setMenuProjectId(project.id)}
                      aria-label={`${project.label} options`}
                      title="Pause / re-check"
                    >
                      <Icon name="more" size={14} />
                    </button>
                    {/* Founder ask: "add the possibility to close a
                        workspace, on hover" — last in the cluster, because
                        that is where a close lives in every window and tab
                        this app sits beside. Confirms first: it ends live
                        engines. */}
                    {onCloseWorkspace && (
                      <button
                        className="project-row-close"
                        onClick={() => setClosingProject(project)}
                        aria-label={`Close workspace ${project.label}`}
                        title="Close workspace"
                      >
                        <Icon name="x" size={13} />
                      </button>
                    )}
                  </span>
                  {menuProjectId === project.id && (
                    <ProjectMenu
                      project={project}
                      paused={isPaused}
                      staleness={staleness.get(project.id)}
                      busy={menuBusy}
                      onTogglePause={() => void togglePause(project)}
                      onReingest={() => void reingest(project)}
                      onRename={(newLabel) => onRenameProject(project, newLabel)}
                      onClose={() => setMenuProjectId(null)}
                    />
                  )}
                  {/* Workspace -> session. One row per session: its light,
                      its name and its branch, and nothing else (see this
                      file's module doc for what was cut and where it went).
                      The session holding the focused pane wears the accent
                      rail — the founder's "it must show the session it's
                      currently on the screen", now carried by the row's own
                      styling rather than by a text tag beside it. */}
                  {sessions.length > 0 && (
                    <ul className="project-row-sessions">
                      {sessions.map((session) => (
                        <SidebarSessionRow
                          key={session.id}
                          session={session}
                          projectLabel={project.label}
                          tint={idColor(session.id)}
                          // The rail marks what the grid is actually
                          // painting, answered by the same function the grid
                          // asks (`visibleSessionGroupId`) — so "the session
                          // it's currently on the screen" means the same
                          // thing in both columns. Only the selected
                          // workspace has a session on screen at all.
                          isCurrent={isSelected && session.id === onScreenSession}
                          onActivate={() => onActivateTab(session.tabs[0].id)}
                          onRename={(name) => onRenameSession?.(project, session.id, name)}
                          onClose={
                            onCloseSession ? () => setClosingSession({ project, session }) : undefined
                          }
                        />
                      ))}
                      {isSelected && onNewSessionInProject && (
                        <li>
                          <button
                            className="project-row-new-session"
                            onClick={() => onNewSessionInProject(project)}
                            title="New session in this project (⌘N)"
                          >
                            + New session
                          </button>
                        </li>
                      )}
                    </ul>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </div>

      <div className="sidebar-footer">
        <AccountBadge
          signedInRaw={authSignedIn}
          personaRaw={authPersona}
          onResetAuthGate={onResetAuthGate}
          onOpenReview={() => setReviewOpen(true)}
          onOpenAbout={() => setAboutOpen(true)}
        />
      </div>

      {aboutOpen && <AboutPanel onClose={() => setAboutOpen(false)} />}
      {reviewOpen && <ReviewPanel onClose={() => setReviewOpen(false)} />}
      {newWorkspaceOpen && (
        <NewWorkspaceModal
          onCreate={(project, engines, layout) => {
            onCloseNewWorkspace();
            onWorkspaceCreated(project, engines, layout);
          }}
          onClose={onCloseNewWorkspace}
          agentState={agentState}
          onInstallAgent={onInstallAgent}
        />
      )}
      {importOpen && (
        <ImportProjectsFlow
          existingProjects={projects}
          onImported={(result) => {
            setImportOpen(false);
            onImportCompleted(result);
          }}
          onClose={() => setImportOpen(false)}
        />
      )}
      {closingSession && (
        <CloseSessionConfirm
          label={closingSession.session.label}
          terminals={closingSession.session.tabs.length}
          onConfirm={() => {
            const { project, session } = closingSession;
            setClosingSession(null);
            onCloseSession?.(project, session.id);
          }}
          onCancel={() => setClosingSession(null)}
        />
      )}
      {closingProject && (
        <CloseWorkspaceConfirm
          label={closingProject.label}
          terminals={grouped.find((g) => g.project === closingProject.id)?.tabs.length ?? 0}
          sessions={
            sessionsByProject.find((p) => p.project === closingProject.id)?.sessions.length ?? 0
          }
          onConfirm={() => {
            const project = closingProject;
            setClosingProject(null);
            onCloseWorkspace?.(project);
          }}
          onCancel={() => setClosingProject(null)}
        />
      )}
    </aside>
  );
}

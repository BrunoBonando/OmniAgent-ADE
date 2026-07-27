// The left pane. **Since the 2026-07-27 redesign (Task 3) it shows exactly
// one workspace**: the `WorkspaceSwitcher` at the top names it, `WorkspaceMenu`
// (the dropdown that switcher opens) is how you reach every other one, and
// everything below the switcher belongs to that single selected workspace.
//
// What that replaced, and where each piece went, because the history below
// was all written against the old shape — a `.project-list` of one row per
// open project, each with its own nested session list:
//
// - the per-project rows -> `WorkspaceMenu`'s rows (name, path, session
//   count, a checkmark on the active one);
// - the header's "+" (new workspace) and "import" triggers -> that same
//   menu's two footer items;
// - a row's "⋯" -> the same menu row's "⋯", which still opens `ProjectMenu`
//   (pause / re-check / rename) — now anchored under the switcher rather
//   than under a row, since there is no row left to hang it on;
// - a row's hover "×" -> `ProjectMenu`'s "Close workspace" item, still
//   confirming through `CloseWorkspaceConfirm` before anything is killed;
// - a row's hover "+" (new terminal) -> Task 5's "New terminal" row inside
//   the session, via the new `onOpenNewTerminal` prop;
// - the session-pressure badge and the per-project attention dot were cut:
//   the first is not in the design, and the second answered a question ("a
//   session in *another* project needs you") that a single-workspace sidebar
//   can no longer ask — the per-session lights inside `SidebarSessionRow`
//   and the notification centre in `AppChrome` still answer it.
//
// Everything below is the original file history, kept because it is why the
// surviving pieces are shaped the way they are.
//
// Project list (Task 5.2): `brain_query{kind:"list_projects"}` -> brain-core
// Store::list_projects() directly, no daemon round trip.
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
import { useCallback, useEffect, useState } from "react";
import { tabsByProject, type Engine, type ProjectInfo, type TabInfo } from "../state/sessions";
import { groupTabsBySession, visibleSessionGroupId } from "../state/sessionGroups";
import { idColor } from "../state/projectColors";
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
import { WorkspaceSwitcher } from "./WorkspaceSwitcher";
import { WorkspaceMenu } from "./WorkspaceMenu";
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
  /** Open a terminal in an arbitrary project. Its trigger — the project
   * row's hover "+" — went away with the row list (Task 3); the sidebar now
   * only ever opens terminals in the *selected* workspace, which is
   * `onOpenNewTerminal` below. Kept because `App.tsx` still passes it and
   * the two are different questions (any project vs. this one). */
  onNewTabInProject: (project: ProjectInfo) => void;
  /** "New terminal" in the selected workspace — `App.tsx` wires it to the
   * same `requestNewTab(selectedProject)` ⌘T runs. Rendered as the current
   * session's "New terminal" row (Task 5); Task 9 swaps App's handler for a
   * modal without this file changing at all. */
  onOpenNewTerminal: () => void;
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
   * degradation badges / FirstRun / BrainMap) and simply forwarded here — it
   * backed the small "ingesting…" indicator next to the wordmark, which went
   * away with the header (Task 3). Still passed and still wanted: Task 8
   * re-homes it as the account row's "Brain indexed · 8m ago" sub-line.
   * Optional so this component still type-checks for tests that don't care
   * about it. */
  ingestion?: IngestionStatus | null;
  /** Task 6.2: the workspace/map view toggle. Optional so this component
   * still type-checks for any test that doesn't care about it. */
  view?: "workspace" | "map";
  onSetView?: (view: "workspace" | "map") => void;
  /** Founder feedback, 2026-07-25: the file tree panel's show/hide toggle
   * (`App.tsx` owns the persisted state — see `FILE_TREE_VISIBLE_SETTING_KEY`).
   * Its "files" button lived in the sidebar header, which Task 3 removed;
   * Task 6 pulls the tree itself into this panel as the FILES section and
   * deletes both of these props with the right-hand dock. Kept until then so
   * `App.tsx` keeps type-checking unchanged. */
  fileTreeVisible?: boolean;
  onToggleFileTree?: () => void;
  /** The SESSIONS header's "+" — opens `NewSessionModal` for the selected
   * workspace (⌘N -> Session reaches the same dialog). Optional, same
   * convention as the props above. */
  onNewSessionInProject?: (project: ProjectInfo) => void;
  /** A session's double-click rename. `App.tsx` owns the dispatch
   * (`session/renamed`), which writes the name onto every pane in the group
   * and persists it with the layout — this component owns only the inline
   * edit UI, the same split `onRenameProject`/`ProjectMenu` uses. */
  onRenameSession?: (project: ProjectInfo, group: string, name: string) => void;
  /** The workspace close, now `ProjectMenu`'s last item (it was the project
   * row's hover "×" before Task 3). Called only after
   * `CloseWorkspaceConfirm` is accepted — `App.tsx` kills the terminals and
   * drops the workspace (see `state/closedWorkspaces.ts`). */
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

// `onNewTabInProject`, `ingestion`, `fileTreeVisible` and `onToggleFileTree`
// are deliberately NOT destructured: they are live props `App.tsx` passes,
// whose render sites either moved out of this file (Task 3) or haven't been
// built yet (Tasks 6/8) — see each one's doc on `SidebarProps`. Leaving them
// out of the signature is what keeps `noUnusedLocals` honest without
// dropping the prop itself.
export default function Sidebar({
  projects,
  tabs,
  activeTabId,
  selectedProjectId,
  onSelectProject,
  onActivateTab,
  onWorkspaceCreated,
  newWorkspaceOpen,
  onOpenNewWorkspace,
  onCloseNewWorkspace,
  onRenameProject,
  onImportCompleted,
  view = "workspace",
  onSetView,
  onNewSessionInProject,
  onRenameSession,
  onCloseWorkspace,
  onCloseSession,
  onOpenNewTerminal,
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
  /** Which sessions the user has manually expanded (Task 4 redesign,
   * 2026-07-27) — the terminal list under a session row is otherwise closed
   * by default. Keyed by session id rather than a single "the expanded one"
   * value because nothing stops more than one session's list being open at
   * once. Starts empty: `session.isCurrent` (see the per-row `expanded`
   * below) already opens the session holding the focused pane without this
   * set knowing about it. */
  const [expandedSessions, setExpandedSessions] = useState<Set<string>>(new Set());
  const toggleSession = useCallback((id: string) => {
    setExpandedSessions((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);
  const grouped = tabsByProject(tabs);
  const sessionsByProject = groupTabsBySession(tabs, activeTabId);
  // Which session the pane grid is showing for the selected workspace — the
  // accent rail's answer, taken from the same derivation `Workspace.tsx`
  // paints from so the two columns always agree (see `SidebarSessionRow`'s
  // `isCurrent` prop).
  const onScreenSession =
    selectedProjectId === null ? null : visibleSessionGroupId(tabs, selectedProjectId, activeTabId);
  // The one workspace this panel is about (Task 3). `null` is a real state —
  // no projects at all, or a selection pointing at a workspace that was just
  // closed — and the switcher renders its own "No workspace" copy for it.
  const selectedProject = projects.find((p) => p.id === selectedProjectId) ?? null;
  // Only the selected workspace's sessions are listed now; the others are a
  // click away in the dropdown, which is where their session *counts* go.
  const selectedSessions =
    sessionsByProject.find((p) => p.project === selectedProjectId)?.sessions ?? [];
  const sessionCounts = new Map(sessionsByProject.map((p) => [p.project, p.sessions.length]));

  const [pausedProjects, setPausedProjects] = useState<Set<string>>(new Set());
  const [staleness, setStaleness] = useState<Map<string, ProjectStaleness>>(new Map());
  /** Whether the workspace dropdown is open under the switcher. */
  const [menuOpen, setMenuOpen] = useState(false);
  const [menuProjectId, setMenuProjectId] = useState<string | null>(null);
  const [menuBusy, setMenuBusy] = useState(false);
  // `ProjectMenu` is opened from a dropdown row's "⋯", so it is about
  // whichever workspace that row named — not necessarily the selected one.
  // Resolved from the live list so a workspace closing underneath the open
  // menu takes the menu with it rather than leaving a stale panel.
  const menuProject = projects.find((p) => p.id === menuProjectId) ?? null;

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
      {/* The switcher and both popovers it can raise share one relatively
          positioned anchor: `.workspace-menu` and `.project-menu` are both
          absolutely placed, and the project menu no longer has a project row
          to hang off (see the module doc). */}
      <div className="sidebar-switcher-anchor">
        <WorkspaceSwitcher
          project={selectedProject}
          open={menuOpen}
          onToggle={() => setMenuOpen((open) => !open)}
        />
        {menuOpen && (
          <WorkspaceMenu
            projects={projects}
            activeProjectId={selectedProjectId}
            sessionCounts={sessionCounts}
            onSelect={onSelectProject}
            onNewWorkspace={onOpenNewWorkspace}
            onImport={() => setImportOpen(true)}
            // The dropdown closes as the project menu opens: they are
            // stacked over the same button, and `.project-menu`'s z-index
            // sits below `.workspace-menu`'s — two popovers deep is noise
            // even if the layering were solvable.
            onManage={(project) => {
              setMenuOpen(false);
              setMenuProjectId(project.id);
            }}
            onClose={() => setMenuOpen(false)}
          />
        )}
        {menuProject && (
          <ProjectMenu
            project={menuProject}
            paused={pausedProjects.has(menuProject.id)}
            staleness={staleness.get(menuProject.id)}
            busy={menuBusy}
            onTogglePause={() => void togglePause(menuProject)}
            onReingest={() => void reingest(menuProject)}
            onRename={(newLabel) => onRenameProject(menuProject, newLabel)}
            onCloseWorkspace={
              onCloseWorkspace
                ? () => {
                    setMenuProjectId(null);
                    setClosingProject(menuProject);
                  }
                : undefined
            }
            onClose={() => setMenuProjectId(null)}
          />
        )}
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

      {/* One workspace, so one flat list of ITS sessions — the nesting
          (project -> sessions) went away with the project rows. The count
          beside the label is what the dropdown shows per workspace, said
          once more for the one on screen. */}
      <div className="sidebar-sessions-header">
        <span className="sidebar-microlabel">SESSIONS</span>
        <span className="sidebar-microcount">{selectedSessions.length}</span>
        <span className="sidebar-spacer" />
        <button
          className="sidebar-sessions-add"
          aria-label="New session"
          title="New session (⌘N)"
          onClick={() => selectedProject && onNewSessionInProject?.(selectedProject)}
        >
          +
        </button>
      </div>

      <ul className="sidebar-session-list">
        {selectedProject &&
          selectedSessions.map((session) => {
            // What the rail marks: the session the grid is actually
            // painting, answered by the same function the grid asks
            // (`visibleSessionGroupId`) — so "the session it's currently on
            // the screen" means the same thing in both columns. Computed
            // once and reused below for `expanded`'s default (fix-round,
            // 2026-07-27: that used to read `session.isCurrent` — the
            // *different* "holds the focused pane" question `SessionGroup`
            // itself answers — which could auto-expand a session other than
            // the one this same row was visually marking as current, since
            // selecting a workspace doesn't move focus. Confirmed with the
            // founder: the row should auto-expand exactly the session its
            // own accent bar marks, so this reuses that one computation
            // rather than asking the question twice with two different
            // answers.)
            const isCurrent = session.id === onScreenSession;
            return (
              <SidebarSessionRow
                key={session.id}
                session={session}
                projectLabel={selectedProject.label}
                tint={idColor(session.id)}
                isCurrent={isCurrent}
                expanded={isCurrent || expandedSessions.has(session.id)}
                activeTabId={activeTabId}
                onActivate={() => onActivateTab(session.tabs[0].id)}
                onToggleExpanded={() => toggleSession(session.id)}
                onActivateTab={onActivateTab}
                onRename={(name) => onRenameSession?.(selectedProject, session.id, name)}
                onClose={
                  onCloseSession
                    ? () => setClosingSession({ project: selectedProject, session })
                    : undefined
                }
                onOpenNewTerminal={onOpenNewTerminal}
              />
            );
          })}
      </ul>

      {/* FILES section arrives in Task 6, between the sessions and the
          account footer. */}

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

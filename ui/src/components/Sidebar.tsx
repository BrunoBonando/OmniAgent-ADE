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
// "pick a folder, optionally rename it, call `add_project`"; the new one
// picks a folder, shows what is in it (`folder_stats`), and takes the two
// folder-level toggles (ingest now / review notes) — so there is no longer
// a reason to keep two overlapping "add a project" entry points in the
// sidebar. (It used to also choose engines and a layout; Task 12 moved
// that to `NewSessionModal`, which `App` opens right after.) `add_project`
// (`src-tauri/src/roots.rs`) is still exactly what gets called; it still
// creates the sidebar row synchronously and ingests on a background
// thread — see that command's own doc comment for why.
//
// "Import projects from other tools" (founder ask, 2026-07-25, verbatim:
// "detect other dev tools already installed on the user's machine and
// offer to import their known project lists"): a SEPARATE, permanent
// header trigger next to "+" — not folded into `NewWorkspaceModal`. That
// modal creates exactly one project, and shows that one folder's stats;
// import bulk-creates however many candidates the user checks across up to
// three tools, with nothing to show per folder, so it doesn't fit that
// dialog's shape without bolting tabs onto a recently-built,
// reference-matched component for a different job. It's deliberately NOT
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
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { tabsByProject, type ProjectInfo, type TabInfo } from "../state/sessions";
import { groupTabsBySession, visibleSessionGroupId } from "../state/sessionGroups";
import {
  rootsPausedProjects,
  rootsReingestProject,
  rootsSetPaused,
  rootsStaleness,
  type IngestionStatus,
  type ProjectStaleness,
} from "../lib/tauri";
import { useReviewStatus } from "../lib/useReviewStatus";
import { buildGitBadges } from "../state/fileGitStatus";
import AboutPanel from "./AboutPanel";
import ReviewPanel from "./ReviewPanel";
import ProjectMenu from "./ProjectMenu";
import { WorkspaceSwitcher } from "./WorkspaceSwitcher";
import { WorkspaceMenu } from "./WorkspaceMenu";
import NewWorkspaceModal from "./NewWorkspaceModal";
import ImportProjectsFlow from "./ImportProjectsFlow";
import CloseWorkspaceConfirm from "./CloseWorkspaceConfirm";
import CloseSessionConfirm from "./CloseSessionConfirm";
import FileTree from "./FileTree";
import type { SessionGroup } from "../state/sessionGroups";
import AccountBadge from "./AccountBadge";
import Icon from "./Icon";
import { brainLine } from "../state/accountBadgeState";
import type { ImportBatchResult } from "../state/importState";

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
  /** "New terminal" in the selected workspace. Rendered as the current
   * session's "New terminal" row (Task 5). Task 9: `App.tsx` used to wire
   * this to the same direct `requestNewTab(selectedProject)` call ⌘T ran;
   * both now instead open `NewTerminalModal` (`setNewTerminalOpen(true)`) —
   * the modal itself calls `requestNewTab` on confirm. This file didn't
   * need to change either way. */
  onOpenNewTerminal: () => void;
  onActivateTab: (id: string) => void;
  /** The "+" New Workspace flow: called the instant `add_project` returns
   * (well before ingestion finishes) with the freshly-created project.
   *
   * No engines/layout any more (Task 12): adding a workspace no longer
   * starts terminals. `App.tsx` selects the new workspace and opens
   * `NewSessionModal`, which is where engines and layout are chosen. */
  onWorkspaceCreated: (project: ProjectInfo) => void;
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
   * re-homes it as the account row's "Brain indexed · 8m ago" sub-line (see
   * `lastIndexedAt` below, and `state/accountBadgeState.ts`'s `brainLine`).
   * Optional so this component still type-checks for tests that don't care
   * about it. */
  ingestion?: IngestionStatus | null;
  /** Dashboard surfaces toggle (Dashboard / Terminals / Board / Files / Map).
   * Optional so this component still type-checks for tests that don't care
   * about view switching. */
  view?: "dashboard" | "workspace" | "board" | "files" | "map";
  onSetView?: (view: "dashboard" | "workspace" | "board" | "files" | "map") => void;
  /** Opens a file in the dashboard Files screen. */
  onOpenFile?: (path: string) => void;
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
  dormantSessions?: DormantSession[];
  onSelectDormantSession?: (session: DormantSession) => void;
}

export interface DormantSession {
  project: string;
  group: string;
  label: string;
  cwd: string;
  paneCount: number;
}

// `onNewTabInProject` is deliberately NOT destructured: it's a live prop
// `App.tsx` passes whose render site moved out of this file (Task 3) — see
// its own doc on `SidebarProps`. Leaving it out of the signature is what
// keeps `noUnusedLocals` honest without dropping the prop itself.
// (`fileTreeVisible`/`onToggleFileTree` used to be here too — Task 6 removed
// both from `SidebarProps` entirely along with the right-hand dock they
// toggled; the tree they used to show/hide is now always-embedded below, in
// `.sidebar-files`. `ingestion` was the third — Task 8 below is what finally
// destructures and uses it.)
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
  ingestion,
  view = "dashboard",
  onSetView,
  onCloseWorkspace,
  onCloseSession,
  authSignedIn,
  authPersona,
  onResetAuthGate,
  dormantSessions = [],
  onSelectDormantSession,
  onOpenFile,
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
   * 2026-07-27) — the terminal list under a session row is closed by
   * default so the left pane stays focused on working sessions, not terminal
   * names. Keyed by session id rather than a single "the expanded one"
   * value because nothing stops more than one session's list being open at
   * once. */
  const [fileFilter, setFileFilter] = useState("");
  // Task 8: session-local memory of the last clean ingest completion, feeding
  // the account row's "Brain indexed · Xm ago" sub-line (`brainLine` below).
  // Nothing on the backend remembers this across a relaunch, so a rising
  // edge on `ingestion.running` true -> false with no `error` just stamps
  // `Date.now()` here — `wasIngestingRef` is what lets the effect tell a
  // fresh "still running" render apart from an actual completion.
  // ponytail: lastIndexedAt is session-local, resets on relaunch to "Nothing
  // indexed yet" until the first ingest completes; persist via settingsSet
  // if it matters.
  const [lastIndexedAt, setLastIndexedAt] = useState<number | null>(null);
  const wasIngestingRef = useRef(false);
  useEffect(() => {
    const running = ingestion?.running ?? false;
    if (wasIngestingRef.current && !running && !ingestion?.error) {
      setLastIndexedAt(Date.now());
    }
    wasIngestingRef.current = running;
  }, [ingestion]);
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
  // Task 7: the FILES section's live git badges — polled for the selected
  // workspace's root and folded into per-file/per-dir lookups keyed by
  // absolute path (`buildGitBadges`'s own doc), which is exactly what
  // `FileTree` rows carry.
  const review = useReviewStatus(selectedProject?.path ?? null);
  const gitBadges = useMemo(() => buildGitBadges(review), [review]);
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

  // Nav card counts and subtitles for the view toggle.
  const allProjectTabs = selectedSessions.flatMap((s) => s.tabs);
  const awaitingCount = allProjectTabs.filter((t) => t.status === "awaiting_approval").length;
  const fileCount = gitBadges.total;
  const totalSessionCount = selectedSessions.length + dormantSessions.length;
  const gitDiffSummary = review
    ? `${review.file_count} file${review.file_count !== 1 ? "s" : ""} · +${review.added} -${review.removed}`
    : "Git diff unavailable";

  function statusLetter(status: "modified" | "added" | "deleted" | "renamed" | "untracked"): string {
    switch (status) {
      case "modified":
        return "M";
      case "added":
      case "untracked":
        return "A";
      case "deleted":
        return "D";
      case "renamed":
        return "R";
      default:
        return "?";
    }
  }

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
          aria-selected={view === "dashboard"}
          className={view === "dashboard" ? "is-active" : ""}
          onClick={() => onSetView?.("dashboard")}
          title="Dashboard"
        >
          <div className="sidebar-nav-icon-box">
            <Icon name="chart" size={16} />
          </div>
          <div className="sidebar-nav-text">
            <span className="sidebar-nav-title">Dashboard</span>
            <span className="sidebar-nav-subtitle">activity, tokens, approvals</span>
          </div>
          {awaitingCount > 0 && <span className="sidebar-nav-count">{awaitingCount}</span>}
        </button>
        <button
          role="tab"
          aria-selected={view === "board"}
          className={view === "board" ? "is-active" : ""}
          onClick={() => onSetView?.("board")}
          title="Plan board"
        >
          <div className="sidebar-nav-icon-box">
            <Icon name="sparkle" size={16} />
          </div>
          <div className="sidebar-nav-text">
            <span className="sidebar-nav-title">Plan board</span>
            <span className="sidebar-nav-subtitle">backlog, sprint, timeline</span>
          </div>
        </button>
        <div className="sidebar-workspace-tab-group">
          <button
            role="tab"
            aria-selected={view === "workspace"}
            className={view === "workspace" ? "is-active" : ""}
            onClick={() => onSetView?.("workspace")}
            title="Working sessions"
          >
            <div className="sidebar-nav-icon-box">
              <Icon name="terminal" size={16} />
            </div>
            <div className="sidebar-nav-text">
              <span className="sidebar-nav-title">Working sessions</span>
            </div>
            {totalSessionCount > 0 && <span className="sidebar-nav-count">{totalSessionCount}</span>}
          </button>
          <div className="sidebar-sessions-inline">
            <ul className="sidebar-inline-session-list">
              {dormantSessions.map((dormant) => (
                <li key={dormant.group} className="sidebar-inline-session-row">
                  <button
                    className="sidebar-inline-session-name-btn"
                    onClick={() => onSelectDormantSession?.(dormant)}
                  >
                    {dormant.label}
                  </button>
                </li>
              ))}
              {selectedProject &&
                selectedSessions.map((session) => {
                  const isCurrent = session.id === onScreenSession;
                  return (
                    <li
                      key={session.id}
                      className={`sidebar-inline-session-row${isCurrent ? " is-current" : ""}`}
                    >
                      <button
                        className="sidebar-inline-session-name-btn"
                        onClick={() => onActivateTab(session.tabs[0].id)}
                        aria-label={session.label}
                      >
                        {session.label}
                      </button>
                      {onCloseSession && (
                        <button
                          className="sidebar-inline-session-close-btn"
                          aria-label={`Close session ${session.label}`}
                          title="Close session"
                          onClick={() => setClosingSession({ project: selectedProject, session })}
                        >
                          <Icon name="x" size={11} />
                        </button>
                      )}
                    </li>
                  );
                })}
            </ul>
          </div>
        </div>
        <button
          role="tab"
          aria-selected={view === "files"}
          className={view === "files" ? "is-active" : ""}
          onClick={() => onSetView?.("files")}
          title="Files editor"
        >
          <div className="sidebar-nav-icon-box">
            <Icon name="folder" size={16} />
          </div>
          <div className="sidebar-nav-text">
            <span className="sidebar-nav-title">Files</span>
          </div>
          {fileCount > 0 && <span className="sidebar-nav-count">{fileCount}</span>}
        </button>
      </div>

      {/* redesign: FILES section (Task 6) — the tree that used to be a
          separate right-hand dock (`FileTree.tsx`, `App.tsx`'s old
          `fileTreeVisible` conditional render) is now embedded here, below
          the sessions and above the account footer. `embedded` drops its
          resize handle/dock header; `filter` is this component's own local
          `fileFilter` state, never lifted — see that state's own doc. */}
      <div className="sidebar-files">
        <div className="sidebar-files-header">
          <span className="sidebar-microlabel">FILES</span>
          <span className="sidebar-spacer" />
          {gitBadges.total > 0 && (
            <span className="sidebar-files-changed">
              {gitBadges.total}
              <span> changed</span>
            </span>
          )}
        </div>
        <div className="sidebar-files-diff" role="note" aria-label="Git diff summary">
          <div className="sidebar-files-diff-summary">{gitDiffSummary}</div>
          {review && review.files.length > 0 ? (
            <ul className="sidebar-files-diff-list">
              {review.files.slice(0, 6).map((f) => (
                <li key={`${f.path}-${f.status}`} className="sidebar-files-diff-item">
                  <span className={`file-tree-git-letter is-${f.status}`}>{statusLetter(f.status)}</span>
                  <span className="sidebar-files-diff-path">{f.path}</span>
                </li>
              ))}
            </ul>
          ) : (
            <div className="sidebar-files-diff-empty">No changed files</div>
          )}
        </div>
        <div className="sidebar-files-filter-wrap">
          <svg width="11" height="11" viewBox="0 0 16 16" fill="none" aria-hidden="true">
            <circle cx="7" cy="7" r="4.3" stroke="currentColor" strokeWidth="1.3" />
            <path d="m10.4 10.4 3 3" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          </svg>
          <input
            className="sidebar-files-filter"
            placeholder="Filter files"
            value={fileFilter}
            onChange={(e) => setFileFilter(e.target.value)}
          />
        </div>
        <div className="sidebar-files-body">
          <FileTree
            project={selectedProject}
            activeTabId={activeTabId}
            onClose={() => {}}
            embedded
            filter={fileFilter}
            gitBadges={gitBadges}
            onOpenFile={(path) => {
              onOpenFile?.(path);
              onSetView?.("files");
            }}
          />
        </div>
      </div>

      <div className="sidebar-footer">
        <AccountBadge
          signedInRaw={authSignedIn}
          personaRaw={authPersona}
          onResetAuthGate={onResetAuthGate}
          onOpenReview={() => setReviewOpen(true)}
          onOpenAbout={() => setAboutOpen(true)}
          brainLine={brainLine(ingestion ?? null, lastIndexedAt, Date.now())}
        />
      </div>

      {aboutOpen && <AboutPanel onClose={() => setAboutOpen(false)} />}
      {reviewOpen && <ReviewPanel onClose={() => setReviewOpen(false)} />}
      {newWorkspaceOpen && (
        <NewWorkspaceModal
          onCreate={(project) => {
            onCloseNewWorkspace();
            onWorkspaceCreated(project);
          }}
          onClose={onCloseNewWorkspace}
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

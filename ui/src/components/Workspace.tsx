// The terminal workspace: a per-project, resizable/draggable grid of panes
// (BridgeSpace pane-grid rebuild — founder feedback, 2026-07-25: "multiple
// tabs, new tabs must open like this [screenshot]... each terminal must be
// draggable and have more information." See docs/DESIGN.md and the
// reference screenshot at docs/reference/bridgespace-pane-grid-reference.png
// for the full brief). Replaces the old single-tab-visible-at-a-time
// `TabBar` strip: every session open in the *selected* project now renders
// simultaneously as a pane in a `react-mosaic-component` grid (chosen over
// react-grid-layout — see the commit message / task report for why: it's
// purpose-built for exactly this IDE-style tiling-with-splits interaction,
// where react-grid-layout is a more generic drag/resize grid with no
// built-in concept of a directional split).
//
// ## The mount-stability rule, and how this file actually satisfies it
//
// Every `<Terminal>` for a live session must stay mounted for the session's
// whole lifetime — `sessions.rs` only streams `session-output:{id}` Tauri
// events to whoever is currently subscribed, so unmounting and re-mounting
// later silently drops output (see `Terminal.tsx`'s own module doc).
//
// **Cross-project switching** is handled the same way `App.tsx` already
// keeps `<Workspace>` and `<BrainMap>` both mounted and toggles only which
// one is visible: `<ProjectPaneGrid>` renders once per project that has any
// open tab, *every* one of them stays mounted for as long as that project
// has open tabs, and only the CSS `display` of the *non-selected* ones
// toggles off. Switching the sidebar's selected project never
// unmounts/remounts anything.
//
// **An earlier version of this file instead used a single grid plus
// `ReactDOM.createPortal`** to move each session's `<Terminal>` between a
// "currently visible" pane and an always-mounted off-screen host when its
// project wasn't selected. That turned out to not work: a hand-written
// experiment (kept as a note here, not shipped) proved `createPortal` does
// **not** preserve a child's React identity across a container change —
// even with a matching `key` argument, changing *which* DOM node a portal
// targets remounts its children. Since portals bought nothing over
// rendering `<Terminal>` directly inside `renderTile`, and cost real
// complexity (a ref-callback cache, an off-screen host div, a manual
// render-count "tick" to notice when refs attach), they were removed.
//
// **Opening/closing panes within one session's grid** is bounded rather than
// free: react-mosaic-component's own `MosaicRoot` keys intermediate split
// nodes by tree *path* (see that library's `MosaicRoot.tsx`), so a leaf whose
// enclosing split changes gets discarded and remounted by React — no portal
// indirection changes that. Since the founder's approved-shape ladder
// (`paneGrid.ts`'s `GRID_LADDER`) re-lays the grid out whenever the pane count
// crosses a rung, the panes that move to a different ROW on such a reflow do
// remount: their xterm starts empty, while tmux keeps the session alive and
// repaints the visible screen on the resize the reflow itself causes. Adds
// and closes *within* one rung keep every full row's path, so they cost at
// most the one pane that was alone on the last row. Exactly which edits cost
// what is pinned down against the real library in
// `Workspace.mountStability.test.tsx`.
//
// **Dragging a pane** can no longer create a new split at all: react-mosaic's
// edge drops are off (`draggable={false}` below) because they build shapes
// the ladder would never produce, and dragging a header now only *swaps* two
// panes (`swapPaneIds`). A swap within a row remounts nothing; a swap across
// rows still remounts both panes, for the same path-keying reason — which is
// why `Terminal.tsx` nudges its PTY size on mount, so tmux repaints a pane
// that traded places with an equally sized one.
//
// ## The grid shows ONE session (founder brief, 2026-07-26)
//
// Bruno, verbatim: *"Inside each workspace (first column) it must show the
// session it's currently on the screen."* The sidebar half of that shipped
// first and this file was explicitly left behind — every pane in a project
// stayed on screen at once, sessions being only an organizing layer in the
// tree. This is the other half.
//
// **The unit of the grid is now a SESSION, not a project.** One
// `<ProjectPaneGrid>` per (project, session) that has any open pane; all of
// them stay mounted for as long as their session has panes; `display`
// toggles off every one that isn't the selected project's current session
// (`visibleSessionGroupId`, state/sessionGroups.ts).
//
// That is deliberately the *same* mechanism the cross-project case above
// already used, applied one level down, and for the identical reason: the
// obvious implementation — render only the current session's panes — is
// exactly the unmount that drops `session-output:{id}` on the floor. A
// session the user isn't looking at is still a live agent doing work, and
// switching away from it must cost nothing but a repaint.
//
// A pleasant consequence: each session's panes get their own mosaic tree, so
// a session's shape is its own and one session's drag-rearrange can't move
// another's.
import { useCallback, useEffect, useMemo, useState } from "react";
import { Mosaic, MosaicWindow, type MosaicNode } from "react-mosaic-component";
import "react-mosaic-component/react-mosaic-component.css";
import EmptyWorkspace from "./EmptyWorkspace";
import PaneHeader from "./PaneHeader";
import Icon from "./Icon";
import Terminal from "./Terminal";
import { isPaneHole, paneIds, swapPaneIds, syncPaneTree, type LayoutPreset, type PaneTree } from "../state/paneGrid";
import { tabDisplayLabel, type Engine, type ProjectInfo, type TabInfo } from "../state/sessions";
import { groupTabsBySession, visibleSessionGroupId } from "../state/sessionGroups";
import { approveKeystroke, denyKeystroke } from "../state/notifications";
import { statusPresentation } from "../state/sessionStatus";
import type { TerminalThemeId } from "../lib/terminalThemes";
import { ownsCtrlOnlyShortcut } from "../lib/keyboard";
import type { AgentsState } from "../state/agents";

/**
 * Keeps a pane drag away from react-dnd's window-level HTML5 backend, which
 * `<Mosaic>` installs (its own `DndProvider`) and which is hostile to any
 * drag it didn't start — verified against react-dnd 16's
 * `HTML5BackendImpl`, all three of these on `window`'s BUBBLE phase, so a
 * `stopPropagation` from React's root container is enough to never reach
 * them:
 *
 * - `dragstart` ends with *"if by this time no drag source reacted, tell
 *   browser not to drag"* → `preventDefault()`, i.e. the drag never starts.
 * - `dragover` sets `dropEffect = "none"` whenever its own monitor isn't
 *   dragging, i.e. the browser refuses the drop and never fires `drop`.
 * - `drop` calls `actions.hover()` unconditionally, which throws
 *   `Invariant Violation: Cannot call hover while not dragging`.
 *
 * The backend's *capture*-phase handlers still run (nothing can stop those
 * from application code) and are all harmless for a foreign drag: they clear
 * their own bookkeeping, and the `application/x-ade-pane` MIME the drag
 * carries matches none of react-dnd's "native item" types, so it never
 * adopts the drag as a file/text/URL one.
 */
function stopBeforeReactDnd(e: React.DragEvent) {
  e.stopPropagation();
}

interface ProjectPaneGridProps {
  hidden: boolean;
  /** Real, combined visibility for every `<Terminal>` this grid renders:
   * true only when this grid is both the selected project's AND the
   * overall Workspace view (not the Map view) is the active one. Threaded
   * through as its own prop (rather than derived from `hidden` alone)
   * because `hidden` here only ever reflects "not the selected project" —
   * see the `visible`-prop bug this fixes in the module doc's cross-
   * reference from `Terminal.tsx`. */
  terminalsVisible: boolean;
  projectId: string;
  /** The session (pane group) whose panes this grid holds — `TabInfo.group`,
   * or `UNGROUPED_SESSION_ID`. Surfaced on the DOM node as `data-session` so
   * the mount-stability tests (and a browser harness) can point at one
   * specific session's grid and read whether it is displayed. */
  sessionId: string;
  projectLabel: string;
  tabs: TabInfo[];
  activeTabId: string | null;
  projects: ProjectInfo[];
  onActivateTab: (id: string) => void;
  onCloseTab: (id: string) => void;
  onNewTabInProject: (project: ProjectInfo) => void;
  onRenameTab: (id: string, label: string) => void;
  /** PaneHeader's 3-dot "Change engine": kill this pane's live session and
   * respawn a new one with a different engine, same pane/slot — the actual
   * kill+respawn lives in `App.tsx`'s `restartTabWithEngine`. */
  onChangeEngine: (tab: TabInfo, engine: Engine) => void;
  /** PaneHeader's 3-dot "Terminal theme" picker. */
  onChangeTheme: (id: string, themeId: TerminalThemeId) => void;
  /** PaneHeader's 3-dot "Code review": opens the right-hand review column
   * for this pane's session (founder ask, 2026-07-26 — "Make sure that the
   * code panel is for session, okay?"). `App.tsx` owns which session the
   * column is currently targeting. */
  onOpenCodeReview: (tab: TabInfo) => void;
  /** Awaiting-approval footer actions in this pane. */
  onResolveApproval: (tab: TabInfo, decision: "approve" | "deny") => void;
  /** Engine-generated title forwarded straight through to each pane's
   * `<Terminal>` (see that component's own doc). */
  onEngineTitle: (id: string, title: string) => void;
  agentState: AgentsState;
}

/** One **session's** grid — always mounted for as long as that session has
 * any open pane (see this file's module doc for why), CSS-hidden via
 * `hidden` when it isn't the selected project's current session. */
function ProjectPaneGrid({
  hidden,
  terminalsVisible,
  projectId,
  sessionId,
  projectLabel,
  tabs,
  activeTabId,
  projects,
  onActivateTab,
  onCloseTab,
  onNewTabInProject,
  onRenameTab,
  onChangeEngine,
  onChangeTheme,
  onOpenCodeReview,
  onResolveApproval,
  onEngineTitle,
  agentState,
}: ProjectPaneGridProps) {
  const [tree, setTree] = useState<PaneTree | null>(null);
  const idsKey = tabs.map((t) => t.id).join(" ");
  // Pane drag-to-swap (founder ask, 2026-07-26: "Make dragged terminal able
  // to exchange places with another terminal... while dragging I see the
  // square being highlighted"). `from` is the pane being dragged, `over` the
  // pane currently under the cursor — the one that lights up and that the
  // drop trades places with. Null between drags.
  const [drag, setDrag] = useState<{ from: string; over: string | null } | null>(null);

  // The whole reconciliation: this session's open panes in, their approved
  // grid out (`syncPaneTree` -> `buildGrid`, paneGrid.ts). No layout hint from
  // the create dialogs is needed or wanted — the shape is a pure function of
  // the pane count, so a bulk-created batch of 4 lands in the same 2x2 that
  // opening a 4th terminal by hand produces.
  useEffect(() => {
    const ids = idsKey.length > 0 ? idsKey.split(" ") : [];
    setTree((prev) => syncPaneTree(prev, ids));
  }, [idsKey]);

  const tabsById = useMemo(() => new Map(tabs.map((t) => [t.id, t])), [tabs]);
  const sessionLabel = useMemo(
    () => tabs.find((t) => t.groupLabel && t.groupLabel.trim().length > 0)?.groupLabel?.trim() ?? null,
    [tabs],
  );

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!ownsCtrlOnlyShortcut(event) || event.key !== "Tab" || hidden) return;
      const ids = paneIds(tree);
      if (ids.length < 2) return;
      event.preventDefault();
      event.stopPropagation();
      onActivateTab(ids[(Math.max(ids.indexOf(activeTabId ?? ""), 0) + 1) % ids.length]);
    };
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, [activeTabId, hidden, onActivateTab, tree]);

  return (
    <div
      className="pane-grid-project"
      data-project={projectId}
      data-session={sessionId}
      style={{ display: hidden ? "none" : "flex" }}
    >
      {tree === null ? (
        <div className="empty-workspace">
          <div className="empty-workspace-prompt"><Icon name="terminal" size={28} strokeWidth={1.7} /></div>
          <p>No terminal open.</p>
          <p className="empty-workspace-hint">⌘T to start one in {projectLabel}.</p>
        </div>
      ) : (
        <Mosaic<string>
          className="pane-grid"
          value={tree}
          onChange={(next: MosaicNode<string> | null) => setTree(next as PaneTree | null)}
          renderTile={(id, path) => {
            // A cell no open session claims (`buildGrid`'s padding, paneGrid.ts) —
            // the empty-workspace gradient sized to this one cell, carrying an
            // "Add Terminal" button (founder, 2026-07-26: "on the blank space...
            // a small square button with an image of a terminal and a text
            // under saying: add Terminal"). Clicking it is exactly the pane
            // header's split: one more terminal in this session, which lands
            // in this very cell (`buildGrid` fills the hole first).
            if (isPaneHole(id)) {
              const project = projects.find((p) => p.id === projectId);
              return (
                <div className="pane-hole">
                  {project && (
                    <button
                      type="button"
                      className="pane-hole-add"
                      onClick={() => onNewTabInProject(project)}
                    >
                      <span className="pane-hole-add-glyph" aria-hidden>
                        &gt;_
                      </span>
                      Add Terminal
                    </button>
                  )}
                </div>
              );
            }
            const tab = tabsById.get(id);
            if (!tab) return <div />; // transient desync (closed mid-reconcile) — next sync clears it
            const terminalIndex = tabs.findIndex((t) => t.id === tab.id) + 1;
            const awaitingApproval = tab.status === "awaiting_approval";
            const canApprove = approveKeystroke(tab.engine) !== null;
            const canDeny = denyKeystroke(tab.engine) !== null;
            // The pane border is the session's status display (founder,
            // 2026-07-26: "remove it from there [the title bar] and leave
            // only in the border") — the same statusPresentation pair the
            // sidebar light carries, as classes because className is the one
            // channel MosaicWindow forwards. App.css's pane-status-border
            // block turns them into the five colours and rhythms.
            const status = statusPresentation(tab.status);
            return (
              <MosaicWindow<string>
                path={path}
                title={tabDisplayLabel(tab)}
                className={`pane-window pane-status-${status.key} pane-motion-${status.motion}${
                  tab.id === activeTabId ? " is-focused" : ""
                }`}
                // react-mosaic's own header drag is off: it only ever offered
                // edge drops, which build a brand-new nested split — a shape
                // `GRID_LADDER` would never produce, and the one interaction
                // this file's module doc lists as a known remount gap. The
                // header below is a plain HTML5 drag handle instead, and the
                // only rearrangement it can make is a swap (`swapPaneIds`),
                // which by construction keeps the approved shape.
                draggable={false}
                renderToolbar={() => (
                  // This `<div>` is the pane's drag handle: grabbing the
                  // header anywhere `PaneHeader` hasn't marked
                  // `draggable={false}` (its buttons and rename input) picks
                  // the whole pane up, and dropping it on another pane's body
                  // trades their places. Plain HTML5 DnD — react-mosaic's own
                  // drag source used to be connected here instead, see the
                  // `draggable={false}` above for why it isn't any more.
                  // `pane-toolbar-wrap` (App.css) stretches it to fill the
                  // toolbar row — see App.css's own comment on that class
                  // for the white-band bug this is half the fix for.
                  <div
                    className="pane-toolbar-wrap"
                    draggable
                    onDragStart={(e) => {
                      // A custom MIME rather than text/plain: nothing else in
                      // the app (or in xterm) can mistake a pane drag for
                      // droppable text, react-dnd won't adopt it as one of its
                      // "native item" types, and the drag store has to be
                      // non-empty or WebKit refuses to start the drag at all.
                      e.dataTransfer.setData("application/x-ade-pane", tab.id);
                      e.dataTransfer.effectAllowed = "move";
                      stopBeforeReactDnd(e);
                      setDrag({ from: tab.id, over: null });
                    }}
                    onDragEnd={() => setDrag(null)}
                  >
                    <PaneHeader
                      tab={tab}
                      projectLabel={projectLabel}
                      isFocused={tab.id === activeTabId}
                      onFocus={() => onActivateTab(tab.id)}
                      onClose={() => onCloseTab(tab.id)}
                      onSplit={() => {
                        const project = projects.find((p) => p.id === projectId);
                        if (project) onNewTabInProject(project);
                      }}
                      onRename={(label) => onRenameTab(tab.id, label)}
                      onChangeEngine={(engine) => onChangeEngine(tab, engine)}
                      onChangeTheme={(themeId) => onChangeTheme(tab.id, themeId)}
                      onOpenCodeReview={() => onOpenCodeReview(tab)}
                    />
                  </div>
                )}
              >
                <div
                  className={`pane-body${tab.id === activeTabId ? " is-focused" : ""}${
                    drag !== null && drag.over === tab.id && drag.from !== tab.id ? " is-swap-target" : ""
                  }${awaitingApproval ? " has-approval-banner" : ""}`}
                  onMouseDownCapture={() => onActivateTab(tab.id)}
                  // Only a pane drag from THIS grid opens a drop zone —
                  // without the guard, `preventDefault` here would also claim
                  // OS file drags, which `Terminal.tsx` handles itself (it
                  // pastes the dropped path) through Tauri's own webview
                  // drag-drop event, not through HTML5 DnD.
                  onDragOver={(e) => {
                    if (drag === null) return;
                    stopBeforeReactDnd(e);
                    if (drag.from === tab.id) return; // a pane can't trade with itself
                    e.preventDefault(); // = "this is a drop zone"
                    if (drag.over !== tab.id) setDrag({ ...drag, over: tab.id });
                  }}
                  onDrop={(e) => {
                    if (drag === null) return;
                    stopBeforeReactDnd(e);
                    if (drag.from === tab.id) return;
                    e.preventDefault();
                    setTree((prev) => swapPaneIds(prev, drag.from, tab.id));
                    setDrag(null);
                  }}
                >
                  <Terminal
                    sessionId={tab.id}
                    visible={terminalsVisible}
                    focused={terminalsVisible && tab.id === activeTabId}
                    themeId={tab.themeId}
                    onEngineTitle={onEngineTitle}
                    agentState={agentState}
                    tabEngine={tab.engine}
                  />
                  {awaitingApproval && (
                    <div className="pane-approval-banner" role="status" aria-live="polite">
                      <div className="pane-approval-banner-head">
                        <span className="pane-approval-banner-text">
                          Needs approval — {tabDisplayLabel(tab)}
                        </span>
                        <div className="pane-approval-banner-actions">
                          {canApprove && (
                            <button
                              type="button"
                              className="pane-approval-button pane-approval-button-approve"
                              onClick={() => onResolveApproval(tab, "approve")}
                            >
                              Approve
                            </button>
                          )}
                          {canDeny && (
                            <button
                              type="button"
                              className="pane-approval-button pane-approval-button-deny"
                              onClick={() => onResolveApproval(tab, "deny")}
                            >
                              Deny
                            </button>
                          )}
                        </div>
                      </div>
                      <span className="pane-approval-banner-meta">
                        {sessionLabel ? `${sessionLabel} · ` : ""}
                        Terminal {terminalIndex} of {tabs.length}
                      </span>
                    </div>
                  )}
                </div>
              </MosaicWindow>
            );
          }}
        />
      )}
    </div>
  );
}

interface WorkspaceProps {
  projects: ProjectInfo[];
  tabs: TabInfo[];
  activeTabId: string | null;
  selectedProjectId: string | null;
  onActivateTab: (id: string) => void;
  onCloseTab: (id: string) => void;
  onNewTabInProject: (project: ProjectInfo) => void;
  onRenameTab: (id: string, label: string) => void;
  /** PaneHeader's 3-dot "Change engine" — see `ProjectPaneGridProps`'s doc.
   * Optional (defaults to a no-op), same reasoning as `Sidebar.tsx`'s own
   * optional props (e.g. `view`/`onSetView`): existing tests that don't
   * care about the 3-dot menu don't have to pass it. */
  onChangeEngine?: (tab: TabInfo, engine: Engine) => void;
  /** PaneHeader's 3-dot "Terminal theme" picker. Optional, same reasoning. */
  onChangeTheme?: (id: string, themeId: TerminalThemeId) => void;
  /** PaneHeader's 3-dot "Code review". Optional, same reasoning. */
  onOpenCodeReview?: (tab: TabInfo) => void;
  /** Awaiting-approval footer actions. Optional/no-op for tests. */
  onResolveApproval?: (tab: TabInfo, decision: "approve" | "deny") => void;
  /** Engine-generated title forwarded to every pane's `<Terminal>`.
   * Optional, same reasoning. */
  onEngineTitle?: (id: string, title: string) => void;
  /** `EmptyWorkspace`'s "Start session" — a workspace with no terminals in
   * it is a front door, not a hint (see that component's own doc).
   * Optional/no-op, same reasoning as the props above: the layout and
   * visibility tests never press it. */
  onStartSession?: (project: ProjectInfo, layout: LayoutPreset, goal: string) => void;
  agentState: AgentsState;
  hidden: boolean;
  restoreState?: {
    status: "loading" | "error";
    onRetry: () => void;
  } | null;
}

export default function Workspace({
  projects,
  tabs,
  activeTabId,
  selectedProjectId,
  onActivateTab,
  onCloseTab,
  onNewTabInProject,
  onRenameTab,
  onChangeEngine = () => {},
  onChangeTheme = () => {},
  onOpenCodeReview = () => {},
  onResolveApproval = () => {},
  onEngineTitle = () => {},
  onStartSession = () => {},
  agentState,
  hidden,
  restoreState = null,
}: WorkspaceProps) {
  const projectLabel = useCallback(
    (id: string) => projects.find((p) => p.id === id)?.label ?? id,
    [projects],
  );

  // First-seen order, one entry per (project, session) that currently has
  // >= 1 open pane — every one of these renders its own always-mounted grid
  // below, and exactly one of them is displayed.
  const grouped = groupTabsBySession(tabs, activeTabId);
  const selectedHasTabs = grouped.some((g) => g.project === selectedProjectId);
  // Which session is on screen for the project the sidebar has selected.
  // Derived, never stored: it follows the focused pane, and falls back to
  // the project's first session when focus is elsewhere (selecting a
  // workspace doesn't move focus) — see `visibleSessionGroupId`'s own doc.
  const visibleSession =
    selectedProjectId === null ? null : visibleSessionGroupId(tabs, selectedProjectId, activeTabId);

  return (
    <div className="workspace" style={{ display: hidden ? "none" : "flex" }}>
      {grouped.flatMap((p) =>
        p.sessions.map((session) => {
          // Two conditions, both required: this is the selected workspace,
          // AND this is the session that workspace is currently showing.
          // Everything else stays mounted and simply isn't painted.
          const gridHidden = hidden || p.project !== selectedProjectId || session.id !== visibleSession;
          return (
            <ProjectPaneGrid
              // Keyed by session, so a session keeps its React identity —
              // and therefore its `<Terminal>`s — for its whole life. Group
              // ids are stable (`sess-grp-…` or the implicit
              // `UNGROUPED_SESSION_ID`); renaming a session changes its
              // label, never this.
              key={`${p.project}:${session.id}`}
              hidden={gridHidden}
              // Only the displayed session's grid, in the active (non-Map)
              // workspace view, is real visibility for its terminals — see
              // `ProjectPaneGridProps.terminalsVisible`'s doc.
              terminalsVisible={!gridHidden}
              projectId={p.project}
              sessionId={session.id}
              projectLabel={projectLabel(p.project)}
              tabs={session.tabs}
              activeTabId={activeTabId}
              projects={projects}
              onActivateTab={onActivateTab}
              onCloseTab={onCloseTab}
              onNewTabInProject={onNewTabInProject}
              onRenameTab={onRenameTab}
              onChangeEngine={onChangeEngine}
              onChangeTheme={onChangeTheme}
              onOpenCodeReview={onOpenCodeReview}
              onResolveApproval={onResolveApproval}
              onEngineTitle={onEngineTitle}
              agentState={agentState}
            />
          );
        }),
      )}

      {restoreState && (
        <div className="session-restore-state" role={restoreState.status === "error" ? "alert" : "status"}>
          <span className="session-restore-logo" aria-hidden />
          <p>{restoreState.status === "loading" ? "Loading session…" : "Couldn’t restore this terminal"}</p>
          {restoreState.status === "error" && (
            <button type="button" onClick={restoreState.onRetry}>
              Retry
            </button>
          )}
        </div>
      )}

      {!selectedHasTabs && !restoreState && (
        <EmptyWorkspace
          project={projects.find((p) => p.id === selectedProjectId) ?? null}
          onStart={onStartSession}
        />
      )}
    </div>
  );
}

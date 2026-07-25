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
// **Opening/closing/resizing panes within one project's grid** is instead
// made safe at the *tree-shape* level: react-mosaic-component's own
// `MosaicRoot` keys intermediate split nodes by tree *path* (see that
// library's `MosaicRoot.tsx`), so a leaf whose parent path changes gets
// discarded and remounted by React — no portal indirection changes that.
// `paneGrid.ts`'s `addPane`/`removePane` are written specifically to never
// change an *existing* leaf's path when adding or removing a sibling (see
// their own doc comments) — verified against the real library in
// `Workspace.mountStability.test.tsx`, which is what actually caught this
// class of bug (the first `addPane` implementation wrapped the whole
// existing tree on every add, which silently remounted every already-open
// terminal each time a new one was created).
//
// **The one known, deliberately-not-fixed gap**: a user physically
// dragging one pane's header onto a *different* pane's edge (forcing a
// brand-new split, rather than reordering within the existing one) does
// still remount the panes whose nesting depth changes — a real limitation
// of react-mosaic-component's own tree-diffing, not something fixable from
// application code short of patching the library. Documented, with a
// suggested mitigation, in the task report and in
// `Workspace.mountStability.test.tsx`'s last test.
import { useCallback, useEffect, useMemo, useState } from "react";
import { Mosaic, MosaicWindow, type MosaicNode } from "react-mosaic-component";
import "react-mosaic-component/react-mosaic-component.css";
import PaneHeader from "./PaneHeader";
import Terminal from "./Terminal";
import { paneIds, syncPaneTree, type PaneTree } from "../state/paneGrid";
import {
  isUnderPressure,
  PRESSURE_THRESHOLD,
  tabDisplayLabel,
  tabsByProject,
  type Engine,
  type ProjectInfo,
  type TabInfo,
} from "../state/sessions";
import type { TerminalThemeId } from "../lib/terminalThemes";

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
  /** Auto-title from the first prompt — forwarded straight through to each
   * pane's `<Terminal>` (see that component's own doc). */
  onFirstInput: (id: string, line: string) => void;
  /** NewWorkspaceModal's bulk-create: when this project's very first
   * render already has its whole tab set present (see `sessions.ts`'s
   * `tabs/opened_bulk`), and this tree's leaf ids are EXACTLY that set,
   * seed the grid with this shape instead of the ordinary flat-row
   * `syncPaneTree` build — see the effect below and `paneGrid.ts`'s
   * `buildLayoutTree` doc. `undefined`/non-matching is the normal path,
   * unchanged from before this prop existed. */
  initialTree?: PaneTree | null;
}

/** One project's grid — always mounted for as long as that project has any
 * open tab (see this file's module doc for why), CSS-hidden via `hidden`
 * when it isn't the sidebar's current selection. */
function ProjectPaneGrid({
  hidden,
  terminalsVisible,
  projectId,
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
  onFirstInput,
  initialTree,
}: ProjectPaneGridProps) {
  const [tree, setTree] = useState<PaneTree | null>(null);
  const idsKey = tabs.map((t) => t.id).join(" ");

  useEffect(() => {
    const ids = idsKey.length > 0 ? idsKey.split(" ") : [];
    setTree((prev) => {
      // `prev === null` only ever true on this instance's very first
      // relevant render (see `initialTree`'s own doc above) — once
      // anything has been synced in, it's never null again for the rest
      // of this component's mounted lifetime (a project dropping to 0
      // tabs unmounts `ProjectPaneGrid` entirely, see `Workspace`'s
      // `grouped` filter below, rather than resetting this to null in
      // place). Matching on the exact leaf-id SET (not just "some
      // initialTree exists") means an unrelated/stale `initialTree` value
      // can never misfire onto a project it wasn't built for — session
      // ids are unique, so an exact-set match only ever happens for the
      // batch it was actually computed from.
      if (prev === null && initialTree) {
        const initialIds = paneIds(initialTree);
        if (initialIds.length === ids.length && initialIds.every((id) => ids.includes(id))) {
          return initialTree;
        }
      }
      const next = syncPaneTree(prev, ids);
      return next === prev ? prev : next;
    });
  }, [idsKey, initialTree]);

  const tabsById = useMemo(() => new Map(tabs.map((t) => [t.id, t])), [tabs]);

  return (
    <div className="pane-grid-project" style={{ display: hidden ? "none" : "flex" }}>
      {tree === null ? (
        <div className="empty-workspace">
          <div className="empty-workspace-prompt">&gt;_</div>
          <p>No terminal open.</p>
          <p className="empty-workspace-hint">⌘T to start one in {projectLabel}.</p>
        </div>
      ) : (
        <Mosaic<string>
          className="pane-grid"
          value={tree}
          onChange={(next: MosaicNode<string> | null) => setTree(next as PaneTree | null)}
          renderTile={(id, path) => {
            const tab = tabsById.get(id);
            if (!tab) return <div />; // transient desync (closed mid-reconcile) — next sync clears it
            return (
              <MosaicWindow<string>
                path={path}
                title={tabDisplayLabel(tab)}
                className="pane-window"
                renderToolbar={() => (
                  // react-mosaic-component's `renderToolbar` return value
                  // gets wrapped by react-dnd's `connectDragSource` (that's
                  // how the whole header becomes the drag handle for
                  // rearranging panes) — react-dnd 16's connector requires
                  // a *native* DOM element to attach its ref to ("Only
                  // native element nodes can now be passed to React DnD
                  // connectors"), rejecting a custom component even with
                  // forwardRef. This `<div>` is that required native
                  // wrapper; `PaneHeader` owns all the actual layout.
                  // `pane-toolbar-wrap` (App.css) stretches it to fill the
                  // toolbar row — see App.css's own comment on that class
                  // for the white-band bug this is half the fix for.
                  <div className="pane-toolbar-wrap">
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
                    />
                  </div>
                )}
              >
                <div className="pane-body" onMouseDownCapture={() => onActivateTab(tab.id)}>
                  <Terminal
                    sessionId={tab.id}
                    visible={terminalsVisible}
                    themeId={tab.themeId}
                    onFirstInput={onFirstInput}
                  />
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
  selectedProjectLabel: string | undefined;
  onActivateTab: (id: string) => void;
  onCloseTab: (id: string) => void;
  onNewTabInProject: (project: ProjectInfo) => void;
  onRenameTab: (id: string, label: string) => void;
  /** PaneHeader's 3-dot "Change engine" — see `ProjectPaneGridProps`'s doc.
   * Optional (defaults to a no-op), same reasoning as `Sidebar.tsx`'s
   * `view`/`fileTreeVisible` props: existing tests that don't care about
   * the 3-dot menu don't have to pass it. */
  onChangeEngine?: (tab: TabInfo, engine: Engine) => void;
  /** PaneHeader's 3-dot "Terminal theme" picker. Optional, same reasoning. */
  onChangeTheme?: (id: string, themeId: TerminalThemeId) => void;
  /** Auto-title from the first prompt, forwarded to every pane's
   * `<Terminal>`. Optional, same reasoning. */
  onFirstInput?: (id: string, line: string) => void;
  hidden: boolean;
  /** NewWorkspaceModal's bulk-create: `projectId -> PaneTree` hints for a
   * project's very first grid render, keyed by project id — see
   * `ProjectPaneGridProps.initialTree`'s doc. Optional so every existing
   * caller/test that only ever opens tabs one at a time (⌘T, the map's
   * "Open terminal here") is unaffected. */
  initialLayouts?: Map<string, PaneTree>;
}

export default function Workspace({
  projects,
  tabs,
  activeTabId,
  selectedProjectId,
  selectedProjectLabel,
  onActivateTab,
  onCloseTab,
  onNewTabInProject,
  onRenameTab,
  onChangeEngine = () => {},
  onChangeTheme = () => {},
  onFirstInput = () => {},
  hidden,
  initialLayouts,
}: WorkspaceProps) {
  const projectLabel = useCallback(
    (id: string) => projects.find((p) => p.id === id)?.label ?? id,
    [projects],
  );

  // First-seen order, one entry per project that currently has >= 1 open
  // tab — every one of these renders its own always-mounted grid below.
  const grouped = tabsByProject(tabs);
  const selectedHasTabs = grouped.some((g) => g.project === selectedProjectId);
  const underPressure = isUnderPressure(tabs);

  return (
    <div className="workspace" style={{ display: hidden ? "none" : "flex" }}>
      {underPressure && (
        <div className="pressure-warning" role="status">
          {tabs.length} live sessions open — past the {PRESSURE_THRESHOLD}-session comfort line. Consider
          closing a few before opening more.
        </div>
      )}

      {grouped.map((g) => {
        const gridHidden = g.project !== selectedProjectId;
        return (
          <ProjectPaneGrid
            key={g.project}
            hidden={gridHidden}
            // Only the selected project's grid, in the active (non-Map)
            // workspace view, is real visibility for its terminals — see
            // `ProjectPaneGridProps.terminalsVisible`'s doc.
            terminalsVisible={!gridHidden && !hidden}
            projectId={g.project}
            projectLabel={projectLabel(g.project)}
            tabs={g.tabs}
            activeTabId={activeTabId}
            projects={projects}
            onActivateTab={onActivateTab}
            onCloseTab={onCloseTab}
            onNewTabInProject={onNewTabInProject}
            onRenameTab={onRenameTab}
            onChangeEngine={onChangeEngine}
            onChangeTheme={onChangeTheme}
            onFirstInput={onFirstInput}
            initialTree={initialLayouts?.get(g.project)}
          />
        );
      })}

      {!selectedHasTabs && (
        <div className="empty-workspace">
          <div className="empty-workspace-prompt">&gt;_</div>
          <p>No terminal open.</p>
          <p className="empty-workspace-hint">
            {projects.length === 0
              ? "Add a project (+ in the sidebar), then press ⌘T."
              : `⌘T to start one in ${selectedProjectLabel ?? "the selected project"}.`}
          </p>
        </div>
      )}
    </div>
  );
}

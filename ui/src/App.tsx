// The app shell: a `view` switch between the Phase 5 terminal workspace and
// the Phase 6 brain map (see the module-level comment at the bottom of this
// file, written by the Phase 5 agent, for the integration plan this follows).
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import "./App.css";
import Sidebar from "./components/Sidebar";
import Workspace from "./components/Workspace";
import EnginePicker from "./components/EnginePicker";
import CommandPalette from "./components/CommandPalette";
import FileTree from "./components/FileTree";
import BrainMap from "./map/BrainMap";
import FirstRun from "./onboarding/FirstRun";
import AuthGate from "./onboarding/AuthGate";
import {
  AUTH_GATE_RESOLVED_SETTING_KEY,
  AUTH_PERSONA_SETTING_KEY,
  AUTH_SIGNED_IN_SETTING_KEY,
  authGateAlreadyResolved,
  type AuthGateOutcome,
} from "./onboarding/authGateState";
import {
  GLOBAL_DEFAULT_ENGINE_KEY,
  LAYOUT_SETTING_KEY,
  defaultEngineSettingKey,
  deserializeLayout,
  initialSessionsState,
  resolveDefaultEngine,
  serializeLayout,
  sessionsReducer,
  type Engine,
  type ProjectInfo,
  type TabInfo,
} from "./state/sessions";
import { buildLayoutTree, type LayoutPreset, type PaneTree } from "./state/paneGrid";
import { ENGINE_LABEL } from "./theme";
import {
  FILE_TREE_VISIBLE_SETTING_KEY,
  getBriefing,
  ingestionStatus,
  listProjects,
  rootsList,
  sessionCreate,
  sessionKill,
  settingsGet,
  settingsSet,
  type IngestionStatus,
} from "./lib/tauri";

type View = "workspace" | "map";

/** Task 8.1: how often `App.tsx` polls `ingestion_status` — PLAN.md's own
 * cadence ("called every ~2s from the frontend while ingestion runs"). This
 * one poll loop backs BOTH FirstRun's onboarding HUD and BrainMap's
 * `livePollMs` live-growth feed (and, incidentally, the post-"Rebuild
 * brain" project-list refresh) — see the boot-adjacent effect below for
 * why a single, always-running poll is simpler than start/stop plumbing
 * threaded through three different triggers. */
const INGESTION_POLL_MS = 2000;

function App() {
  const [state, dispatch] = useReducer(sessionsReducer, initialSessionsState);
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);
  const [pickerProject, setPickerProject] = useState<ProjectInfo | null>(null);
  const [pickerDefault, setPickerDefault] = useState<Engine>("claude");
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [errorBanner, setErrorBanner] = useState<string | null>(null);
  const [view, setView] = useState<View>("workspace");
  const restoredRef = useRef(false);
  // Founder feedback (Bruno, 2026-07-25, verbatim): "nice to have a
  // folder/file navigation on the right panel" — but the same founder has
  // twice now been explicit that UI chrome must not compete with the
  // terminal workspace for attention, so it's collapsible rather than a
  // fixed extra column. Defaults to visible (it's the feature being asked
  // for) and is persisted via the same settings-table pattern
  // `LAYOUT_SETTING_KEY`/`REVIEW_MEMORY_SETTING_KEY` already use, restored
  // in the boot effect below alongside the tab layout.
  const [fileTreeVisible, setFileTreeVisible] = useState(true);

  // NewWorkspaceModal's bulk-create: `projectId -> PaneTree` arrangement
  // hints for a project's very first pane-grid render (see
  // `Workspace.tsx`'s `initialLayouts`/`ProjectPaneGrid`'s `initialTree`
  // doc). A plain mutable ref, not React state — nothing needs to
  // re-render *because* this map changed; it only needs to hold the right
  // value by the time the `tabs/opened_bulk` dispatch below triggers
  // `Workspace`'s next render, and mutating-then-dispatching in the same
  // synchronous call does exactly that. `ProjectPaneGrid` only ever reads
  // an entry once (its tree is never `null` again after that, see that
  // component's own doc), so entries are deliberately never cleaned up
  // afterward — bounded by "how many workspaces this session has ever
  // bulk-created," negligible for a desktop app that restarts on relaunch.
  const pendingLayoutsRef = useRef<Map<string, PaneTree>>(new Map());

  // ---- fake sign-in + personalization gate — a SEPARATE, EARLIER gate
  // than Task 8.1's FirstRun below (Bruno, verbatim: "let's Focus on
  // getting to know the user after a login, but they can use it without
  // login for now while in development. Login must be fake for now, just
  // to test the workflow."). `null` while checking, same convention as
  // `needsOnboarding` right below — the render below only shows FirstRun
  // once this has resolved to `false` (either the user signed in/answered,
  // or explicitly skipped), so a first-ever launch never shows both
  // overlays layered on top of each other.
  const [needsAuthGate, setNeedsAuthGate] = useState<boolean | null>(null);

  // ---- Task 8.1: onboarding gating + the always-on ingestion status poll -
  const [needsOnboarding, setNeedsOnboarding] = useState<boolean | null>(null); // null = still checking
  const [firstRunDismissed, setFirstRunDismissed] = useState(false);
  const [ingestion, setIngestion] = useState<IngestionStatus | null>(null);
  const wasIngestingRef = useRef(false);

  const reloadProjects = useCallback(async () => {
    try {
      const projects = await listProjects();
      dispatch({ type: "projects/loaded", projects });
    } catch (err) {
      console.error("failed to load projects", err);
      setErrorBanner(`Couldn't load projects from the brain: ${err}`);
    }
  }, []);

  // Polls `ingestion_status` at a fixed cadence for the app's whole
  // lifetime rather than starting/stopping around each of its three
  // triggers (first-run picker, "Rebuild brain", a future "add another
  // folder") — one cheap mutex-guarded read every 2s is negligible, and it
  // means FirstRun/BrainMap/AboutPanel never have to coordinate who owns
  // starting or stopping the loop. Whenever `running` flips true -> false,
  // the project list (which "Rebuild brain" especially can change
  // wholesale) is refreshed exactly once.
  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      try {
        const status = await ingestionStatus();
        if (cancelled) return;
        setIngestion(status);
        if (status.running) {
          wasIngestingRef.current = true;
        } else if (wasIngestingRef.current) {
          wasIngestingRef.current = false;
          void reloadProjects();
        }
      } catch (err) {
        console.error("ingestion_status poll failed", err);
      }
    };
    void tick();
    const interval = window.setInterval(tick, INGESTION_POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [reloadProjects]);

  // ---- auth gate check — its own independent effect, deliberately NOT
  // nested inside the boot effect below: a UI gate read must never block
  // (or be blocked by) project loading/layout restore. Resolved once, on
  // mount — a real login wouldn't re-prompt every launch, and testing
  // "does this workflow feel right" requires the same behavior here.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const resolved = await settingsGet(AUTH_GATE_RESOLVED_SETTING_KEY);
        if (!cancelled) setNeedsAuthGate(!authGateAlreadyResolved(resolved));
      } catch (err) {
        console.error("failed to read auth_gate_resolved setting, defaulting to resolved", err);
        if (!cancelled) setNeedsAuthGate(false); // fail open — never trap the user behind a broken check
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // ---- boot: load the sidebar's project list + restore the last layout --
  useEffect(() => {
    let cancelled = false;

    (async () => {
      await reloadProjects();

      try {
        const roots = await rootsList();
        if (!cancelled) setNeedsOnboarding(roots.length === 0);
      } catch (err) {
        console.error("failed to load project roots", err);
        if (!cancelled) setNeedsOnboarding(false); // fail open — never trap the user behind a broken check
      }

      try {
        const storedFileTreeVisible = await settingsGet(FILE_TREE_VISIBLE_SETTING_KEY);
        // Unset (first run) keeps the `useState(true)` default — only an
        // explicit "false" ever hides it on boot.
        if (!cancelled && storedFileTreeVisible !== null) {
          setFileTreeVisible(storedFileTreeVisible === "true");
        }
      } catch (err) {
        console.error("failed to read file_tree_visible setting, defaulting to visible", err);
      }

      try {
        const raw = await settingsGet(LAYOUT_SETTING_KEY);
        const persisted = deserializeLayout(raw);
        const restored: TabInfo[] = [];
        for (const t of persisted) {
          try {
            const briefing = t.engine === "claude" ? await getBriefing(t.project) : undefined;
            const info = await sessionCreate(t.project, t.engine, t.cwd, briefing);
            restored.push({
              id: info.id,
              project: info.project,
              engine: t.engine,
              cwd: info.cwd,
              createdAt: info.created,
              label: t.label,
              needsAttention: false,
            });
          } catch (err) {
            // DESIGN 3.1: engines "restart fresh" on relaunch — if one
            // fails to spawn (e.g. that CLI got uninstalled), skip it
            // rather than blocking the rest of the layout from restoring.
            console.error("failed to restore tab", t, err);
          }
        }
        if (!cancelled) dispatch({ type: "layout/restored", tabs: restored });
      } catch (err) {
        console.error("failed to restore layout", err);
      } finally {
        restoredRef.current = true;
      }
    })();

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ---- persist layout whenever the open tabs change (post-restore only) -
  useEffect(() => {
    if (!restoredRef.current) return;
    void settingsSet(LAYOUT_SETTING_KEY, serializeLayout(state.tabs));
  }, [state.tabs]);

  // ---- session-attention:{id} events (founder feedback, 2026-07-24) -----
  // Same subscription style `Terminal.tsx` already uses for
  // `session-output:{id}` (`void listen(event, cb).then((unlisten) => ...)`)
  // — the difference is *where* it's done: `Terminal.tsx` subscribes once
  // per mounted session because it only ever cares about its own id, but
  // the attention badge has to update the Sidebar/TabBar for a session that
  // isn't the active tab's Terminal, so it lives here instead, subscribing
  // per tab id and diffing against `state.tabs` as tabs open/close (rather
  // than tearing everything down and resubscribing on every tab change,
  // which would risk a real event landing in the gap). `attentionListeners`
  // holds either a resolved `UnlistenFn` or a temporary cancel-flag closure
  // for a subscription still in flight — see the resolution branch below
  // for why that matters when a tab closes before its `listen()` call
  // returns.
  const attentionListeners = useRef<Map<string, UnlistenFn>>(new Map());
  useEffect(() => {
    const listeners = attentionListeners.current;
    const liveIds = new Set(state.tabs.map((t) => t.id));

    for (const [id, unlisten] of listeners) {
      if (!liveIds.has(id)) {
        unlisten();
        listeners.delete(id);
      }
    }

    for (const id of liveIds) {
      if (listeners.has(id)) continue;
      let cancelled = false;
      listeners.set(id, () => {
        cancelled = true;
      });
      void listen(`session-attention:${id}`, () => {
        dispatch({ type: "tab/attention", id });
      }).then((unlisten) => {
        if (cancelled) {
          unlisten();
          return;
        }
        listeners.set(id, unlisten);
      });
    }
  }, [state.tabs]);

  // Unsubscribe everything on unmount (App.tsx only ever unmounts with the
  // whole window closing, but this keeps the pattern honest/symmetric).
  useEffect(() => {
    const listeners = attentionListeners.current;
    return () => {
      for (const unlisten of listeners.values()) unlisten();
      listeners.clear();
    };
  }, []);

  // ---- default the sidebar's "current project" once projects arrive -----
  useEffect(() => {
    if (selectedProjectId === null && state.projects.length > 0) {
      setSelectedProjectId(state.projects[0].id);
    }
  }, [state.projects, selectedProjectId]);

  const selectedProject = useMemo(
    () => state.projects.find((p) => p.id === selectedProjectId) ?? null,
    [state.projects, selectedProjectId],
  );

  // ---- new-tab flow: resolve the default engine, then show the picker ---
  // Same out-of-order-response guard `useGraphData.ts`'s `fetchOnce`
  // already established for `map_graph`: a monotonically incrementing ref,
  // captured at the start of each call, checked before applying the
  // result. Without it, clicking "+" for project A then quickly for
  // project B has no protection against A's `Promise.all` settling AFTER
  // B's — whichever settles last wins the picker state regardless of click
  // order, so a user who confirms via Enter without reading the modal's
  // project label could land a live terminal in the wrong project.
  const requestNewTabIdRef = useRef(0);
  const requestNewTab = useCallback(async (project: ProjectInfo) => {
    setSelectedProjectId(project.id);
    const requestId = ++requestNewTabIdRef.current;
    let perProject: string | null = null;
    let global: string | null = null;
    try {
      [perProject, global] = await Promise.all([
        settingsGet(defaultEngineSettingKey(project.id)),
        settingsGet(GLOBAL_DEFAULT_ENGINE_KEY),
      ]);
    } catch (err) {
      console.error("failed to read engine-default settings, falling back to claude", err);
    }
    if (requestId !== requestNewTabIdRef.current) return; // superseded by a newer requestNewTab call
    const settingsMap: Record<string, string | undefined> = {};
    if (perProject) settingsMap[defaultEngineSettingKey(project.id)] = perProject;
    if (global) settingsMap[GLOBAL_DEFAULT_ENGINE_KEY] = global;
    setPickerDefault(resolveDefaultEngine(project.id, settingsMap));
    setPickerProject(project);
  }, []);

  // The one place a session actually gets spawned: `engine === "claude"`
  // fetches its briefing first (the zero-config MCP/briefing wiring
  // DESIGN.md 5 requires happens automatically around the engine, never by
  // asking the user to configure anything), then calls `session_create`
  // with the project's cwd. Shared by both the single-tab ⌘T/"+" flow
  // (`confirmNewTab` below) and NewWorkspaceModal's bulk-create
  // (`handleWorkspaceCreated`) so there is exactly one place that knows how
  // to spin up a session for a project — no second, drifting copy of the
  // per-engine spawn logic.
  const createSessionTab = useCallback(async (project: ProjectInfo, engine: Engine): Promise<TabInfo> => {
    const briefing = engine === "claude" ? await getBriefing(project.id) : undefined;
    const cwd = project.path ?? project.id;
    const info = await sessionCreate(project.id, engine, cwd, briefing);
    return {
      id: info.id,
      project: info.project,
      engine,
      cwd: info.cwd,
      createdAt: info.created,
      needsAttention: false,
    };
  }, []);

  const confirmNewTab = useCallback(
    async (engine: Engine) => {
      const project = pickerProject;
      setPickerProject(null);
      if (!project) return;
      try {
        const tab = await createSessionTab(project, engine);
        dispatch({ type: "tab/opened", tab });
        void settingsSet(defaultEngineSettingKey(project.id), engine);
        // Cross-view integration point (Task 6.2): the map's "Open terminal
        // here" action calls `requestNewTab` too (via `onOpenTerminal`
        // below), so landing back in the workspace here covers both
        // origins — a no-op when we were already there.
        setView("workspace");
      } catch (err) {
        console.error("failed to create session", err);
        setErrorBanner(`Couldn't start ${engine} in ${project.label}: ${err}`);
      }
    },
    [pickerProject, createSessionTab],
  );

  // ---- NewWorkspaceModal's bulk-create (Sidebar's "+" -> New Workspace) -
  // `add_project` + the modal's own folder-pick/name UI already ran inside
  // `NewWorkspaceModal.tsx` by the time this fires (see that component's
  // module doc for the ownership split) — `project` already exists. This
  // spins up exactly one session per checked engine, in the order the
  // caller passed (`newWorkspaceState.ts`'s `checkedEngines` — always
  // `ENGINES` order), landing every success in ONE `tabs/opened_bulk`
  // dispatch (never one `tab/opened` per session — see that action's own
  // doc for why an incremental reveal would both defeat the chosen LAYOUT
  // arrangement and risk remounting already-open panes mid-batch).
  //
  // Partial failure is expected, not exceptional (DESIGN.md's own "bring
  // your own engine" reality: a checked engine's CLI might genuinely not be
  // installed) — every engine is attempted independently; one failing
  // never aborts the rest, and whatever succeeds still lands the user in a
  // live, populated project rather than nothing at all.
  //
  // Deliberately does NOT persist `defaultEngineSettingKey` the way
  // `confirmNewTab` does — that setting means "the last single engine
  // chosen for this project's next ⌘T", and a multi-engine batch has no
  // one answer to write there.
  const handleWorkspaceCreated = useCallback(
    async (project: ProjectInfo, engines: Engine[], layout: LayoutPreset) => {
      void reloadProjects();
      setSelectedProjectId(project.id);

      const created: TabInfo[] = [];
      const failed: Engine[] = [];
      for (const engine of engines) {
        try {
          created.push(await createSessionTab(project, engine));
        } catch (err) {
          console.error(`failed to start ${engine} in ${project.label}`, err);
          failed.push(engine);
        }
      }

      if (created.length > 0) {
        const tree = buildLayoutTree(created.map((t) => t.id), layout);
        if (tree) pendingLayoutsRef.current.set(project.id, tree);
        dispatch({ type: "tabs/opened_bulk", tabs: created });
      }

      if (failed.length > 0) {
        const names = failed.map((e) => ENGINE_LABEL[e]).join(", ");
        setErrorBanner(
          created.length > 0
            ? `Created "${project.label}", but couldn't start ${names} — the rest are running.`
            : `Created "${project.label}", but couldn't start ${names} — no sessions are running yet.`,
        );
      }

      setView("workspace");
    },
    [reloadProjects, createSessionTab],
  );

  // Activating a tab is now also "the grid you're looking at should show
  // it" — the pane grid (Workspace.tsx) only ever displays the *selected*
  // project's sessions as panes, unlike the old single-tab-visible TabBar
  // strip which could show any project's tab regardless of the sidebar
  // selection. So every activation path (Sidebar's per-project tab list,
  // CommandPalette's "switch to", a pane header gaining focus) keeps
  // `selectedProjectId` in sync with whichever tab it's activating —
  // otherwise "switch to X" could focus a tab whose grid isn't even on
  // screen. `activeTabId` itself keeps its pre-existing job (which pane
  // last had focus — used to clear its attention badge, and to know which
  // pane to visually highlight); see `state/sessions.ts`'s `TabInfo` doc for
  // the reducer side of this.
  const activateTab = useCallback(
    (id: string) => {
      const tab = state.tabs.find((t) => t.id === id);
      if (tab) setSelectedProjectId(tab.project);
      dispatch({ type: "tab/activated", id });
    },
    [state.tabs],
  );

  const renameTab = useCallback(
    (id: string, label: string) => dispatch({ type: "tab/renamed", id, label }),
    [],
  );

  // Same optimistic-flip-then-persist shape as `ReviewPanel.tsx`'s
  // `toggleReviewMode` (its own settings-table boolean toggle) — flip local
  // state immediately so the panel opens/closes with no round-trip latency,
  // fire-and-forget the persist. Doubles as both the sidebar trigger's
  // handler and the panel's own in-place close button.
  const toggleFileTree = useCallback(() => {
    const next = !fileTreeVisible;
    setFileTreeVisible(next);
    void settingsSet(FILE_TREE_VISIBLE_SETTING_KEY, next ? "true" : "false");
  }, [fileTreeVisible]);

  // `AuthGate`'s `onResolved` — fires exactly once, whichever path the user
  // took (skip-from-login, or personalize's answer/skip). Persists all
  // three settings the gate cares about and dismisses it immediately
  // (optimistic, same shape as `toggleFileTree` above — the writes are
  // fire-and-forget, the UI doesn't wait on them).
  const handleAuthGateResolved = useCallback((outcome: AuthGateOutcome) => {
    setNeedsAuthGate(false);
    void settingsSet(AUTH_GATE_RESOLVED_SETTING_KEY, "true");
    void settingsSet(AUTH_SIGNED_IN_SETTING_KEY, outcome.signedIn ? "true" : "false");
    void settingsSet(AUTH_PERSONA_SETTING_KEY, outcome.persona ?? "");
  }, []);

  // AboutPanel's "Reset sign-in flow" (Sidebar threads it through) — clears
  // the persisted outcome and re-shows the gate immediately, without
  // needing an actual app relaunch or manual devtools settings surgery.
  // Deliberately a dev-mode-only affordance: nothing here checks any real
  // credential, so "resetting" is just re-running the same fake workflow.
  const resetAuthGate = useCallback(() => {
    setNeedsAuthGate(true);
    void settingsSet(AUTH_GATE_RESOLVED_SETTING_KEY, "false");
    void settingsSet(AUTH_SIGNED_IN_SETTING_KEY, "false");
    void settingsSet(AUTH_PERSONA_SETTING_KEY, "");
  }, []);

  const closeTab = useCallback(async (id: string) => {
    try {
      await sessionKill(id);
    } catch (err) {
      console.error("failed to kill session (closing tab anyway)", err);
    }
    dispatch({ type: "tab/closed", id });
  }, []);

  // ---- ⌘T new tab / ⌘K palette. ⌘W is deliberately left alone — see the
  // module comment at the bottom of this file for why. -------------------
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (!e.metaKey) return;
      if (e.key.toLowerCase() === "t") {
        e.preventDefault();
        if (selectedProject) void requestNewTab(selectedProject);
      } else if (e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen((open) => !open);
      }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [selectedProject, requestNewTab]);

  return (
    <div className="app-shell">
      {errorBanner && (
        <div className="error-banner">
          <span>{errorBanner}</span>
          <button onClick={() => setErrorBanner(null)}>Dismiss</button>
        </div>
      )}
      <div className="app-body">
        <Sidebar
          projects={state.projects}
          tabs={state.tabs}
          activeTabId={state.activeTabId}
          selectedProjectId={selectedProjectId}
          onSelectProject={(p) => setSelectedProjectId(p.id)}
          onNewTabInProject={(p) => void requestNewTab(p)}
          onActivateTab={activateTab}
          onWorkspaceCreated={(p, engines, layout) => void handleWorkspaceCreated(p, engines, layout)}
          ingestion={ingestion}
          view={view}
          onSetView={setView}
          fileTreeVisible={fileTreeVisible}
          onToggleFileTree={toggleFileTree}
          onResetAuthGate={resetAuthGate}
        />
        <Workspace
          projects={state.projects}
          tabs={state.tabs}
          activeTabId={state.activeTabId}
          selectedProjectId={selectedProjectId}
          selectedProjectLabel={selectedProject?.label}
          onActivateTab={activateTab}
          onCloseTab={(id) => void closeTab(id)}
          onNewTabInProject={(p) => void requestNewTab(p)}
          onRenameTab={renameTab}
          hidden={view !== "workspace"}
          initialLayouts={pendingLayoutsRef.current}
        />
        <BrainMap
          projects={state.projects}
          onOpenTerminal={(p) => void requestNewTab(p)}
          hidden={view !== "map"}
          livePollMs={ingestion?.running ? INGESTION_POLL_MS : undefined}
        />
        {fileTreeVisible && (
          <FileTree project={selectedProject} activeTabId={state.activeTabId} onClose={toggleFileTree} />
        )}
      </div>

      {needsAuthGate === true && <AuthGate onResolved={handleAuthGateResolved} />}

      {needsAuthGate === false && needsOnboarding === true && !firstRunDismissed && (
        <FirstRun
          ingestion={ingestion}
          onRequestView={setView}
          onOpenTerminal={(p) => void requestNewTab(p)}
          onDismiss={() => setFirstRunDismissed(true)}
        />
      )}

      {pickerProject && (
        <EnginePicker
          project={pickerProject}
          defaultEngine={pickerDefault}
          onConfirm={(engine) => void confirmNewTab(engine)}
          onCancel={() => setPickerProject(null)}
        />
      )}

      <CommandPalette
        open={paletteOpen}
        projects={state.projects}
        tabs={state.tabs}
        onClose={() => setPaletteOpen(false)}
        onActivateTab={activateTab}
        onNewTabInProject={(p) => void requestNewTab(p)}
      />
    </div>
  );
}

export default App;

// ---------------------------------------------------------------------------
// Phase 6 integration notes (superseded the Phase 5 agent's plan above,
// which this followed almost verbatim — kept as a record of what changed
// and why, for whoever touches this next):
//
// - `view: "workspace" | "map"` state lives here, toggled from the Sidebar
//   (two header buttons next to the OMNIAGENT wordmark).
// - `<Workspace>` (`components/Workspace.tsx`) and `<BrainMap>`
//   (`map/BrainMap.tsx`) are BOTH always mounted — never `{view === "x" ?
//   A : B}` — visibility is CSS-only (`hidden` prop -> `display: none`).
//   This deviates from the Phase 5 note's literal ternary suggestion on
//   purpose: `<Terminal>` (inside `<Workspace>`) already relies on staying
//   mounted across tab switches so it doesn't miss `session-output:{id}`
//   events fired while it's in the background (see `Terminal.tsx`'s own
//   doc comment) — unmounting the whole `<Workspace>` on a view switch
//   would silently drop live PTY output the same way. Keeping `<BrainMap>`
//   mounted too is a free bonus: camera position, expand/filter state, and
//   the force simulation all survive switching back to the workspace and
//   forth again, instead of re-fetching and re-laying-out every time.
// - `requestNewTab`/`confirmNewTab` stayed in `App.tsx` rather than moving
//   to a shared hook (the note above suggested that as one option) —
//   `<BrainMap>` just receives `onOpenTerminal={(p) =>
//   void requestNewTab(p)}` as a prop, same shape the Sidebar/TabBar/
//   CommandPalette already use. `confirmNewTab` now also does
//   `setView("workspace")` after a successful `session_create`, which is
//   the actual cross-view integration point: click "Open terminal here" on
//   a map node -> engine picker -> session created -> view flips back to
//   the workspace with the new tab focused (the reducer's `tab/opened`
//   already sets `activeTabId`).
// - `map_graph`/`map_node_detail` (see `src/lib/tauri.ts`) are the map's
//   own Tauri commands (`src-tauri/src/map_feed.rs`), following the same
//   thin-wrapper pattern as `brain_query`/`brain_briefing`.
// ---------------------------------------------------------------------------

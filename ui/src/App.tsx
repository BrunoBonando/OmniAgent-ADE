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
import BrainMap from "./map/BrainMap";
import FirstRun from "./onboarding/FirstRun";
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
import {
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
  const requestNewTab = useCallback(async (project: ProjectInfo) => {
    setSelectedProjectId(project.id);
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
    const settingsMap: Record<string, string | undefined> = {};
    if (perProject) settingsMap[defaultEngineSettingKey(project.id)] = perProject;
    if (global) settingsMap[GLOBAL_DEFAULT_ENGINE_KEY] = global;
    setPickerDefault(resolveDefaultEngine(project.id, settingsMap));
    setPickerProject(project);
  }, []);

  const confirmNewTab = useCallback(
    async (engine: Engine) => {
      const project = pickerProject;
      setPickerProject(null);
      if (!project) return;
      try {
        const briefing = engine === "claude" ? await getBriefing(project.id) : undefined;
        const cwd = project.path ?? project.id;
        const info = await sessionCreate(project.id, engine, cwd, briefing);
        dispatch({
          type: "tab/opened",
          tab: {
            id: info.id,
            project: info.project,
            engine,
            cwd: info.cwd,
            createdAt: info.created,
            needsAttention: false,
          },
        });
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
    [pickerProject],
  );

  const activateTab = useCallback((id: string) => dispatch({ type: "tab/activated", id }), []);

  const renameTab = useCallback(
    (id: string, label: string) => dispatch({ type: "tab/renamed", id, label }),
    [],
  );

  // ---- the sidebar's "+" Add Project flow (founder feedback, 2026-07-24):
  // `add_project` already upserted the node and returned its `ProjectInfo`
  // synchronously, so there's no need to await `reloadProjects` before
  // acting on it — select it and go straight into the engine picker
  // (`requestNewTab`, the exact same flow the per-project "+"/⌘T already
  // use) so a terminal is one more click away immediately. `reloadProjects`
  // still runs, non-blocking, so the sidebar row appears without waiting
  // for the next `ingestion_status` poll's post-run refresh.
  const handleProjectAdded = useCallback(
    (project: ProjectInfo) => {
      void reloadProjects();
      setSelectedProjectId(project.id);
      void requestNewTab(project);
    },
    [reloadProjects, requestNewTab],
  );

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
          onProjectAdded={handleProjectAdded}
          ingestion={ingestion}
          view={view}
          onSetView={setView}
        />
        <Workspace
          projects={state.projects}
          tabs={state.tabs}
          activeTabId={state.activeTabId}
          selectedProjectLabel={selectedProject?.label}
          onActivateTab={activateTab}
          onCloseTab={(id) => void closeTab(id)}
          onNewTabInProject={(p) => void requestNewTab(p)}
          onRenameTab={renameTab}
          hidden={view !== "workspace"}
        />
        <BrainMap
          projects={state.projects}
          onOpenTerminal={(p) => void requestNewTab(p)}
          hidden={view !== "map"}
          livePollMs={ingestion?.running ? INGESTION_POLL_MS : undefined}
        />
      </div>

      {needsOnboarding === true && !firstRunDismissed && (
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

// The workspace shell (PLAN.md Phase 5, Task 5.2). This is currently the
// *only* view the app renders — there is no view-switcher yet. Phase 6 (the
// brain map pane) needs to add one; see the module-level comment at the
// bottom of this file for exactly what to hook into.
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import "./App.css";
import Sidebar from "./components/Sidebar";
import TabBar from "./components/TabBar";
import Terminal from "./components/Terminal";
import EnginePicker from "./components/EnginePicker";
import CommandPalette from "./components/CommandPalette";
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
import { getBriefing, listProjects, sessionCreate, sessionKill, settingsGet, settingsSet } from "./lib/tauri";

function App() {
  const [state, dispatch] = useReducer(sessionsReducer, initialSessionsState);
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);
  const [pickerProject, setPickerProject] = useState<ProjectInfo | null>(null);
  const [pickerDefault, setPickerDefault] = useState<Engine>("claude");
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [errorBanner, setErrorBanner] = useState<string | null>(null);
  const restoredRef = useRef(false);

  // ---- boot: load the sidebar's project list + restore the last layout --
  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const projects = await listProjects();
        if (!cancelled) dispatch({ type: "projects/loaded", projects });
      } catch (err) {
        console.error("failed to load projects", err);
        if (!cancelled) setErrorBanner(`Couldn't load projects from the brain: ${err}`);
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
          tab: { id: info.id, project: info.project, engine, cwd: info.cwd, createdAt: info.created },
        });
        void settingsSet(defaultEngineSettingKey(project.id), engine);
      } catch (err) {
        console.error("failed to create session", err);
        setErrorBanner(`Couldn't start ${engine} in ${project.label}: ${err}`);
      }
    },
    [pickerProject],
  );

  const activateTab = useCallback((id: string) => dispatch({ type: "tab/activated", id }), []);

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
        />
        <div className="workspace">
          <TabBar
            projects={state.projects}
            tabs={state.tabs}
            activeTabId={state.activeTabId}
            onActivateTab={activateTab}
            onCloseTab={(id) => void closeTab(id)}
            onNewTabInProject={(p) => void requestNewTab(p)}
          />
          <div className="terminal-area">
            {state.tabs.map((tab) => (
              <Terminal key={tab.id} sessionId={tab.id} visible={tab.id === state.activeTabId} />
            ))}
            {state.tabs.length === 0 && (
              <div className="empty-workspace">
                <div className="empty-workspace-prompt">&gt;_</div>
                <p>No terminal open.</p>
                <p className="empty-workspace-hint">
                  {state.projects.length === 0
                    ? "Ingest a project, then press ⌘T."
                    : `⌘T to start one in ${selectedProject?.label ?? "the selected project"}.`}
                </p>
              </div>
            )}
          </div>
        </div>
      </div>

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
// Notes for Phase 6 (brain map pane) — read this before wiring the map in.
//
// - This file is the entire app today: there is no router and no
//   view-switcher. `<App>` renders the workspace (Sidebar + TabBar +
//   terminal-area) unconditionally.
// - State lives in one `useReducer(sessionsReducer, ...)` here in `App.tsx`
//   (see `src/state/sessions.ts` for the reducer/actions/types — it's
//   framework-free on purpose). Local UI state (selected project, palette
//   open, engine-picker target) is plain `useState` alongside it.
// - Suggested integration: add a top-level view switcher (e.g. a `view:
//   "workspace" | "map"` piece of state, or promote to a tiny router) and
//   move the current JSX under `app-body` into its own `<Workspace>`
//   component so `<App>` becomes `{view === "workspace" ? <Workspace/> :
//   <BrainMap/>}`. The Sidebar is a natural place for the view toggle
//   (e.g. a second header icon next to the OMNIAGENT wordmark).
// - `brain_query`/`brain_get_context` (see `src/lib/tauri.ts`) are already
//   general-purpose brain-read commands on the Rust side — the map's data
//   feed (`map_graph`, per PLAN.md Task 6.1) should be a new Tauri command
//   alongside them in `src-tauri/src/commands.rs`, not a new query path.
// - "Open terminal here" from a future map detail panel should reuse
//   `requestNewTab`'s shape (project -> engine picker -> session_create):
//   lift `requestNewTab`/`confirmNewTab` out of `App.tsx` into a shared
//   hook if the map pane needs to trigger the same flow from outside the
//   sidebar/tab-bar.
// ---------------------------------------------------------------------------

// The app shell: a `view` switch between the Phase 5 terminal workspace and
// the Phase 6 brain map (see the module-level comment at the bottom of this
// file, written by the Phase 5 agent, for the integration plan this follows).
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import "./App.css";
import Sidebar from "./components/Sidebar";
import Workspace from "./components/Workspace";
import CommandPalette from "./components/CommandPalette";
import FileTree from "./components/FileTree";
import CodeReviewPanel from "./components/CodeReviewPanel";
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
  tabDisplayLabel,
  type Engine,
  type ProjectInfo,
  type TabInfo,
} from "./state/sessions";
import { buildLayoutTree, type LayoutPreset, type PaneTree } from "./state/paneGrid";
import { importFailureBanner, type ImportBatchResult } from "./state/importState";
import { isSessionStatus, type SessionStatusEvent } from "./state/sessionStatus";
import { ENGINE_LABEL } from "./theme";
import type { TerminalThemeId } from "./lib/terminalThemes";
import { usePerSessionEvent } from "./lib/usePerSessionEvent";
import {
  FILE_TREE_VISIBLE_SETTING_KEY,
  getBriefing,
  ingestionStatus,
  listProjects,
  renameProject,
  rootsList,
  sessionCreate,
  sessionKill,
  sessionStatus,
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
  const [paletteOpen, setPaletteOpen] = useState(false);
  // ⌘N (founder ask: "Command + N opens a new workspace") — lifted out of
  // `Sidebar.tsx` (which still owns its OTHER overlays locally, e.g.
  // aboutOpen/reviewOpen/importOpen) so the global keydown handler below
  // can open it, same as ⌘T/⌘K.
  const [newWorkspaceOpen, setNewWorkspaceOpen] = useState(false);
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

  // ---- the per-session code review column (founder ask, 2026-07-26) -----
  //
  // `null` = closed. When open it holds the session the panel is reviewing,
  // captured at open time from the pane whose 3-dot menu was used — which is
  // the whole "Make sure that the code panel is for session, okay?" contract.
  // Opening it from a different pane re-targets it rather than stacking a
  // second column.
  //
  // COEXISTENCE WITH THE FILE TREE: they share the one right-hand dock and
  // are mutually exclusive, because at realistic window widths they aren't
  // both affordable — a 1440px MacBook already spends ~220px on the sidebar,
  // and a file tree (260) plus a review column (440) would leave the
  // terminals under 520px, which is where a terminal grid stops being usable.
  // The review column wins while it's open and the file tree comes back
  // exactly as the user left it on close: `fileTreeVisible` is deliberately
  // NOT mutated here, it stays the user's own preference and is only
  // suppressed from rendering.
  const [reviewTarget, setReviewTarget] = useState<{ id: string; cwd: string; label: string } | null>(null);

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
  // Lifted (not read locally by `AccountBadge.tsx` itself) for the same
  // reason `fileTreeVisible` is lifted rather than let its own consumer
  // poll settings independently: one read on boot, kept live by the two
  // mutations below, and handed down as plain props the whole way to the
  // sidebar-header badge — a persistent piece of chrome, unlike
  // `AboutPanel.tsx`'s own one-shot `settingsGet` (that panel unmounts and
  // remounts every time it opens, so a mount-time fetch is enough for it;
  // the always-mounted badge has no equivalent remount to hang a refetch
  // on). Raw setting strings, not booleans, so `AccountBadge.tsx` can feed
  // them straight into `deriveAccountBadgeState`/`describeAuthSummary`
  // exactly like `settingsGet`'s own return shape, no extra conversion.
  const [authSignedIn, setAuthSignedIn] = useState<string | null>(null);
  const [authPersona, setAuthPersona] = useState<string | null>(null);

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
        const [resolved, signedIn, persona] = await Promise.all([
          settingsGet(AUTH_GATE_RESOLVED_SETTING_KEY),
          settingsGet(AUTH_SIGNED_IN_SETTING_KEY),
          settingsGet(AUTH_PERSONA_SETTING_KEY),
        ]);
        if (!cancelled) {
          setNeedsAuthGate(!authGateAlreadyResolved(resolved));
          setAuthSignedIn(signedIn);
          setAuthPersona(persona);
        }
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
            // THE session-restore wiring (2026-07-26). `t.id` is the id this
            // pane's session had before the app closed; handing it back as
            // `restoreId` is what lets the backend reattach to the engine
            // still running inside its tmux session — the same live Claude
            // conversation / shell, scrollback and all — instead of spawning
            // a new one. Absent (a layout written before ids were persisted,
            // or an id `deserializeLayout` rejected) it is simply not sent,
            // which is exactly the old fresh-spawn behaviour.
            //
            // `info.restored` is what actually happened, and it is NOT
            // assumed: a `restoreId` whose tmux session is gone (first
            // launch after a reboot, tmux uninstalled) comes back
            // `restored: false` with a perfectly good fresh session, and the
            // pane must look and behave identically either way.
            let info;
            try {
              info = await sessionCreate(t.project, t.engine, t.cwd, briefing, t.id);
            } catch (restoreErr) {
              // A rejected restore must never cost the user the pane. The
              // only ways `session_create` fails *because of* the id are an
              // id this build considers valid but the backend doesn't, or
              // one naming a session already live in this app — both mean
              // "you can't reattach", never "you can't have a terminal". Try
              // once more as a plain fresh spawn before giving up.
              if (t.id === undefined) throw restoreErr;
              console.error(`failed to reattach session ${t.id}, starting it fresh instead`, restoreErr);
              info = await sessionCreate(t.project, t.engine, t.cwd, briefing);
            }
            restored.push({
              id: info.id,
              project: info.project,
              engine: t.engine,
              cwd: info.cwd,
              createdAt: info.created,
              label: t.label,
              themeId: t.themeId,
              needsAttention: false,
              restored: info.restored === true,
            });
          } catch (err) {
            // If a session can't be started at all (e.g. that CLI got
            // uninstalled), skip it rather than blocking the rest of the
            // layout from restoring.
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

  // ---- per-session event streams ----------------------------------------
  // Two of them now, both subscribed here rather than inside the component
  // that renders the session: a badge/light is interesting precisely for the
  // session the user is NOT looking at. `usePerSessionEvent` owns the
  // subscribe/diff/unsubscribe dance (see its module doc — it is this file's
  // original attention effect, lifted out when the second stream arrived).
  const tabIds = useMemo(() => state.tabs.map((t) => t.id), [state.tabs]);

  // `session-attention:{id}` (founder feedback, 2026-07-24): Claude Code
  // asking for a tool permission, pattern-matched out of the raw PTY stream.
  usePerSessionEvent<unknown>(tabIds, "session-attention:", (id) => {
    dispatch({ type: "tab/attention", id });
  });

  // `session-status:{id}` (founder brief, 2026-07-26): the five-state light.
  // Fires only on a genuine transition. `notify` rides along on the payload
  // and is deliberately ignored here — the notifications panel a later
  // dispatch builds is what consumes it; this wiring only renders status.
  usePerSessionEvent<SessionStatusEvent>(tabIds, "session-status:", (id, payload) => {
    if (payload && isSessionStatus(payload.status)) {
      dispatch({ type: "tab/status", id, status: payload.status });
    }
  });

  // …and one pull per newly-seen session, because the push side only fires
  // on *change*: without this a pane that just mounted (or was just
  // restored, already mid-thought) would show the neutral "Starting" mark
  // until its session next happened to change state. The backend returns the
  // identical payload shape for both. Ids are remembered so this runs once
  // per session, not on every tab-array change; ids that go away are
  // forgotten so a re-created one pulls again.
  const pulledStatusIds = useRef<Set<string>>(new Set());
  useEffect(() => {
    const live = new Set(tabIds);
    for (const id of pulledStatusIds.current) {
      if (!live.has(id)) pulledStatusIds.current.delete(id);
    }
    for (const id of tabIds) {
      if (pulledStatusIds.current.has(id)) continue;
      pulledStatusIds.current.add(id);
      void sessionStatus(id)
        .then((event) => {
          if (event && isSessionStatus(event.status)) {
            dispatch({ type: "tab/status", id, status: event.status });
          }
        })
        .catch((err) => {
          // A missing status is a rendering detail, never a reason to break
          // the pane — the event stream will correct it on the next change.
          console.error(`session_status(${id}) failed`, err);
        });
    }
  }, [tabIds]);

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

  // The one place a session actually gets spawned: `engine === "claude"`
  // fetches its briefing first (the zero-config MCP/briefing wiring
  // DESIGN.md 5 requires happens automatically around the engine, never by
  // asking the user to configure anything), then calls `session_create`
  // with the project's cwd. Shared by the single-tab ⌘T/"+" flow
  // (`requestNewTab` below), NewWorkspaceModal's bulk-create
  // (`handleWorkspaceCreated`), and PaneHeader's 3-dot "change engine"
  // restart (`restartTabWithEngine`) so there is exactly one place that
  // knows how to spin up a session for a project — no second, drifting copy
  // of the per-engine spawn logic.
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

  // ---- new-tab flow: resolve the default engine, open it immediately ----
  // Founder ask (verbatim): "When a new terminal is created, it should
  // automatically open the default one" — no blocking picker. Resolves the
  // exact same per-project-override-else-global-else-claude chain
  // `EnginePicker`'s old `defaultEngine` resolution used
  // (`resolveDefaultEngine`), then spawns the session directly. Every
  // "new tab in project X" entry point (⌘T, the sidebar's per-project "+",
  // the pane header's split "+", the map's "Open terminal here") already
  // funnels through this one function via `onNewTabInProject`/
  // `onOpenTerminal`, so none of them need their own wiring.
  //
  // No out-of-order-response guard needed here (unlike the old
  // picker-based flow, which had one — see git history / `App.
  // requestNewTab.test.tsx` for the bug it fixed): that guard protected a
  // single shared "which project is the picker showing" UI slot from two
  // overlapping calls resolving out of order. There's no such shared slot
  // anymore — each call resolves its own engine and creates its own
  // session independently, so two concurrent calls for different projects
  // can never clobber each other regardless of which `settingsGet` settles
  // first.
  const requestNewTab = useCallback(
    async (project: ProjectInfo) => {
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
      const engine = resolveDefaultEngine(project.id, settingsMap);

      try {
        const tab = await createSessionTab(project, engine);
        dispatch({ type: "tab/opened", tab });
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
    [createSessionTab],
  );

  // ---- PaneHeader's 3-dot "Change engine" -------------------------------
  // Kills the pane's live session and spawns a brand-new one with a
  // different engine, same project/cwd, same pane/slot — DESIGN's own
  // constraint (you can't hot-swap a live PTY's engine) plus the
  // constraint from this task: "changing engine = kill+respawn using the
  // exact same existing zero-config spawn logic, nothing new invented
  // there" (`createSessionTab`, unchanged). Carries the pane's existing
  // `label` (a manual rename OR a previously auto-titled first prompt) and
  // `themeId` (its terminal-theme override) forward onto the new session —
  // both describe the PANE, not the engine underneath it, so a restart
  // must not reset either. `tab/engineRestarted` (sessions.ts) swaps the
  // `TabInfo` in place at the same array index, and `paneGrid.ts`'s
  // `syncPaneTree` 1-for-1-swap case keeps the actual grid position intact
  // — see both of those doc comments for why this is a dedicated action
  // rather than a close-then-open.
  const restartTabWithEngine = useCallback(
    async (tab: TabInfo, engine: Engine) => {
      const project = state.projects.find((p) => p.id === tab.project);
      if (!project) return;
      try {
        await sessionKill(tab.id);
      } catch (err) {
        console.error(`failed to kill session ${tab.id} before restarting with ${engine} (continuing anyway)`, err);
      }
      try {
        const spawned = await createSessionTab(project, engine);
        const restarted: TabInfo = { ...spawned, label: tab.label, themeId: tab.themeId };
        dispatch({ type: "tab/engineRestarted", oldId: tab.id, tab: restarted });
      } catch (err) {
        console.error(`failed to restart ${tab.id} with ${engine}`, err);
        setErrorBanner(`Couldn't restart with ${ENGINE_LABEL[engine]}: ${err}`);
      }
    },
    [state.projects, createSessionTab],
  );

  // PaneHeader's 3-dot "Terminal theme" picker — applied and persisted
  // immediately (the layout-persist effect below fires on every
  // `state.tabs` change, which this dispatch causes).
  const changeTabTheme = useCallback(
    (id: string, themeId: TerminalThemeId) => dispatch({ type: "tab/themeChanged", id, themeId }),
    [],
  );

  // Auto-title from the first prompt (`Terminal.tsx`'s `onFirstInput` ->
  // here). The reducer's own guard (never overwrite a tab that already has
  // a label) means this callback doesn't need to check anything itself.
  const autoTitleTab = useCallback(
    (id: string, line: string) => dispatch({ type: "tab/autoTitled", id, label: line }),
    [],
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

  // ---- ImportProjectsFlow's bulk-import ("import from other tools") -----
  // `ImportProjectsFlow.tsx` owns every Tauri call in the flow itself
  // (`detect_importable_tools`, `list_import_candidates`, and one
  // `add_project` per checked candidate — the same `addProject` wrapper
  // `NewWorkspaceModal.tsx` already uses, never reimplemented) and hands
  // back the finished `ImportBatchResult` here once the batch settles,
  // exactly the ownership split `onCreate`/`handleWorkspaceCreated`
  // established for NewWorkspaceModal: the component that shows the
  // checklist does the work, `App.tsx` reacts to the outcome. Reachable
  // from two places (`FirstRun`'s pick phase, Sidebar's permanent "import"
  // trigger) — both funnel through this one handler so there's exactly one
  // place that reloads the project list and builds the failure banner.
  const handleImportCompleted = useCallback(
    (result: ImportBatchResult) => {
      if (result.created.length > 0) {
        void reloadProjects();
        setSelectedProjectId(result.created[0].id);
      }
      const banner = importFailureBanner(result);
      if (banner) setErrorBanner(banner);
    },
    [reloadProjects],
  );

  // `ProjectMenu`'s rename (founder ask, verbatim across two messages: the
  // name "OmniAgent-ADE" — this very repo's real folder name — "must not
  // appear in the terminal title"; investigation found that's a project's
  // real, currently-unchangeable display label, not a hardcoded string —
  // see `src-tauri/src/roots.rs::rename_project`'s own doc for the full
  // root-cause story). Reloads `state.projects` on success so every pane
  // header for sessions in that project reflects the new label immediately
  // — `list_projects` (via `reloadProjects`) is the single source every one
  // of those reads from (`Workspace.tsx`'s `projectLabel` lookup,
  // `selectedProject?.label`, ...), so nothing else needs to change.
  const handleRenameProject = useCallback(
    async (project: ProjectInfo, newLabel: string) => {
      try {
        await renameProject(project.id, newLabel);
        await reloadProjects();
      } catch (err) {
        console.error(`rename_project(${project.id}) failed`, err);
        setErrorBanner(`Couldn't rename "${project.label}": ${err}`);
      }
    },
    [reloadProjects],
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
    const signedInValue = outcome.signedIn ? "true" : "false";
    const personaValue = outcome.persona ?? "";
    setAuthSignedIn(signedInValue);
    setAuthPersona(personaValue);
    void settingsSet(AUTH_GATE_RESOLVED_SETTING_KEY, "true");
    void settingsSet(AUTH_SIGNED_IN_SETTING_KEY, signedInValue);
    void settingsSet(AUTH_PERSONA_SETTING_KEY, personaValue);
  }, []);

  // `AccountBadge.tsx`'s "Sign in"/"Log out" menu rows AND (still, see that
  // component's own module doc for why it kept only a passive summary
  // line) `AboutPanel`'s history — clears the persisted outcome and
  // re-shows the gate immediately, without needing an actual app relaunch
  // or manual devtools settings surgery. Deliberately a dev-mode-only
  // affordance: nothing here checks any real credential, so "resetting" is
  // just re-running the same fake workflow. Also mirrors the reset into
  // `authSignedIn`/`authPersona` so the sidebar-header badge flips to its
  // not-signed-in placeholder the instant either menu action fires,
  // without waiting on the fire-and-forget `settingsSet` calls below.
  const resetAuthGate = useCallback(() => {
    setNeedsAuthGate(true);
    setAuthSignedIn("false");
    setAuthPersona("");
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
    // The review column belongs to a session, so it goes when that session
    // does. Its cwd would still resolve to a perfectly valid repo, which is
    // exactly the problem: the panel would keep showing a live-looking review
    // headed by the name of a pane that isn't there any more.
    setReviewTarget((target) => (target?.id === id ? null : target));
  }, []);

  // ---- ⌘T new tab / ⌘K palette / ⌘N new workspace. ⌘W is deliberately
  // left alone — see the module comment at the bottom of this file for
  // why. No existing binding (native menu or app-level) claimed ⌘N before
  // this — `lib.rs`'s `.menu(tauri::menu::Menu::default)` only supplies the
  // standard macOS Quit/Hide/Edit/Window items, no File/New — so it's wired
  // here exactly like ⌘T/⌘K, the established place app-level shortcuts that
  // need live UI state (as opposed to a static native-menu event) already
  // live. -------------------------------------------------------------
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (!e.metaKey) return;
      if (e.key.toLowerCase() === "t") {
        e.preventDefault();
        if (selectedProject) void requestNewTab(selectedProject);
      } else if (e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen((open) => !open);
      } else if (e.key.toLowerCase() === "n") {
        e.preventDefault();
        setNewWorkspaceOpen(true);
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
          newWorkspaceOpen={newWorkspaceOpen}
          onOpenNewWorkspace={() => setNewWorkspaceOpen(true)}
          onCloseNewWorkspace={() => setNewWorkspaceOpen(false)}
          onRenameProject={(p, label) => void handleRenameProject(p, label)}
          onImportCompleted={handleImportCompleted}
          ingestion={ingestion}
          view={view}
          onSetView={setView}
          fileTreeVisible={fileTreeVisible}
          onToggleFileTree={toggleFileTree}
          onResetAuthGate={resetAuthGate}
          authSignedIn={authSignedIn}
          authPersona={authPersona}
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
          onChangeEngine={(tab, engine) => void restartTabWithEngine(tab, engine)}
          onChangeTheme={changeTabTheme}
          onOpenCodeReview={(tab) =>
            setReviewTarget({ id: tab.id, cwd: tab.cwd, label: tabDisplayLabel(tab) })
          }
          onFirstInput={autoTitleTab}
          hidden={view !== "workspace"}
          initialLayouts={pendingLayoutsRef.current}
        />
        <BrainMap
          projects={state.projects}
          onOpenTerminal={(p) => void requestNewTab(p)}
          hidden={view !== "map"}
          livePollMs={ingestion?.running ? INGESTION_POLL_MS : undefined}
        />
        {/* One right-hand dock, one panel at a time — see `reviewTarget`'s
            declaration for why these are mutually exclusive rather than
            side by side, and why closing the review column restores the
            file tree to whatever the user had chosen. */}
        {reviewTarget ? (
          <CodeReviewPanel
            key={reviewTarget.id}
            repoPath={reviewTarget.cwd}
            sessionLabel={reviewTarget.label}
            onClose={() => setReviewTarget(null)}
          />
        ) : (
          fileTreeVisible && (
            <FileTree project={selectedProject} activeTabId={state.activeTabId} onClose={toggleFileTree} />
          )
        )}
      </div>

      {needsAuthGate === true && <AuthGate onResolved={handleAuthGateResolved} />}

      {needsAuthGate === false && needsOnboarding === true && !firstRunDismissed && (
        <FirstRun
          ingestion={ingestion}
          existingProjects={state.projects}
          onRequestView={setView}
          onOpenTerminal={(p) => void requestNewTab(p)}
          onImportCompleted={handleImportCompleted}
          onDismiss={() => setFirstRunDismissed(true)}
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

// The app shell: a `view` switch between the Phase 5 terminal workspace and
// the Phase 6 brain map (see the module-level comment at the bottom of this
// file, written by the Phase 5 agent, for the integration plan this follows).
import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import "./App.css";
import Sidebar from "./components/Sidebar";
import Workspace from "./components/Workspace";
import CommandPalette from "./components/CommandPalette";
import CodeReviewPanel from "./components/CodeReviewPanel";
import AppChrome from "./components/AppChrome";
import NewChooserModal from "./components/NewChooserModal";
import NewSessionModal from "./components/NewSessionModal";
import { NewTerminalModal } from "./components/NewTerminalModal";
import ClosePaneConfirm from "./components/ClosePaneConfirm";
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
  UNGROUPED_SESSION_ID,
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
import { MAX_PANES, type LayoutPreset } from "./state/paneGrid";
import { importFailureBanner, type ImportBatchResult } from "./state/importState";
import {
  CLOSED_WORKSPACES_SETTING_KEY,
  deserializeClosedWorkspaces,
  nextSelectedAfterClose,
  openWorkspaces,
  serializeClosedWorkspaces,
} from "./state/closedWorkspaces";
import { isSessionStatus, type SessionStatusEvent } from "./state/sessionStatus";
import { sessionNameFromPrompt } from "./state/newSessionState";
import {
  adjacentSessionTab,
  groupTabsBySession,
  newSessionGroupId,
  nextSessionName,
  sessionGroupForNewPane,
  visibleSessionGroupId,
  type SessionGroup,
} from "./state/sessionGroups";
import {
  NOTIFICATIONS_SETTING_KEY,
  deriveNotification,
  deserializeNotifications,
  initialNotificationsState,
  notificationsReducer,
  serializeNotifications,
  type NotificationEntry,
} from "./state/notifications";
import type { CreateChoice } from "./state/newChooserState";
import { ENGINE_LABEL } from "./theme";
import type { TerminalThemeId } from "./lib/terminalThemes";
import { ownsCtrlOnlyShortcut } from "./lib/keyboard";
import { usePerSessionEvent } from "./lib/usePerSessionEvent";
import {
  agentCheckInstalled,
  agentInstall,
  getBriefing,
  ingestionStatus,
  listProjects,
  onAgentInstallProgress,
  renameProject,
  rootsList,
  sessionCreate,
  sessionKill,
  sessionStatus,
  sessionWrite,
  settingsGet,
  settingsSet,
  type IngestionStatus,
} from "./lib/tauri";
import { agentsReducer, initialAgentsState, type Agent } from "./state/agents";

type View = "workspace" | "map";

/** Task 8.1: how often `App.tsx` polls `ingestion_status` — PLAN.md's own
 * cadence ("called every ~2s from the frontend while ingestion runs"). This
 * one poll loop backs BOTH FirstRun's onboarding HUD and BrainMap's
 * `livePollMs` live-growth feed (and, incidentally, the post-"Rebuild
 * brain" project-list refresh) — see the boot-adjacent effect below for
 * why a single, always-running poll is simpler than start/stop plumbing
 * threaded through three different triggers. */
const INGESTION_POLL_MS = 2000;

/** Resolves a group id (from `visibleSessionGroupId`/`sessionGroupForNewPane`
 * — both only ever return an id, `string | null`) to the full `SessionGroup`
 * object. Shared by `visibleSession`/`joinTargetSession` below: same
 * `groupTabsBySession` lookup, two different id inputs answering two
 * different questions — see those consts' own docs for why the two must
 * stay separate rather than collapsing into one shared derivation. */
function findSessionGroup(
  tabs: TabInfo[],
  activeTabId: string | null,
  project: string | null,
  groupId: string | null,
): SessionGroup | null {
  if (groupId === null) return null;
  return (
    groupTabsBySession(tabs, activeTabId)
      .find((g) => g.project === project)
      ?.sessions.find((s) => s.id === groupId) ?? null
  );
}

function App() {
  const [state, dispatch] = useReducer(sessionsReducer, initialSessionsState);
  const [agentState, agentDispatch] = useReducer(agentsReducer, initialAgentsState);
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);
  const [paletteOpen, setPaletteOpen] = useState(false);
  // ⌘N — since 2026-07-26 it no longer opens the workspace dialog directly
  // (Bruno: "cmd + N now has a new meaning. Either a new session or a new
  // workspace"). It opens `NewChooserModal` first; that hands back
  // "session" or "workspace" and exactly one of the two dialogs below
  // opens. `newWorkspaceOpen` stays lifted out of `Sidebar.tsx` (which
  // still owns its OTHER overlays locally, e.g. aboutOpen/reviewOpen/
  // importOpen) because the sidebar's "+" opens it too.
  const [newChooserOpen, setNewChooserOpen] = useState(false);
  /** The pane ⌘W is asking about, if any — see the ⌘W handler below. */
  const [closingTabId, setClosingTabId] = useState<string | null>(null);
  const [newWorkspaceOpen, setNewWorkspaceOpen] = useState(false);
  const [newSessionOpen, setNewSessionOpen] = useState(false);
  // ⌘T (Task 9, 2026-07-27): used to spawn the default engine directly
  // (`requestNewTab(selectedProject)`, no UI in between — see that
  // function's own doc). Now opens `NewTerminalModal` instead, same
  // "session already has MAX_PANES terminals" refusal still guarding the
  // keystroke BEFORE the modal opens (see the keydown handler below) —
  // only the happy path grew a naming/engine step.
  const [newTerminalOpen, setNewTerminalOpen] = useState(false);
  const [errorBanner, setErrorBanner] = useState<string | null>(null);
  const [view, setView] = useState<View>("workspace");
  const restoredRef = useRef(false);
  // Founder feedback (Bruno, 2026-07-25, verbatim): "nice to have a
  // folder/file navigation on the right panel" — originally a collapsible
  // right-hand dock (a `fileTreeVisible` boolean lived here, persisted via
  // the settings table like `LAYOUT_SETTING_KEY`/`REVIEW_MEMORY_SETTING_KEY`)
  // because the same founder had twice been explicit that UI chrome must not
  // compete with the terminal workspace for attention. Left-pane redesign,
  // Task 6 (2026-07-27): the tree moved into the sidebar as a permanent FILES
  // section instead — always there, no toggle to lose track of — so that
  // boolean and its persistence are gone; see `Sidebar.tsx`'s `.sidebar-files`
  // and `FileTree.tsx`'s `embedded` prop.
  // Workspaces the user has closed (founder ask: "add the possibility to
  // close a workspace, on hover"). Held here rather than derived from the
  // brain because the brain is deliberately not told — closing is a window
  // close, not a delete (see `state/closedWorkspaces.ts`). Restored on boot
  // and written back on every change, so a closed workspace does not quietly
  // reappear on the next launch.
  const [closedProjectIds, setClosedProjectIds] = useState<Set<string>>(() => new Set());

  // ---- the per-session code review column (founder ask, 2026-07-26) -----
  //
  // `null` = closed. When open it holds the session the panel is reviewing,
  // captured at open time from the pane whose 3-dot menu was used — which is
  // the whole "Make sure that the code panel is for session, okay?" contract.
  // Opening it from a different pane re-targets it rather than stacking a
  // second column.
  //
  // THE RIGHT-HAND DOCK: used to be shared with the file tree, mutually
  // exclusive between the two because at realistic window widths a file tree
  // (260) plus a review column (440) wouldn't both fit next to a usable
  // terminal grid on a 1440px MacBook. Left-pane redesign, Task 6
  // (2026-07-27) moved the file tree into the sidebar as permanent, embedded
  // chrome — see `fileTreeVisible`'s old declaration above — so this column
  // is now the dock's only occupant; `reviewTarget` alone decides whether
  // anything renders there.
  const [reviewTarget, setReviewTarget] = useState<{ id: string; cwd: string; label: string } | null>(null);


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
  // Lifted (not read locally by `AccountBadge.tsx` itself) so it's a single
  // read on boot, kept live by the two mutations below, and handed down as
  // plain props the whole way to the sidebar-header badge — a persistent
  // piece of chrome, unlike
  // `AboutPanel.tsx`'s own one-shot `settingsGet` (that panel unmounts and
  // remounts every time it opens, so a mount-time fetch is enough for it;
  // the always-mounted badge has no equivalent remount to hang a refetch
  // on). Raw setting strings, not booleans, so `AccountBadge.tsx` can feed
  // them straight into `deriveAccountBadgeState`/`describeAuthSummary`
  // exactly like `settingsGet`'s own return shape, no extra conversion.
  const [authSignedIn, setAuthSignedIn] = useState<string | null>(null);
  const [authPersona, setAuthPersona] = useState<string | null>(null);

  // ---- notifications (founder ask, 2026-07-26) -------------------------
  // Its own reducer beside `sessionsReducer` rather than a slice of it:
  // notifications outlive the sessions they describe (they're restored from
  // the settings table on boot, sessions are not), so folding them into
  // `SessionsState` would tie a list that persists to a list that doesn't.
  // The rule for what becomes a notification lives in
  // `state/notifications.ts`; the rule for *which statuses* notify at all
  // lives in Rust and rides on the event as `notify`.
  const [notifications, notificationsDispatch] = useReducer(
    notificationsReducer,
    initialNotificationsState,
  );
  const notificationsRestoredRef = useRef(false);

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

  // ---- Load installed agents on startup ----
  useEffect(() => {
    (async () => {
      try {
        const installed = await agentCheckInstalled();
        agentDispatch({ type: "agents/loaded", installed: installed as Agent[] });

        // Load last-selected from settings
        const lastSelected = await settingsGet("last_selected_agents");
        if (lastSelected) {
          try {
            const parsed = JSON.parse(lastSelected);
            if (Array.isArray(parsed)) {
              agentDispatch({ type: "agents/selected", agents: parsed });
            }
          } catch {
            // Ignore parse errors
          }
        }
      } catch (err) {
        console.error("Failed to load agent state", err);
      }
    })();
  }, []);

  // ---- boot: load the sidebar's project list + restore the last layout --
  useEffect(() => {
    let cancelled = false;

    (async () => {
      // The closed set is read BEFORE the project list loads: the sidebar
      // must never paint every workspace and then collapse to the open ones
      // a beat later — that flash read as "two different lists" on launch.
      try {
        const rawClosed = await settingsGet(CLOSED_WORKSPACES_SETTING_KEY);
        const closed = deserializeClosedWorkspaces(rawClosed);
        if (!cancelled && closed.length > 0) setClosedProjectIds(new Set(closed));
      } catch (err) {
        // Fail open: showing a workspace the user closed is a small
        // annoyance, hiding one they didn't is lost work.
        console.error("failed to read closed_workspaces setting, showing every workspace", err);
      }

      await reloadProjects();

      try {
        const roots = await rootsList();
        if (!cancelled) setNeedsOnboarding(roots.length === 0);
      } catch (err) {
        console.error("failed to load project roots", err);
        if (!cancelled) setNeedsOnboarding(false); // fail open — never trap the user behind a broken check
      }

      // Recent notifications survive a relaunch (see
      // `state/notifications.ts`'s persistence note — "somewhere else"
      // includes "quit for the night", and the reference panel's own rows
      // read "3 days ago"). Best effort: a failed read just starts empty.
      try {
        const rawNotifications = await settingsGet(NOTIFICATIONS_SETTING_KEY);
        const entries = deserializeNotifications(rawNotifications);
        if (!cancelled && entries.length > 0) {
          notificationsDispatch({ type: "notifications/restored", entries });
        }
      } catch (err) {
        console.error("failed to restore notifications", err);
      } finally {
        notificationsRestoredRef.current = true;
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
              // The pane's session (pane group) — restored alongside its
              // label/theme so the sidebar's project -> session -> pane tree
              // comes back exactly as the user left it. Absent for layouts
              // written before groups existed, which is handled by
              // `sessionGroups.ts`'s implicit group rather than by inventing
              // one here.
              group: t.group,
              // …and its NAME, so a relaunch comes back with the sessions
              // the user named rather than a fresh "Session 1, 2, 3…".
              groupLabel: t.groupLabel,
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

  // ---- …and the notification list, same shape, same guard ---------------
  useEffect(() => {
    if (!notificationsRestoredRef.current) return;
    void settingsSet(NOTIFICATIONS_SETTING_KEY, serializeNotifications(notifications.entries));
  }, [notifications.entries]);

  // ---- the per-session event stream -------------------------------------
  // Subscribed here rather than inside the component that renders the
  // session: a light (and a notification) is interesting precisely for the
  // session the user is NOT looking at. `usePerSessionEvent` owns the
  // subscribe/diff/unsubscribe dance.
  //
  // `session-attention:{id}` used to be a SECOND stream here, driving the
  // latched red `needsAttention` badge. It's gone (2026-07-26): the same
  // underlying detection in `sessions.rs` also produces
  // `awaiting_approval`/`error` on this stream, so the badge was a second
  // visual language for a fact the five-state light already carried, with
  // a different lifetime. See `TabInfo`'s doc in `state/sessions.ts` for
  // the full reconciliation.
  const tabIds = useMemo(() => state.tabs.map((t) => t.id), [state.tabs]);

  // The focus context the notification rule reads, mirrored into a ref in a
  // LAYOUT effect — i.e. synchronously at commit, before anything can be
  // painted or any passive effect runs.
  //
  // This is not ceremony: `usePerSessionEvent` re-points its handler in a
  // *passive* effect, so an event arriving in the window between a commit
  // and that flush would otherwise be judged against the previous render's
  // idea of "which pane is focused and which project is on screen". That
  // window is real in the app (a status event can land in the same tick the
  // user switches project) and it is exactly the wrong thing to be stale
  // about: getting it wrong means either a notification for the pane the
  // user is staring at, or — worse — silence for one they can't see. Read
  // through the ref, the rule always sees the state that is actually
  // committed.
  const notifyContextRef = useRef({
    tabs: state.tabs,
    projects: state.projects,
    activeTabId: state.activeTabId,
    selectedProjectId,
    view,
  });
  useLayoutEffect(() => {
    notifyContextRef.current = {
      tabs: state.tabs,
      projects: state.projects,
      activeTabId: state.activeTabId,
      selectedProjectId,
      view,
    };
  });

  // Session prompt (design §3 New session): delivered to the first agent
  // pane after its first status event — the engine's CLI is accepting input
  // by the time it starts reporting status. Written WITHOUT a trailing
  // newline so nothing auto-executes; the user reviews and presses Enter.
  // `handleSessionCreated` queues tabId -> prompt here; the status-event
  // callback below delivers and deletes it, so a second status event for the
  // same tab finds nothing queued and writes nothing twice.
  // ponytail: if an engine ever swallows early stdin, gate this on
  // status === "ready" instead of first-event.
  const pendingFirstPrompt = useRef<Map<string, string>>(new Map());

  // `session-status:{id}` (founder brief, 2026-07-26): the five-state light
  // AND — since this dispatch — the notification feed. Fires only on a
  // genuine transition. `payload.notify` is the backend's precomputed
  // "green/yellow/red only" rule and is consumed as-is, never re-derived
  // (see `state/notifications.ts`). This closure is re-read from a ref on
  // every render (`usePerSessionEvent`), so the focus/visibility state it
  // checks is always current at the moment the event lands.
  usePerSessionEvent<SessionStatusEvent>(tabIds, "session-status:", (id, payload) => {
    if (!payload || !isSessionStatus(payload.status)) return;
    dispatch({ type: "tab/status", id, status: payload.status });

    const queuedPrompt = pendingFirstPrompt.current.get(id);
    if (queuedPrompt !== undefined) {
      pendingFirstPrompt.current.delete(id);
      void sessionWrite(id, queuedPrompt);
    }

    const { tabs, projects, activeTabId, selectedProjectId: onScreenProject, view: currentView } =
      notifyContextRef.current;
    const tab = tabs.find((t) => t.id === id);
    const entry = deriveNotification({
      event: payload,
      tab,
      projectLabel: projects.find((p) => p.id === tab?.project)?.label ?? tab?.project ?? "",
      focusedTabId: activeTabId,
      selectedProjectId: onScreenProject,
      view: currentView,
      windowVisible: typeof document === "undefined" || document.visibilityState !== "hidden",
      now: Date.now(),
    });
    if (entry) notificationsDispatch({ type: "notification/added", entry });
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

  // The workspaces the sidebar lists: what the brain knows, minus what the
  // user has closed. Everything else — the map, the palette, the brain
  // itself — deliberately still sees all of them: closing a workspace closes
  // a window, it does not unlearn a project.
  const visibleProjects = useMemo(
    () => openWorkspaces(state.projects, closedProjectIds),
    [state.projects, closedProjectIds],
  );

  // ---- default the sidebar's "current project" once projects arrive -----
  useEffect(() => {
    if (selectedProjectId === null && visibleProjects.length > 0) {
      setSelectedProjectId(visibleProjects[0].id);
    }
  }, [visibleProjects, selectedProjectId]);

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
  //
  // `cwd` overrides the project's own folder — the "or subfolder" half of
  // Bruno's session brief (`NewSessionModal` validates that the override is
  // genuinely inside the project before it ever gets here). `group` is the
  // session (pane group) the new pane belongs to, and `groupLabel` is that
  // session's NAME — carried on every one of its panes (see
  // `TabInfo.groupLabel`), which is what makes it survive a relaunch.
  const createSessionTab = useCallback(
    async (
      project: ProjectInfo,
      engine: Engine,
      group: string,
      groupLabel: string | undefined,
      cwd?: string,
    ): Promise<TabInfo> => {
      const briefing = engine === "claude" ? await getBriefing(project.id) : undefined;
      const info = await sessionCreate(project.id, engine, cwd ?? project.path ?? project.id, briefing);
      return {
        id: info.id,
        project: info.project,
        engine,
        cwd: info.cwd,
        createdAt: info.created,
        group,
        groupLabel,
      };
    },
    [],
  );

  /** Takes a workspace back out of the closed set (and persists that), so
   * anything that *opens* it — a terminal from the map or the palette,
   * re-adding the folder, importing it — undoes the close instead of
   * leaving a workspace with live terminals hidden from the sidebar. A
   * no-op for a workspace that was never closed, so every entry point can
   * call it unconditionally. */
  const reopenWorkspace = useCallback((projectId: string) => {
    setClosedProjectIds((closed) => {
      if (!closed.has(projectId)) return closed;
      const next = new Set(closed);
      next.delete(projectId);
      void settingsSet(CLOSED_WORKSPACES_SETTING_KEY, serializeClosedWorkspaces(next));
      return next;
    });
  }, []);

  // ---- new-tab flow: resolve the default engine, open it immediately ----
  // Founder ask (verbatim): "When a new terminal is created, it should
  // automatically open the default one" — no blocking picker. Resolves the
  // exact same per-project-override-else-global-else-claude chain
  // `EnginePicker`'s old `defaultEngine` resolution used
  // (`resolveDefaultEngine`), then spawns the session directly. Every
  // "new tab in project X" entry point (the sidebar's per-project "+",
  // the pane header's split "+", the map's "Open terminal here") already
  // funnels through this one function via `onNewTabInProject`/
  // `onOpenTerminal`, so none of them need their own wiring. ⌘T itself
  // moved to `NewTerminalModal` (Task 9) — its confirm handler is the one
  // caller that passes `opts` below, so this function's engine-resolution
  // path stays a plain fallback for every OTHER entry point, unchanged.
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
  //
  // The per-project-override-else-global-else-claude resolution itself lives
  // in `defaultEngineFor` just below, shared with `EmptyWorkspace`'s
  // zero-decision "Start session" (`handleQuickStart`) — both mean "the
  // engine this project opens by default", and two copies of that chain
  // would be two places to forget a settings key.
  const defaultEngineFor = useCallback(async (projectId: string): Promise<Engine> => {
    let perProject: string | null = null;
    let global: string | null = null;
    try {
      [perProject, global] = await Promise.all([
        settingsGet(defaultEngineSettingKey(projectId)),
        settingsGet(GLOBAL_DEFAULT_ENGINE_KEY),
      ]);
    } catch (err) {
      console.error("failed to read engine-default settings, falling back to claude", err);
    }
    const settingsMap: Record<string, string | undefined> = {};
    if (perProject) settingsMap[defaultEngineSettingKey(projectId)] = perProject;
    if (global) settingsMap[GLOBAL_DEFAULT_ENGINE_KEY] = global;
    return resolveDefaultEngine(projectId, settingsMap);
  }, []);

  const requestNewTab = useCallback(
    async (project: ProjectInfo, opts?: { engine?: Engine; label?: string }) => {
      setSelectedProjectId(project.id);
      reopenWorkspace(project.id);

      // A single new pane joins the session you're already in for that
      // project (`sessionGroupForNewPane`) — ⌘T, the sidebar "+" and the
      // pane header's split all mean "one more terminal here", not "a new
      // session". A project with no panes at all starts one, named.
      const existingGroup = sessionGroupForNewPane(state.tabs, project.id, state.activeTabId);

      // The approved-shape ladder tops out at 2x4 (`paneGrid.ts`'s
      // `GRID_LADDER` — founder: "and then no more terminals are
      // available"), so refuse the 9th pane instead of spawning a live
      // session the grid has no approved shape for. Per SESSION, not per
      // project or per app: a workspace can hold as many 8-pane sessions as
      // the machine will take (`isUnderPressure` is the softer, advisory
      // warning about that).
      const inSession = state.tabs.filter(
        (t) => t.project === project.id && (t.group ?? UNGROUPED_SESSION_ID) === existingGroup,
      ).length;
      if (existingGroup !== null && inSession >= MAX_PANES) {
        setErrorBanner(
          `This session already has ${MAX_PANES} terminals — the most one grid holds. Close one, or start a new session (⌘N).`,
        );
        return;
      }

      // `opts.engine` (NewTerminalModal's chosen engine, Task 9) overrides
      // the usual per-project/global default resolution — skip the
      // `settingsGet` round-trip entirely when the caller already picked
      // one explicitly.
      const engine = opts?.engine ?? (await defaultEngineFor(project.id));

      try {
        // Joining an existing session means inheriting its name from the
        // panes already in it (`undefined` for a pre-naming session, which
        // keeps showing its derived default) — never minting a second name
        // for a session that already has one.
        const group = existingGroup ?? newSessionGroupId();
        const groupLabel =
          existingGroup === null
            ? nextSessionName(state.tabs, project.id)
            : state.tabs.find(
                (t) => t.project === project.id && (t.group ?? UNGROUPED_SESSION_ID) === existingGroup && t.groupLabel,
              )?.groupLabel;
        const tab = await createSessionTab(project, engine, group, groupLabel);
        dispatch({ type: "tab/opened", tab });
        // `opts.label` (NewTerminalModal's name field) renames the pane
        // right after it opens — a second, tiny dispatch rather than
        // threading a label through `createSessionTab`/`sessionCreate`,
        // which every OTHER caller of this function has no use for.
        // `tab/renamed` trims and no-ops on empty, so this is safe to fire
        // unconditionally whenever the caller passed one.
        if (opts?.label !== undefined) {
          dispatch({ type: "tab/renamed", id: tab.id, label: opts.label });
        }
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
    [createSessionTab, reopenWorkspace, defaultEngineFor, state.tabs, state.activeTabId],
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
        // `tab.group`/`tab.groupLabel` ride along for the same reason
        // `label`/`themeId` do: restarting the engine must not move the pane
        // out of the session it belongs to, nor cost that session its name.
        const spawned = await createSessionTab(
          project,
          engine,
          tab.group ?? newSessionGroupId(),
          tab.groupLabel,
          tab.cwd,
        );
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

  // ---- Agent installation handler ----
  async function handleInstallAgent(agent: Agent) {
    agentDispatch({ type: "agents/install_started", agent });

    // The listener drops ITSELF on the terminal event, rather than being
    // dropped in a `finally` once `agentInstall` resolves. The backend emits
    // "completed" and *then* returns, and event delivery to the webview is
    // async IPC — so unsubscribing the moment the await resolves can race the
    // very event this is waiting for, and losing it leaves the agent stuck in
    // `installing` with its pane dimmed forever. Unsubscribing only once the
    // event is in hand cannot lose it.
    //
    // It still has to be dropped: each Install/Retry click registers its own
    // listener, and one that outlived its install would keep dispatching for
    // every later install of any agent.
    let unlisten: (() => void) | undefined;
    let settled = false;

    const finish = (action: Parameters<typeof agentDispatch>[0]) => {
      if (settled) return; // first terminal signal wins
      settled = true;
      agentDispatch(action);
      unlisten?.();
    };

    try {
      unlisten = await onAgentInstallProgress(agent, (status) => {
        if (status === "completed") finish({ type: "agents/install_completed", agent });
        else if (status === "failed") finish({ type: "agents/install_failed", agent });
      });
      // A fast install can settle before the line above assigned `unlisten`,
      // leaving `finish`'s own call a no-op — so drop it here instead.
      if (settled) unlisten();

      await agentInstall(agent);
    } catch (err) {
      console.error(`Failed to install ${agent}:`, err);
      finish({ type: "agents/install_failed", agent });
    }
  }

  // ---- NewWorkspaceModal's create (Sidebar's "+" -> New workspace) ------
  // `add_project`, the folder pick and the ingest/review toggles all already
  // ran inside `NewWorkspaceModal.tsx` by the time this fires (see that
  // component's module doc for the ownership split) — `project` exists.
  //
  // Task 12 removed everything else this used to do. It no longer spawns a
  // session per checked engine, because the dialog no longer asks for
  // engines or a layout: adding a workspace and starting terminals are two
  // separate decisions now. So this only lands the user *in* the new
  // workspace and hands straight over to `NewSessionModal`, which is the
  // one place that decides what runs where. The old bulk-create loop (and
  // its `last_selected_agents` write, and its partial-failure banner) moved
  // wholesale to `handleSessionCreated` below — one implementation, not
  // two near-identical ones.
  const handleWorkspaceCreated = useCallback(
    (project: ProjectInfo) => {
      void reloadProjects();
      setSelectedProjectId(project.id);
      // `add_project` upserts by folder basename, so re-adding a closed
      // folder returns the id still sitting in the closed set — un-hide it,
      // the same contract every other "opens the workspace" path honours.
      reopenWorkspace(project.id);
      setView("workspace");
      // Straight into "what are you doing?" — a brand-new workspace with no
      // terminals is exactly the state this modal exists to resolve, and
      // asking immediately is what makes dropping the engine checkboxes an
      // improvement rather than a missing step.
      setNewSessionOpen(true);
    },
    [reloadProjects, reopenWorkspace],
  );

  // ---- NewSessionModal's create (⌘N -> "Session") -----------------------
  // The sibling of `handleWorkspaceCreated` above, and deliberately almost
  // the same function: same per-engine spawn, same one-bulk-dispatch,
  // same partial-failure handling, same layout hint. Two differences, and
  // they are the whole definition of a session (founder brief, 2026-07-26:
  // "Each session can be created with a new layout, agents, etc... but in
  // the same folder or subfolder"):
  //
  // 1. no `add_project` — the project already exists, this runs inside it;
  // 2. `cwd` is the project folder or a validated subfolder of it, not a
  //    brand-new folder chosen from anywhere on disk.
  //
  // `slots` is one engine per terminal, in pane order (Task 10) — the
  // dialog decided *which pane runs what*, so this loop spawns them in that
  // exact order rather than deduplicating; two Claude terminals in one
  // session is a normal thing to ask for.
  //
  // `prompt` is the answer to the dialog's only question ("what are you
  // doing?"). It names the session (`sessionNameFromPrompt` — trimmed,
  // collapsed, capped) and, from Task 11, is delivered as the first prompt
  // to the session's lead terminal. `EmptyWorkspace`'s typed goal comes
  // through the same parameter, which is why that flow needs no naming code
  // of its own.
  const handleSessionCreated = useCallback(
    async (project: ProjectInfo, cwd: string, slots: Engine[], prompt: string) => {
      setNewSessionOpen(false);
      setSelectedProjectId(project.id);

      const group = newSessionGroupId();
      // No prompt still means a named session: `nextSessionName` is the
      // workspace's own numbering, and it is *stored* on the panes rather
      // than derived at render time — see `sessionGroups.ts`'s module doc
      // for why (a positional name renames every session below one that
      // closes, which is the opposite of a name).
      const groupLabel = sessionNameFromPrompt(prompt) ?? nextSessionName(state.tabs, project.id);
      const created: TabInfo[] = [];
      const failed: Engine[] = [];
      for (const engine of slots) {
        try {
          created.push(await createSessionTab(project, engine, group, groupLabel, cwd));
        } catch (err) {
          console.error(`failed to start ${engine} in ${cwd}`, err);
          failed.push(engine);
        }
      }

      if (created.length > 0) {
        dispatch({ type: "tabs/opened_bulk", tabs: created });
      }

      // "The last one that they created should be pre-selected" (founder
      // rule, encoded in `getDefaultAgentSelection`) — this is the write
      // that makes `lastSelected` mean anything. It used to live in
      // `handleWorkspaceCreated`'s engine-spawn loop; when Task 12 removed
      // that loop it came here, because choosing engines is now this
      // dialog's job, and without a writer `lastSelected` would stay `[]`
      // forever and every future dialog would fall through to `["shell"]`.
      //
      // Deduplicated (`slots` is one engine PER PANE, so two Claude
      // terminals is a normal ask) and recorded as the user's *choice*,
      // not as whatever happened to boot — an engine that failed to start
      // is still the engine they asked for. Same key and JSON-array
      // encoding the boot-time reader at the top of this file parses.
      const chosen = [...new Set(slots)] as Agent[];
      if (chosen.length > 0) {
        void settingsSet("last_selected_agents", JSON.stringify(chosen));
        agentDispatch({ type: "agents/selected", agents: chosen });
      }

      // Task 11: the dialog's "what are you doing?" answer becomes the
      // first thing typed into the session's lead terminal — the first
      // spawned pane that isn't a bare shell, since a shell has no agent CLI
      // to hand a prompt to. Queued here, delivered by the status-event
      // callback above once that pane reports its first status.
      const promptText = prompt.trim();
      if (promptText.length > 0) {
        const target = created.find((t) => t.engine !== "shell");
        if (target) pendingFirstPrompt.current.set(target.id, promptText);
      }

      if (failed.length > 0) {
        // Deduplicated: with one engine per slot, the same CLI can fail
        // twice in one batch, and "couldn't run Shell, Shell" reads like a
        // bug in the message rather than a fact about the machine.
        const names = [...new Set(failed)].map((e) => ENGINE_LABEL[e]).join(", ");
        setErrorBanner(
          created.length > 0
            ? `Started the session, but couldn't run ${names} — the rest are up.`
            : `Couldn't start ${names} in ${project.label} — no panes were opened.`,
        );
      }

      setView("workspace");
    },
    [createSessionTab, state.tabs],
  );

  // ---- EmptyWorkspace's "Start session" ---------------------------------
  // The zero-decision sibling of `handleSessionCreated` above, and nothing
  // more than a set of defaults in front of it: the project's own folder,
  // the project's default engine (`defaultEngineFor` — same chain ⌘T uses),
  // and one pane per slot in the chosen layout, so picking "4" gives four
  // terminals in a 2x2 rather than four slots waiting for engines that were
  // never chosen. The typed goal becomes the session's name.
  const handleQuickStart = useCallback(
    async (project: ProjectInfo, layout: LayoutPreset, goal: string) => {
      reopenWorkspace(project.id);
      const engine = await defaultEngineFor(project.id);
      await handleSessionCreated(
        project,
        project.path ?? project.id,
        Array.from({ length: layout }, () => engine),
        goal,
      );
    },
    [defaultEngineFor, handleSessionCreated, reopenWorkspace],
  );

  // ⌘N's chooser resolved. "Session" needs a project to run in — with none
  // selected (a brand-new install with no projects at all) the only
  // meaningful thing to create is a workspace, so it falls through to that
  // rather than opening a dialog with nowhere to put its panes.
  const handleCreateChoice = useCallback(
    (choice: CreateChoice) => {
      setNewChooserOpen(false);
      if (choice === "workspace" || !selectedProject) setNewWorkspaceOpen(true);
      else setNewSessionOpen(true);
    },
    [selectedProject],
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
        // Importing a previously closed folder reopens it, same as re-adding
        // it via "+" — see `state/closedWorkspaces.ts`.
        for (const project of result.created) reopenWorkspace(project.id);
      }
      const banner = importFailureBanner(result);
      if (banner) setErrorBanner(banner);
    },
    [reloadProjects, reopenWorkspace],
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

  // The sidebar's double-click-to-rename on a session row (founder brief:
  // "Each session has a name and can be renamed"). Writes the name onto
  // every pane in the group; the layout-persist effect below then carries it
  // to the settings table, so the name survives a relaunch exactly like a
  // pane's own rename does.
  const renameSession = useCallback(
    (project: ProjectInfo, group: string, name: string) =>
      dispatch({ type: "session/renamed", project: project.id, group, name }),
    [],
  );

  // `AuthGate`'s `onResolved` — fires exactly once, whichever path the user
  // took (skip-from-login, or personalize's answer/skip). Persists all
  // three settings the gate cares about and dismisses it immediately
  // (optimistic — same fire-and-forget `settingsSet`-after-local-flip shape
  // `ReviewPanel.tsx`'s own `toggleReviewMode` uses; the writes here don't
  // block the UI either).
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

  // ---- clicking a notification (the feature's whole point) --------------
  // Bruno's own rationale for notifications is that he's somewhere else, so
  // the row has to take him back. Three cases, in order of how much is
  // still there:
  //
  // 1. the session is live -> select its project and focus its pane
  //    (`activateTab` already does both);
  // 2. the session is gone but its project isn't -> select the project, so
  //    he lands where the work happened;
  // 3. neither exists any more (project removed) -> say so in the banner
  //    rather than silently doing nothing.
  const handleNotificationSelect = useCallback(
    (entry: NotificationEntry) => {
      const tab = state.tabs.find((t) => t.id === entry.sessionId);
      if (tab) {
        setView("workspace");
        setSelectedProjectId(tab.project);
        dispatch({ type: "tab/activated", id: tab.id });
        return;
      }
      if (state.projects.some((p) => p.id === entry.project)) {
        setView("workspace");
        setSelectedProjectId(entry.project);
        setErrorBanner(`"${entry.title}" isn't running any more — opened ${entry.projectLabel} instead.`);
        return;
      }
      setErrorBanner(`"${entry.title}" is gone: ${entry.projectLabel} isn't in your projects any more.`);
    },
    [state.tabs, state.projects],
  );

  // ---- closing a whole workspace (founder ask: "add the possibility to
  // close a workspace, on hover") --------------------------------------
  //
  // The cascade, in the only order that can't strand anything: kill every
  // terminal in the workspace (each `session_kill` also tears down the tmux
  // session behind it, so nothing outlives the close), drop them from state,
  // then hide the row and remember the choice.
  //
  // What it deliberately does NOT do: call anything on the brain. No
  // project is removed, nothing is un-ingested, no memory note is touched —
  // `list_projects` will keep returning this project, and re-adding the
  // folder (or opening a terminal in it from the map) brings the row
  // straight back. `CloseWorkspaceConfirm` says exactly this before any of
  // it happens; `state/closedWorkspaces.ts` records why.
  //
  // Kills run in parallel and are individually best-effort: one wedged PTY
  // must not leave the other terminals of a closed workspace running.
  const closeWorkspace = useCallback(
    async (project: ProjectInfo) => {
      const doomed = state.tabs.filter((t) => t.project === project.id);
      await Promise.all(
        doomed.map((tab) =>
          sessionKill(tab.id).catch((err) =>
            console.error(`failed to kill session ${tab.id} while closing ${project.label}`, err),
          ),
        ),
      );
      for (const tab of doomed) dispatch({ type: "tab/closed", id: tab.id });
      setReviewTarget((target) => (doomed.some((t) => t.id === target?.id) ? null : target));

      setClosedProjectIds((closed) => {
        const next = new Set(closed);
        next.add(project.id);
        void settingsSet(CLOSED_WORKSPACES_SETTING_KEY, serializeClosedWorkspaces(next));
        setSelectedProjectId((selected) =>
          nextSelectedAfterClose(state.projects, next, project.id, selected),
        );
        return next;
      });
    },
    [state.tabs, state.projects],
  );

  // ---- closing one session (founder ask: "I must be able to close a
  // session") — `closeWorkspace`'s cascade scoped to one pane group: kill
  // every terminal in it, drop them from state. No closed-set bookkeeping —
  // the workspace row stays, only this session's panes go.
  const closeSession = useCallback(
    async (project: ProjectInfo, sessionId: string) => {
      const doomed = state.tabs.filter(
        (t) => t.project === project.id && (t.group ?? UNGROUPED_SESSION_ID) === sessionId,
      );
      await Promise.all(
        doomed.map((tab) =>
          sessionKill(tab.id).catch((err) =>
            console.error(`failed to kill session ${tab.id} while closing a session in ${project.label}`, err),
          ),
        ),
      );
      for (const tab of doomed) dispatch({ type: "tab/closed", id: tab.id });
      setReviewTarget((target) => (doomed.some((t) => t.id === target?.id) ? null : target));
    },
    [state.tabs],
  );

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

  // The same question the sidebar's accent rail and the pane grid answer,
  // asked once more here for the chrome breadcrumb: which session is ON
  // SCREEN. All three go through `visibleSessionGroupId` so they can never
  // name different sessions — see that function's doc for why it isn't just
  // `currentSessionGroupId` (selecting a workspace doesn't move focus).
  //
  // Fix round (2026-07-27): this used to ALSO back `NewTerminalModal`'s
  // `session` prop and the ⌘T MAX_PANES precheck below, on the (wrong)
  // assumption that "on screen" and "the session a new pane joins" always
  // agree. They don't — `sessionGroups.ts`'s own docs draw this distinction
  // on purpose: `visibleSessionGroupId` falls back to the project's
  // FIRST-SEEN session when nothing in that project has focus, while
  // `sessionGroupForNewPane` (what `requestNewTab` itself calls to pick a
  // join target) falls back to the MOST-RECENTLY-CREATED one in that same
  // case. They diverge exactly when the user switches to a different
  // project via the sidebar (which only touches `selectedProjectId`, never
  // `activeTabId`) and that project has 2+ sessions — an ordinary flow, not
  // an edge case. So this const now backs ONLY the breadcrumb, which
  // genuinely wants "on screen"; `joinTargetSession` right below is the
  // separate derivation for anything that's about to actually receive a
  // new pane.
  //
  // `useMemo`d (unlike the rest of this file's plain-const derivations) for
  // referential stability: `joinTargetSession` below is a dependency of the
  // ⌘T `useEffect` further down, and a fresh object on every render would
  // re-subscribe that effect's window listeners on every render instead of
  // only when the tabs/focus/selected-project actually change. Kept
  // `useMemo` here too for the same shape/symmetry, even though nothing
  // downstream of `visibleSession` itself is effect-dependency-sensitive.
  const visibleSession = useMemo(
    () =>
      findSessionGroup(
        state.tabs,
        state.activeTabId,
        selectedProjectId,
        selectedProjectId === null
          ? null
          : visibleSessionGroupId(state.tabs, selectedProjectId, state.activeTabId),
      ),
    [state.tabs, state.activeTabId, selectedProjectId],
  );
  const currentSessionLabel = visibleSession?.label ?? null;

  // The session a NEW pane in the selected project actually joins:
  // `sessionGroupForNewPane`, called with the exact same arguments (tabs,
  // project id, activeTabId) `requestNewTab` itself passes internally to
  // resolve `existingGroup` — see that function's body. This is what ⌘T's
  // MAX_PANES precheck and `NewTerminalModal`'s `session` prop must read,
  // NEVER `visibleSession` above: the modal has to show — and precheck
  // against — the session `requestNewTab` is actually about to drop the new
  // pane into, which is not always "the one on screen" (see that const's
  // own doc for exactly when the two disagree).
  const joinTargetSession = useMemo(
    () =>
      findSessionGroup(
        state.tabs,
        state.activeTabId,
        selectedProjectId,
        selectedProjectId === null
          ? null
          : sessionGroupForNewPane(state.tabs, selectedProjectId, state.activeTabId),
      ),
    [state.tabs, state.activeTabId, selectedProjectId],
  );

  // ---- ⌘T new tab / ⌘K palette / ⌘N new workspace / ⌘W close pane. The
  // established place for app-level shortcuts that need live UI state (which
  // tab, which project) rather than a static native-menu event.
  //
  // ⌘W joined them on 2026-07-26 (founder bug: *"cmd+w is closing the full
  // app instead of confirming closing the current terminal"*). It could not
  // simply be added here: macOS handles a native menu accelerator in AppKit
  // *before* the key event reaches the webview, and `Menu::default` bound
  // ⌘W to `close_window` in two submenus — so this handler was never even
  // entered, and `preventDefault` had nothing to prevent. `lib.rs`'s
  // `build_menu` now omits both, which is what lets the keystroke fall
  // through to here like ⌘T and ⌘K always did.
  //
  // ⌘T itself (Task 9, 2026-07-27): used to call `requestNewTab` directly,
  // spawning the default engine with no UI in between. Now it opens
  // `NewTerminalModal` — but the two guards that used to live inside
  // `requestNewTab` still have to run BEFORE that modal ever shows: no
  // project selected (existing "no workspace" silence — there's nothing to
  // name a terminal in), and the on-screen session already sitting at
  // MAX_PANES (existing full-session error banner, `requestNewTab`'s own
  // message reused verbatim so the two entry points never disagree). Only
  // once neither guard fires does the keystroke open the modal.
  // -------------------------------------------------------------------
  useEffect(() => {
    function onNavigationKeyDown(e: KeyboardEvent) {
      if (
        ownsCtrlOnlyShortcut(e) &&
        (e.key === "ArrowDown" || e.key === "ArrowUp")
      ) {
        if (selectedProjectId !== null) {
          const next = adjacentSessionTab(
            state.tabs,
            selectedProjectId,
            state.activeTabId,
            e.key === "ArrowDown" ? 1 : -1,
          );
          if (next) {
            e.preventDefault();
            e.stopPropagation();
            activateTab(next.id);
          }
        }
      }
    }
    function onKeyDown(e: KeyboardEvent) {
      if (!e.metaKey) return;
      if (e.key.toLowerCase() === "t") {
        e.preventDefault();
        // No selected project, or a selected project with no session to
        // join yet (every pane closed, or a brand-new workspace mid-boot)
        // — silently does nothing, exactly like the old direct-spawn
        // handler's own `if (selectedProject)` guard did. `NewTerminalModal`
        // joins an existing session (its whole `session` prop, resolved via
        // `joinTargetSession` — the SAME session `requestNewTab` will
        // actually use, not necessarily the one on screen, see that const's
        // own doc); starting a project's FIRST session is ⌘N/
        // `EmptyWorkspace`'s job, not ⌘T's — and setting `newTerminalOpen`
        // with no `joinTargetSession` to hand the modal would leave that
        // state stuck true with nothing rendered (the render guard below
        // requires `joinTargetSession` too), ready to pop the modal open
        // later the moment a session appears.
        if (!selectedProject || !joinTargetSession) return;
        if (joinTargetSession.tabs.length >= MAX_PANES) {
          setErrorBanner(
            `This session already has ${MAX_PANES} terminals — the most one grid holds. Close one, or start a new session (⌘N).`,
          );
          return;
        }
        setNewTerminalOpen(true);
      } else if (e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen((open) => !open);
      } else if (e.key.toLowerCase() === "n") {
        e.preventDefault();
        // Since 2026-07-26 this asks first (session or workspace) instead
        // of opening the workspace dialog outright — see `newChooserOpen`.
        setNewChooserOpen(true);
      } else if (e.key.toLowerCase() === "w") {
        // Always prevented, focused pane or not: with the native item gone
        // the default would be nothing at all, and letting it through is how
        // a stray "close the window" behaviour would quietly come back.
        e.preventDefault();
        if (state.activeTabId) {
          setClosingTabId(state.activeTabId);
        } else {
          // Sane and honest rather than silent — the user pressed a key and
          // is owed an answer, and "nothing happened" reads as a broken
          // shortcut.
          setErrorBanner("No terminal focused — there is nothing here to close.");
        }
      }
    }
    window.addEventListener("keydown", onNavigationKeyDown, true);
    window.addEventListener("keydown", onKeyDown);
    return () => {
      window.removeEventListener("keydown", onNavigationKeyDown, true);
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [activateTab, selectedProject, selectedProjectId, joinTargetSession, state.activeTabId, state.tabs]);

  // The chrome's breadcrumb — "which workspace, which session am I in" —
  // built from the same `groupTabsBySession` derivation the sidebar renders
  // its tree from, so the two can never disagree.
  const closingTab = closingTabId ? (state.tabs.find((t) => t.id === closingTabId) ?? null) : null;

  return (
    <div className="app-shell">
      <AppChrome
        projectLabel={selectedProject?.label ?? null}
        sessionLabel={currentSessionLabel}
        notifications={notifications.entries}
        liveSessionIds={tabIds}
        knownProjectIds={state.projects.map((p) => p.id)}
        selectedProjectId={selectedProjectId}
        selectedProjectLabel={selectedProject?.label ?? null}
        onNotificationsOpened={() => notificationsDispatch({ type: "notifications/read" })}
        onSelectNotification={handleNotificationSelect}
        onDismissNotification={(id) => notificationsDispatch({ type: "notification/dismissed", id })}
        onClearNotifications={() => notificationsDispatch({ type: "notifications/cleared" })}
      />
      {errorBanner && (
        <div className="error-banner">
          <span>{errorBanner}</span>
          <button onClick={() => setErrorBanner(null)}>Dismiss</button>
        </div>
      )}
      <div className="app-body">
        <Sidebar
          projects={visibleProjects}
          tabs={state.tabs}
          activeTabId={state.activeTabId}
          selectedProjectId={selectedProjectId}
          onSelectProject={(p) => setSelectedProjectId(p.id)}
          onNewTabInProject={(p) => void requestNewTab(p)}
          onOpenNewTerminal={() => {
            // "New terminal" in the workspace the sidebar is showing — the
            // same modal ⌘T opens (Task 9). `SidebarSessionRow` only ever
            // renders this row for the current session and only while it's
            // under `MAX_PANES` (see that component's own doc), so no
            // "session is full" guard is needed here the way ⌘T's handler
            // needs one — the row simply isn't clickable once full.
            setNewTerminalOpen(true);
          }}
          onActivateTab={activateTab}
          onWorkspaceCreated={handleWorkspaceCreated}
          newWorkspaceOpen={newWorkspaceOpen}
          onOpenNewWorkspace={() => setNewWorkspaceOpen(true)}
          onCloseNewWorkspace={() => setNewWorkspaceOpen(false)}
          onRenameProject={(p, label) => void handleRenameProject(p, label)}
          onImportCompleted={handleImportCompleted}
          ingestion={ingestion}
          view={view}
          onSetView={setView}
          onNewSessionInProject={(p) => {
            setSelectedProjectId(p.id);
            setNewSessionOpen(true);
          }}
          onRenameSession={renameSession}
          onCloseWorkspace={(p) => void closeWorkspace(p)}
          onCloseSession={(p, sessionId) => void closeSession(p, sessionId)}
          authSignedIn={authSignedIn}
          authPersona={authPersona}
          onResetAuthGate={resetAuthGate}
        />
        <Workspace
          projects={state.projects}
          tabs={state.tabs}
          activeTabId={state.activeTabId}
          selectedProjectId={selectedProjectId}
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
          onStartSession={(p, layout, goal) => void handleQuickStart(p, layout, goal)}
          agentState={agentState}
          hidden={view !== "workspace"}
        />
        <BrainMap
          projects={state.projects}
          onOpenTerminal={(p) => void requestNewTab(p)}
          hidden={view !== "map"}
          livePollMs={ingestion?.running ? INGESTION_POLL_MS : undefined}
        />
        {/* The one right-hand dock — see `reviewTarget`'s declaration for
            why the file tree that used to share this slot moved into the
            sidebar (Task 6) and isn't rendered here any more. */}
        {reviewTarget && (
          <CodeReviewPanel
            key={reviewTarget.id}
            repoPath={reviewTarget.cwd}
            sessionLabel={reviewTarget.label}
            onClose={() => setReviewTarget(null)}
          />
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

      {/* ⌘N's two steps: the chooser, then whichever dialog it picked.
          `NewWorkspaceModal` itself still lives inside `Sidebar` (its "+"
          opens it too) — see `newWorkspaceOpen`'s declaration. */}
      {newChooserOpen && (
        <NewChooserModal onChoose={handleCreateChoice} onClose={() => setNewChooserOpen(false)} />
      )}

      {/* ⌘W's confirmation. Resolved from live state rather than captured at
          keypress time, so a pane that goes away underneath the dialog (its
          engine exits, the session is closed from the pane menu) takes the
          dialog with it instead of leaving a prompt about nothing. */}
      {closingTab && (
        <ClosePaneConfirm
          label={closingTab.label ?? ENGINE_LABEL[closingTab.engine] ?? closingTab.engine}
          onConfirm={() => {
            setClosingTabId(null);
            void closeTab(closingTab.id);
          }}
          onCancel={() => setClosingTabId(null)}
        />
      )}

      {newSessionOpen && selectedProject && (
        <NewSessionModal
          project={selectedProject}
          agentState={agentState}
          onCreate={(project, cwd, slots, prompt) => void handleSessionCreated(project, cwd, slots, prompt)}
          onClose={() => setNewSessionOpen(false)}
        />
      )}

      {/* ⌘T / the sidebar's "New terminal" row (Task 9). `session` is
          `joinTargetSession` — deliberately NOT `visibleSession` — so the
          modal always shows, and precheck against, the exact session
          `requestNewTab` below is about to drop the new pane into (see
          `joinTargetSession`'s own doc for why "on screen" and "join
          target" can legitimately be two different sessions). Both openers
          already only fire `setNewTerminalOpen(true)` when a join target
          genuinely exists (⌘T's own explicit `!joinTargetSession` bail
          above; the sidebar row is simply never rendered without a current
          session — `SidebarSessionRow`'s own doc), so this guard is just
          the type-narrowing echo of that, not a second decision. */}
      {newTerminalOpen && selectedProject && joinTargetSession && (
        <NewTerminalModal
          session={joinTargetSession}
          agentState={agentState}
          onCreate={(name, engine) => {
            setNewTerminalOpen(false);
            void requestNewTab(selectedProject, { engine, label: name });
          }}
          onInstallAgent={handleInstallAgent}
          onClose={() => setNewTerminalOpen(false)}
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

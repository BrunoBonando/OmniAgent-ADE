// The app shell: a `view` switch between the Phase 5 terminal workspace and
// the Phase 6 brain map (see the module-level comment at the bottom of this
// file, written by the Phase 5 agent, for the integration plan this follows).
import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import "./App.css";
import Sidebar from "./components/Sidebar";
import type { DormantSession } from "./components/Sidebar";
import Workspace from "./components/Workspace";
import DashboardOverview from "./components/DashboardOverview";
import PlanBoard from "./components/PlanBoard";
import FilesDashboard from "./components/FilesDashboard";
import CommandPalette from "./components/CommandPalette";
import CodeReviewPanel from "./components/CodeReviewPanel";
import AppChrome from "./components/AppChrome";
import NewSessionModal from "./components/NewSessionModal";
import NewWorkspaceModal from "./components/NewWorkspaceModal";
import StartupScreen from "./components/StartupScreen";
import LoadingOverlay from "./components/LoadingOverlay";
import { NewTerminalModal } from "./components/NewTerminalModal";
import ClosePaneConfirm from "./components/ClosePaneConfirm";
import BrainMap from "./map/BrainMap";
import FirstRun from "./onboarding/FirstRun";
import AuthGate from "./onboarding/AuthGate";
import SystemStatusBar, { type SystemStats } from "./components/SystemStatusBar";
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
  type PersistedTab,
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
  visibleSessionGroupId,
  type SessionGroup,
} from "./state/sessionGroups";
import {
  NOTIFICATIONS_SETTING_KEY,
  approveKeystroke,
  denyKeystroke,
  deriveNotification,
  deserializeNotifications,
  initialNotificationsState,
  notificationsReducer,
  notificationSubtitle,
  serializeNotifications,
  type NotificationEntry,
} from "./state/notifications";
import { ENGINE_LABEL } from "./theme";
import type { TerminalThemeId } from "./lib/terminalThemes";
import { ownsCtrlOnlyShortcut } from "./lib/keyboard";
import { usePerSessionEvent } from "./lib/usePerSessionEvent";
import {
  agentCheckInstalled,
  enrichQueuePendingCount,
  getBriefing,
  ingestionStatus,
  onSessionWrite,
  listProjects,
  renameProject,
  rootsList,
  sessionCreate,
  sessionKill,
  sessionStatus,
  sessionWrite,
  systemStats,
  settingsGet,
  settingsSet,
  sendNativeNotification,
  type IngestionStatus,
} from "./lib/tauri";
import { agentsReducer, initialAgentsState, type Agent } from "./state/agents";
import {
  cloneUsageAnalyticsStore,
  createUsageAnalyticsStore,
  parseTokenEstimateMax,
  parseUsageAnalyticsStore,
  recordInput,
  recordOutput,
  recordSessionOpened,
  recordStatusDuration,
  recordTerminalOpened,
  recordTokens,
  USAGE_ANALYTICS_SETTING_KEY,
  type UsageAnalyticsStore,
} from "./state/usageAnalytics";

type View = "dashboard" | "workspace" | "board" | "files" | "map";
type StartupPhase = "booting" | "choosing-workspace" | "workspace-active";
const AGENT_INSTALL_COMMAND: Partial<Record<Agent, string>> = {
  claude: "curl -fsSL https://claude.ai/install.sh | bash",
  codex: "npm install -g @openai/codex",
  copilot: "npm install -g @github/copilot",
  antigravity:
    "echo 'Antigravity has no scriptable installer yet. Opening download page...' && open https://antigravity.google/download",
};

function persistedGroup(tab: PersistedTab): string {
  return tab.group ?? UNGROUPED_SESSION_ID;
}

function persistedSessionKey(project: string, group: string): string {
  return `${project}:${group}`;
}

function serializeLiveAndDormantTabs(live: TabInfo[], dormant: PersistedTab[]): string {
  const liveLayout = JSON.parse(serializeLayout(live)) as { tabs: PersistedTab[] };
  return JSON.stringify({ tabs: [...liveLayout.tabs, ...dormant] });
}

function errorMessage(err: unknown): string {
  if (err instanceof Error && err.message.trim().length > 0) return err.message;
  if (typeof err === "string" && err.trim().length > 0) return err;
  if (err && typeof err === "object" && "message" in err) {
    const message = (err as { message?: unknown }).message;
    if (typeof message === "string" && message.trim().length > 0) return message;
  }
  return String(err);
}

function decodeBase64Chunk(payload: string): string {
  try {
    return atob(payload);
  } catch {
    return "";
  }
}

function submittedCommands(data: string): number {
  const matches = data.match(/\r|\n/g);
  return matches ? matches.length : 0;
}

function analyticsSessionKey(tab: TabInfo): string {
  return `${tab.project}:${tab.group ?? tab.id}`;
}

/** Task 8.1: how often `App.tsx` polls `ingestion_status` — PLAN.md's own
 * cadence ("called every ~2s from the frontend while ingestion runs"). This
 * one poll loop backs BOTH FirstRun's onboarding HUD and BrainMap's
 * `livePollMs` live-growth feed (and, incidentally, the post-"Rebuild
 * brain" project-list refresh) — see the boot-adjacent effect below for
 * why a single, always-running poll is simpler than start/stop plumbing
 * threaded through three different triggers. */
const INGESTION_POLL_MS = 2000;

/** Resolves a group id (from `visibleSessionGroupId`, which only ever
 * returns an id, `string | null`) to the full `SessionGroup` object the
 * chrome breadcrumb and `NewTerminalModal` both need — see `visibleSession`
 * below, its only caller. */
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
  const [startupPhase, setStartupPhase] = useState<StartupPhase>("booting");
  const [persistedTabs, setPersistedTabs] = useState<PersistedTab[]>([]);
  const [restoringGroupKey, setRestoringGroupKey] = useState<string | null>(null);
  const [requestedGroupKey, setRequestedGroupKey] = useState<string | null>(null);
  const [restoreErrors, setRestoreErrors] = useState<Record<string, string>>({});
  // Tracks the group key being loaded for a workspace switch (sidebar select
  // or startup → workspace transition). Non-null while the first session of a
  // newly-selected workspace is being created; cleared in `restoreSession`'s
  // finally block, which drives the LoadingOverlay's exit animation.
  const [workspaceSwitchGroup, setWorkspaceSwitchGroup] = useState<string | null>(null);
  const restoredGroupsRef = useRef(new Set<string>());
  const restoringGroupRef = useRef<string | null>(null);
  const [agentState, agentDispatch] = useReducer(agentsReducer, initialAgentsState);
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);
  const [paletteOpen, setPaletteOpen] = useState(false);
  /** The pane ⌘W is asking about, if any — see the ⌘W handler below. */
  const [closingTabId, setClosingTabId] = useState<string | null>(null);
  // ⌘N (Task 13, 2026-07-27, retiring the 2026-07-26 chooser step): direct
  // again — opens `NewSessionModal` when a workspace is selected,
  // `NewWorkspaceModal` otherwise (see the ⌘N handler below). The
  // intermediate "session or workspace?" step (`NewChooserModal`/
  // `state/newChooserState.ts`) is gone; see git history if you need it.
  // `newWorkspaceOpen` stays lifted out of `Sidebar.tsx` (which still owns
  // its OTHER overlays locally, e.g. aboutOpen/reviewOpen/importOpen)
  // because the sidebar's "+" opens it too.
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
  const [view, setView] = useState<View>("dashboard");
  const [fileOpenRequest, setFileOpenRequest] = useState<{ path: string; nonce: number } | null>(null);
  const [usageAnalytics, setUsageAnalytics] = useState<UsageAnalyticsStore>(() => createUsageAnalyticsStore());
  const analyticsRef = useRef<UsageAnalyticsStore>(createUsageAnalyticsStore());
  const analyticsReadyRef = useRef(false);
  const analyticsDirtyRef = useRef(false);
  const analyticsTerminalSeenRef = useRef<Set<string>>(new Set());
  const analyticsSessionSeenRef = useRef<Set<string>>(new Set());
  const analyticsStatusRef = useRef<
    Map<string, { project: string; status: SessionStatusEvent["status"]; since: number }>
  >(new Map());
  const analyticsTokenWatermarkRef = useRef<Map<string, number>>(new Map());
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
  const [computerStats, setComputerStats] = useState<SystemStats>({ cpuPercent: null, ramUsedBytes: null, ramTotalBytes: null, mcpWired: false });
  const [brainQueueCount, setBrainQueueCount] = useState<number | null>(null);
  const wasIngestingRef = useRef(false);

  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      try {
        const [statsResult, queueResult] = await Promise.allSettled([systemStats(), enrichQueuePendingCount()]);
        if (cancelled) return;
        if (statsResult.status === "fulfilled") setComputerStats(statsResult.value);
        if (queueResult.status === "fulfilled") setBrainQueueCount(queueResult.value);
      } catch (err) {
        console.error("system stats poll failed", err);
      }
    };
    void tick();
    const interval = window.setInterval(tick, 2000);
    return () => { cancelled = true; window.clearInterval(interval); };
  }, []);

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
      void settingsGet(NOTIFICATIONS_SETTING_KEY)
        .then((rawNotifications) => {
          const entries = deserializeNotifications(rawNotifications);
          if (!cancelled && entries.length > 0) {
            notificationsDispatch({ type: "notifications/restored", entries });
          }
        })
        .catch((err) => console.error("failed to restore notifications", err))
        .finally(() => {
          notificationsRestoredRef.current = true;
        });

      try {
        const raw = await settingsGet(LAYOUT_SETTING_KEY);
        if (!cancelled) setPersistedTabs(deserializeLayout(raw));
      } catch (err) {
        console.error("failed to load saved layout metadata", err);
      } finally {
        restoredRef.current = true;
        if (!cancelled) setStartupPhase("choosing-workspace");
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
    void settingsSet(LAYOUT_SETTING_KEY, serializeLiveAndDormantTabs(state.tabs, persistedTabs));
  }, [state.tabs, persistedTabs]);

  // ---- …and the notification list, same shape, same guard ---------------
  useEffect(() => {
    if (!notificationsRestoredRef.current) return;
    void settingsSet(NOTIFICATIONS_SETTING_KEY, serializeNotifications(notifications.entries));
  }, [notifications.entries]);

  // ---- usage analytics: persisted longitudinal usage model ---------------
  useEffect(() => {
    let cancelled = false;
    void settingsGet(USAGE_ANALYTICS_SETTING_KEY)
      .then((raw) => {
        if (cancelled) return;
        const parsed = parseUsageAnalyticsStore(raw);
        analyticsRef.current = parsed;
        setUsageAnalytics(parsed);
        analyticsTerminalSeenRef.current = new Set(state.tabs.map((tab) => tab.id));
        analyticsSessionSeenRef.current = new Set(state.tabs.map(analyticsSessionKey));
        analyticsReadyRef.current = true;
      })
      .catch((err) => {
        console.error("usage analytics restore failed", err);
        if (cancelled) return;
        analyticsRef.current = createUsageAnalyticsStore();
        setUsageAnalytics(analyticsRef.current);
        analyticsTerminalSeenRef.current = new Set(state.tabs.map((tab) => tab.id));
        analyticsSessionSeenRef.current = new Set(state.tabs.map(analyticsSessionKey));
        analyticsReadyRef.current = true;
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!analyticsReadyRef.current) return;

    const seenTerminals = analyticsTerminalSeenRef.current;
    const seenSessions = analyticsSessionSeenRef.current;
    const now = Date.now();
    const live = new Set(state.tabs.map((tab) => tab.id));

    for (const tab of state.tabs) {
      if (!seenTerminals.has(tab.id)) {
        seenTerminals.add(tab.id);
        recordTerminalOpened(analyticsRef.current, tab.project, now);
        analyticsDirtyRef.current = true;
      }
      const sessionKey = analyticsSessionKey(tab);
      if (!seenSessions.has(sessionKey)) {
        seenSessions.add(sessionKey);
        recordSessionOpened(analyticsRef.current, tab.project, now);
        analyticsDirtyRef.current = true;
      }
      if (tab.status && !analyticsStatusRef.current.has(tab.id)) {
        analyticsStatusRef.current.set(tab.id, { project: tab.project, status: tab.status, since: now });
      }
    }

    for (const [id, status] of analyticsStatusRef.current) {
      if (live.has(id)) continue;
      recordStatusDuration(analyticsRef.current, status.project, status.status, status.since, now);
      analyticsStatusRef.current.delete(id);
      analyticsTokenWatermarkRef.current.delete(id);
      analyticsDirtyRef.current = true;
    }
  }, [state.tabs]);

  useEffect(() => {
    const stop = onSessionWrite((id, data) => {
      if (!analyticsReadyRef.current) return;
      const tab = notifyContextRef.current.tabs.find((entry) => entry.id === id);
      if (!tab) return;
      recordInput(analyticsRef.current, tab.project, data.length, submittedCommands(data), Date.now());
      analyticsDirtyRef.current = true;
    });
    return stop;
  }, []);

  useEffect(() => {
    const interval = window.setInterval(() => {
      if (!analyticsReadyRef.current) return;
      const now = Date.now();
      for (const active of analyticsStatusRef.current.values()) {
        recordStatusDuration(analyticsRef.current, active.project, active.status, active.since, now);
        active.since = now;
      }
      if (!analyticsDirtyRef.current) return;
      analyticsDirtyRef.current = false;
      const snapshot = cloneUsageAnalyticsStore(analyticsRef.current);
      setUsageAnalytics(snapshot);
      void settingsSet(USAGE_ANALYTICS_SETTING_KEY, JSON.stringify(snapshot)).catch((err) => {
        console.error("usage analytics persist failed", err);
      });
    }, 15000);
    return () => window.clearInterval(interval);
  }, []);

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

  // Session ids whose CURRENT status is `awaiting_approval` — what decides
  // which NEEDS YOU rows in the notifications panel are actionable right
  // now (`isActionable`/`NotificationsPanel.tsx`'s `awaiting` set), as
  // opposed to whatever status a row froze at when it was recorded.
  const awaitingSessionIds = useMemo(
    () => state.tabs.filter((t) => t.status === "awaiting_approval").map((t) => t.id),
    [state.tabs],
  );

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

  usePerSessionEvent<string>(tabIds, "session-output:", (id, payload) => {
    if (!analyticsReadyRef.current || typeof payload !== "string") return;
    const tab = notifyContextRef.current.tabs.find((entry) => entry.id === id);
    if (!tab) return;
    const text = decodeBase64Chunk(payload);
    if (text.length > 0) {
      recordOutput(analyticsRef.current, tab.project, text.length, Date.now());
      analyticsDirtyRef.current = true;
    }
    const estimate = parseTokenEstimateMax(text);
    if (estimate === null) return;
    const previous = analyticsTokenWatermarkRef.current.get(id) ?? 0;
    if (estimate <= previous) return;
    analyticsTokenWatermarkRef.current.set(id, estimate);
    recordTokens(analyticsRef.current, tab.project, estimate - previous, Date.now());
    analyticsDirtyRef.current = true;
  });

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

    if (analyticsReadyRef.current) {
      const tabForStatus = notifyContextRef.current.tabs.find((entry) => entry.id === id);
      const now = Date.now();
      const previous = analyticsStatusRef.current.get(id);
      if (previous) {
        recordStatusDuration(analyticsRef.current, previous.project, previous.status, previous.since, now);
        analyticsDirtyRef.current = true;
      }
      const projectId = tabForStatus?.project ?? previous?.project;
      if (projectId) {
        analyticsStatusRef.current.set(id, { project: projectId, status: payload.status, since: now });
      }
      if (payload.status === "ready") {
        analyticsTokenWatermarkRef.current.set(id, 0);
      }
    }

    const queuedPrompt = pendingFirstPrompt.current.get(id);
    if (queuedPrompt !== undefined) {
      pendingFirstPrompt.current.delete(id);
      void sessionWrite(id, queuedPrompt);
    }

    // Any non-awaiting status means this session's pending prompt (if any)
    // was answered — in the pane, via the panel's Approve, either way — so
    // its awaiting rows come down before the new status' own row goes up.
    // The reducer no-ops when there's nothing to remove.
    if (payload.status !== "awaiting_approval") {
      notificationsDispatch({ type: "notifications/approval_resolved", sessionId: id });
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
      view: currentView === "map" ? "map" : "workspace",
      windowVisible: typeof document === "undefined" || document.visibilityState !== "hidden",
      windowFocused: typeof document === "undefined" || document.hasFocus(),
      previousStatus: tab?.status,
      now: Date.now(),
    });
    if (entry) {
      notificationsDispatch({ type: "notification/added", entry });

      const appFocused =
        typeof document === "undefined"
          ? true
          : document.visibilityState === "visible" && document.hasFocus();
      if (!appFocused) {
        const place = entry.sessionLabel ? `${entry.projectLabel} • ${entry.sessionLabel}` : entry.projectLabel;
        void sendNativeNotification(`Attention: ${entry.title}`, `${notificationSubtitle(entry.status)} ${place}`);
      }
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

  // The workspaces the sidebar lists: what the brain knows, minus what the
  // user has closed. Everything else — the map, the palette, the brain
  // itself — deliberately still sees all of them: closing a workspace closes
  // a window, it does not unlearn a project.
  const visibleProjects = useMemo(
    () => openWorkspaces(state.projects, closedProjectIds),
    [state.projects, closedProjectIds],
  );

  const selectedProject = useMemo(
    () => state.projects.find((p) => p.id === selectedProjectId) ?? null,
    [state.projects, selectedProjectId],
  );

  const restoreSession = useCallback(
    async (projectId: string, group: string) => {
      const key = persistedSessionKey(projectId, group);
      if (restoredGroupsRef.current.has(key) || restoringGroupRef.current !== null) return;
      const saved = persistedTabs.filter(
        (tab) => tab.project === projectId && persistedGroup(tab) === group,
      );
      if (saved.length === 0) return;

      restoredGroupsRef.current.add(key);
      restoringGroupRef.current = key;
      setRequestedGroupKey(key);
      setRestoringGroupKey(key);
      setRestoreErrors((errors) => {
        const next = { ...errors };
        delete next[key];
        return next;
      });

      const restored: TabInfo[] = [];
      try {
        for (const tab of saved) {
          const briefing = tab.engine === "claude" ? await getBriefing(tab.project) : undefined;
          let info;
          try {
            info = await sessionCreate(tab.project, tab.engine, tab.cwd, briefing, tab.id);
          } catch (restoreErr) {
            if (tab.id === undefined) throw restoreErr;
            info = await sessionCreate(tab.project, tab.engine, tab.cwd, briefing);
          }
          restored.push({
            id: info.id,
            project: info.project,
            engine: tab.engine,
            cwd: info.cwd,
            createdAt: info.created,
            label: tab.label,
            themeId: tab.themeId,
            group: tab.group,
            groupLabel: tab.groupLabel,
            restored: info.restored === true,
          });
        }
        dispatch({ type: "layout/lazyRestored", tabs: restored });
        dispatch({ type: "tab/activated", id: restored[0].id });
        setPersistedTabs((tabs) =>
          tabs.filter((tab) => !(tab.project === projectId && persistedGroup(tab) === group)),
        );
      } catch (err) {
        restoredGroupsRef.current.delete(key);
        if (restored.length > 0) {
          const completed = saved.slice(0, restored.length);
          dispatch({ type: "layout/lazyRestored", tabs: restored });
          dispatch({ type: "tab/activated", id: restored[0].id });
          setPersistedTabs((tabs) => tabs.filter((tab) => !completed.includes(tab)));
        }
        setRestoreErrors((errors) => ({ ...errors, [key]: String(err) }));
      } finally {
        restoringGroupRef.current = null;
        setRestoringGroupKey((current) => (current === key ? null : current));
        setWorkspaceSwitchGroup((current) => (current === key ? null : current));
      }
    },
    [persistedTabs],
  );

  const selectStartupWorkspace = useCallback(
    (project: ProjectInfo) => {
      setSelectedProjectId(project.id);
      setStartupPhase("workspace-active");
      const first = persistedTabs.find((tab) => tab.project === project.id);
      if (first) {
        const key = persistedSessionKey(project.id, persistedGroup(first));
        setWorkspaceSwitchGroup(key);
        void restoreSession(project.id, persistedGroup(first));
      }
    },
    [persistedTabs, restoreSession],
  );

  const selectWorkspace = useCallback(
    (project: ProjectInfo) => {
      setSelectedProjectId(project.id);
      if (state.tabs.some((tab) => tab.project === project.id)) return;
      const first = persistedTabs.find((tab) => tab.project === project.id);
      if (first) {
        const key = persistedSessionKey(project.id, persistedGroup(first));
        setWorkspaceSwitchGroup(key);
        void restoreSession(project.id, persistedGroup(first));
      }
    },
    [persistedTabs, restoreSession, state.tabs],
  );

  const dormantSessions = useMemo<DormantSession[]>(() => {
    if (selectedProjectId === null) return [];
    const sessions = new Map<string, DormantSession>();
    for (const tab of persistedTabs) {
      if (tab.project !== selectedProjectId) continue;
      const group = persistedGroup(tab);
      const existing = sessions.get(group);
      if (existing) {
        existing.paneCount += 1;
      } else {
        sessions.set(group, {
          project: tab.project,
          group,
          label: tab.groupLabel?.trim() || `Session ${sessions.size + 1}`,
          cwd: tab.cwd,
          paneCount: 1,
        });
      }
    }
    return [...sessions.values()];
  }, [persistedTabs, selectedProjectId]);

  const requestedDormantSession = dormantSessions.find(
    (session) => persistedSessionKey(session.project, session.group) === requestedGroupKey,
  );
  const sessionRestoreState =
    requestedGroupKey &&
    requestedDormantSession &&
    (restoringGroupKey === requestedGroupKey || restoreErrors[requestedGroupKey])
      ? {
          status: (restoringGroupKey === requestedGroupKey ? "loading" : "error") as "loading" | "error",
          onRetry: () => void restoreSession(requestedDormantSession.project, requestedDormantSession.group),
        }
      : null;

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

      // A single new pane joins the session that project is currently
      // SHOWING (`visibleSessionGroupId`) — ⌘T, the sidebar "+" and the
      // pane header's split all mean "one more terminal here", not "a new
      // session". A project with no panes at all starts one, named.
      //
      // This used to ask `sessionGroupForNewPane`, a near-twin that differed
      // in exactly one case — no focused pane in this project — where it
      // picked the project's MOST-RECENTLY-CREATED session while
      // `visibleSessionGroupId` picks its FIRST-SEEN one, i.e. the session
      // actually on screen. That case is not exotic: selecting a workspace
      // in the sidebar deliberately doesn't move focus, so any project with
      // 2+ sessions hit it. The sidebar's "New terminal" row is gated and
      // drawn off the on-screen session, so the row could sit under Session
      // 1 and spawn into Session 2. Unified on the on-screen answer, which
      // is also what this function's own `setView("workspace")` below is
      // about to paint. Whenever the focused pane IS in this project the two
      // functions returned the same group anyway, so the focused ⌘T and
      // pane-split paths are untouched; `sessionGroupForNewPane` is gone.
      const existingGroup = visibleSessionGroupId(state.tabs, project.id, state.activeTabId);

      // The approved-shape ladder tops out at 2x4 (`paneGrid.ts`'s
      // `GRID_LADDER` — founder: "and then no more terminals are
      // available"), so refuse the 9th pane instead of spawning a live
      // session the grid has no approved shape for. Per SESSION, not per
      // project or per app: a workspace can hold as many 8-pane sessions as
      // the machine will take.
      const inSession = state.tabs.filter(
        (t) => t.project === project.id && (t.group ?? UNGROUPED_SESSION_ID) === existingGroup,
      ).length;
      if (existingGroup !== null && inSession >= MAX_PANES) {
        setErrorBanner(
          `This session already has ${MAX_PANES} terminals — the most one grid holds. Close one, or start a new session (⌘N).`,
        );
        return null;
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
        return tab;
      } catch (err) {
        console.error("failed to create session", err);
        setErrorBanner(`Couldn't start ${engine} in ${project.label}: ${err}`);
        return null;
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
  // `label` (a manual rename OR a previously auto-titled engine summary) and
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

  // Agent-generated title (`Terminal.tsx`'s xterm title event -> here).
  // The reducer's guard preserves any human rename.
  const autoTitleTab = useCallback(
    (id: string, title: string) => dispatch({ type: "tab/autoTitled", id, label: title }),
    [],
  );

  // ---- Agent installation handler ----
  // Clicking Install opens a shell pane and runs that agent's install command
  // there, so users can watch and control installation directly.
  const handleInstallAgent = useCallback(
    async (agent: Agent) => {
      if (!selectedProject) return;

      const installCommand = AGENT_INSTALL_COMMAND[agent];
      if (!installCommand) {
        setErrorBanner(`No install command is available for ${ENGINE_LABEL[agent]}.`);
        return;
      }

      const tab = await requestNewTab(selectedProject, {
        engine: "shell",
        label: `Install ${ENGINE_LABEL[agent]}`,
      });
      if (!tab) return;

      try {
        await sessionWrite(tab.id, `${installCommand}\n`);
      } catch (err) {
        console.error(`failed to start install command for ${agent}`, err);
        setErrorBanner(`Couldn't run the install command for ${ENGINE_LABEL[agent]}: ${err}`);
      }
    },
    [requestNewTab, selectedProject],
  );

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
      setStartupPhase("workspace-active");
      setNewWorkspaceOpen(false);
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
      const failed: Array<{ engine: Engine; error: string }> = [];
      for (const engine of slots) {
        try {
          created.push(await createSessionTab(project, engine, group, groupLabel, cwd));
        } catch (err) {
          console.error(`failed to start ${engine} in ${cwd}`, err);
          failed.push({ engine, error: errorMessage(err) });
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
        const names = [...new Set(failed.map((f) => f.engine))].map((e) => ENGINE_LABEL[e]).join(", ");
        const details = [...new Set(failed.map((f) => f.error).filter((m) => m.trim().length > 0))].join(" | ");
        setErrorBanner(
          created.length > 0
            ? `Started the session, but couldn't run ${names}${details ? `: ${details}` : ""} — the rest are up.`
            : `Couldn't start ${names} in ${project.label}${details ? `: ${details}` : " — no panes were opened."}`,
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

  // Approve-from-the-panel (founder ask, 2026-07-27: the notification row's
  // own Approve button, so a pending tool-permission prompt never forces a
  // trip to the pane). One write of the engine's yes-keystroke down the same
  // PTY path typing uses — which also clears the Rust attention latch, so the
  // amber state resolves exactly as if the user had answered in the pane.
  // Re-checked against the CURRENT status at click time: a prompt already
  // answered in the pane must not get a stray "1" typed into whatever
  // replaced it.
  //
  // `approveInFlightRef` guards a double-click: `tab.status` only flips on
  // the backend's NEXT status event, so a second click before that event
  // arrives sees the very same "still awaiting" status the first click did
  // and would sail past the check above too. Claude often raises a
  // follow-up permission prompt immediately, so a second unguarded write can
  // approve a prompt the user never even saw. The set is checked and added
  // to synchronously, before any `await`, so the second call in a
  // double-click — however close together — is always the one that bails.
  const approvalInFlightRef = useRef<Set<string>>(new Set());
  const resolveAwaitingApproval = useCallback(
    async (sessionId: string, engine: string, decision: "approve" | "deny", title: string) => {
      if (approvalInFlightRef.current.has(sessionId)) return false;
      approvalInFlightRef.current.add(sessionId);
      try {
        const keystroke = decision === "approve" ? approveKeystroke(engine) : denyKeystroke(engine);
        const tab = state.tabs.find((t) => t.id === sessionId);
        if (!keystroke || !tab || tab.status !== "awaiting_approval") return false;
        await sessionWrite(sessionId, keystroke);
        return true;
      } catch (err) {
        console.error(`${decision} from approval banner failed`, err);
        setErrorBanner(`Couldn't ${decision} "${title}" — open its pane and answer there.`);
        return false;
      } finally {
        approvalInFlightRef.current.delete(sessionId);
      }
    },
    [state.tabs],
  );

  const handleNotificationApprove = useCallback(
    async (entry: NotificationEntry) => {
      const sent = await resolveAwaitingApproval(
        entry.sessionId,
        entry.engine,
        "approve",
        entry.title,
      );
      if (sent) {
        notificationsDispatch({ type: "notification/dismissed", id: entry.id });
      }
    },
    [resolveAwaitingApproval],
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

  const openFileInDashboard = useCallback((path: string) => {
    setFileOpenRequest((prev) => ({ path, nonce: (prev?.nonce ?? 0) + 1 }));
    setView("files");
  }, []);

  // The one session this app is "in" for the selected workspace: what the
  // sidebar's accent rail marks, what the pane grid paints, what the chrome
  // breadcrumb names — and what a new terminal joins. All of them go through
  // `visibleSessionGroupId` so they can never name different sessions; see
  // that function's doc for why it isn't just `currentSessionGroupId`
  // (selecting a workspace doesn't move focus).
  //
  // There were briefly TWO consts here — this one for "on screen" and a
  // `joinTargetSession` for "which session receives a new pane" — because
  // `requestNewTab` resolved its own target through `sessionGroupForNewPane`,
  // whose only difference was the no-focus-in-this-project fallback
  // (most-recently-created vs first-seen/on-screen). Keeping the modal
  // honest about that divergence just moved the bug: the sidebar's "New
  // terminal" row is drawn and gated off the ON-SCREEN session, so the row
  // could sit under Session 1 and spawn into Session 2. `requestNewTab` now
  // resolves through `visibleSessionGroupId` too (see its body), the two
  // questions have one answer again, and this is it.
  //
  // `useMemo`d (unlike the rest of this file's plain-const derivations) for
  // referential stability: this is a dependency of the ⌘T `useEffect`
  // further down, and a fresh object on every render would re-subscribe that
  // effect's window listeners on every render instead of only when the
  // tabs/focus/selected-project actually change.
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

  // ---- ⌘T new tab / ⌘K palette / ⌘N new session or workspace / ⌘W close
  // pane. The established place for app-level shortcuts that need live UI
  // state (which tab, which project) rather than a static native-menu event.
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
        // `visibleSession` — the SAME session `requestNewTab` will actually
        // use, see that const's own doc); starting a project's FIRST session
        // is ⌘N/`EmptyWorkspace`'s job, not ⌘T's — and setting
        // `newTerminalOpen` with no `visibleSession` to hand the modal would
        // leave that state stuck true with nothing rendered (the render
        // guard below requires `visibleSession` too), ready to pop the modal
        // open later the moment a session appears.
        if (!selectedProject || !visibleSession) return;
        if (visibleSession.tabs.length >= MAX_PANES) {
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
        // Task 13 (2026-07-27): direct again, no "session or workspace?"
        // chooser in between. A session needs a project to run in — with
        // none selected (a brand-new install with no projects at all) the
        // only meaningful thing to create is a workspace, so it falls
        // through to that rather than opening a dialog with nowhere to put
        // its panes (the same fallback `handleCreateChoice` used to encode
        // for the now-retired chooser).
        if (selectedProject) setNewSessionOpen(true);
        else setNewWorkspaceOpen(true);
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
  }, [activateTab, selectedProject, selectedProjectId, visibleSession, state.activeTabId, state.tabs]);

  // The chrome's breadcrumb — "which workspace, which session am I in" —
  // built from the same `groupTabsBySession` derivation the sidebar renders
  // its tree from, so the two can never disagree.
  const closingTab = closingTabId ? (state.tabs.find((t) => t.id === closingTabId) ?? null) : null;

  if (startupPhase !== "workspace-active") {
    return (
      <>
        <StartupScreen
          loading={startupPhase === "booting" || needsAuthGate !== false}
          projects={visibleProjects}
          onSelectWorkspace={selectStartupWorkspace}
          onStartFromScratch={() => setNewWorkspaceOpen(true)}
        />
        {needsAuthGate === true && <AuthGate onResolved={handleAuthGateResolved} />}
        {newWorkspaceOpen && (
          <NewWorkspaceModal
            onCreate={handleWorkspaceCreated}
            onClose={() => setNewWorkspaceOpen(false)}
          />
        )}
      </>
    );
  }

  return (
    <div className="app-shell">
      <AppChrome
        projectLabel={selectedProject?.label ?? null}
        sessionLabel={currentSessionLabel}
        sessionTerminalCount={visibleSession?.tabs.length ?? null}
        notifications={notifications.entries}
        liveSessionIds={tabIds}
        knownProjectIds={state.projects.map((p) => p.id)}
        selectedProjectId={selectedProjectId}
        selectedProjectLabel={selectedProject?.label ?? null}
        onNotificationsOpened={() => notificationsDispatch({ type: "notifications/read" })}
        onSelectNotification={handleNotificationSelect}
        onDismissNotification={(id) => notificationsDispatch({ type: "notification/dismissed", id })}
        onClearNotifications={() => notificationsDispatch({ type: "notifications/cleared" })}
        awaitingSessionIds={awaitingSessionIds}
        onApproveNotification={(entry) => void handleNotificationApprove(entry)}
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
          onSelectProject={selectWorkspace}
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
          onOpenFile={openFileInDashboard}
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
          dormantSessions={dormantSessions}
          onSelectDormantSession={(session) => void restoreSession(session.project, session.group)}
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
          onResolveApproval={(tab, decision) =>
            void resolveAwaitingApproval(tab.id, tab.engine, decision, tabDisplayLabel(tab))
          }
          onEngineTitle={autoTitleTab}
          onStartSession={(p, layout, goal) => void handleQuickStart(p, layout, goal)}
          agentState={agentState}
          hidden={view !== "workspace"}
          restoreState={sessionRestoreState}
        />
        <DashboardOverview
          hidden={view !== "dashboard"}
          project={selectedProject}
          tabs={state.tabs}
          activeTabId={state.activeTabId}
          analytics={usageAnalytics}
          onOpenTerminals={() => setView("workspace")}
          onOpenBoard={() => setView("board")}
          onOpenFiles={() => setView("files")}
          onOpenSession={(tabId) => {
            activateTab(tabId);
            setView("workspace");
          }}
        />
        <PlanBoard
          project={selectedProject}
          hidden={view !== "board"}
        />
        <FilesDashboard
          project={selectedProject}
          hidden={view !== "files"}
          openRequest={fileOpenRequest}
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
      <SystemStatusBar
        liveSessionCount={tabIds.length}
        brainNodeCount={ingestion?.total_nodes ?? null}
        brainQueueCount={brainQueueCount}
        {...computerStats}
      />

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
          `visibleSession` — the session on screen, which is also the exact
          session `requestNewTab` below will drop the new pane into: both
          resolve through `visibleSessionGroupId` (see that const's own doc
          for the fix that made those one answer instead of two). So the
          modal's header names the session the row was rendered under, and
          the MAX_PANES precheck counts that same session's panes. Both
          openers already only fire `setNewTerminalOpen(true)` when a session
          genuinely exists (⌘T's own explicit `!visibleSession` bail above;
          the sidebar row is simply never rendered without a current session
          — `SidebarSessionRow`'s own doc), so this guard is just the
          type-narrowing echo of that, not a second decision. */}
      {newTerminalOpen && selectedProject && visibleSession && (
        <NewTerminalModal
          session={visibleSession}
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
      {/* Workspace-switch loading overlay — covers the full window while the
          first session of a newly-selected workspace (or the startup →
          workspace transition) is being created. Fades out when the restore
          settles (success or error). */}
      <LoadingOverlay visible={workspaceSwitchGroup !== null} />
    </div>
  );
}

export default App;

// ---------------------------------------------------------------------------
// Phase 6 integration notes (superseded the Phase 5 agent's plan above,
// which this followed almost verbatim — kept as a record of what changed
// and why, for whoever touches this next):
//
// - `view: "workspace" | "board" | "files" | "map"` state lives here,
//   toggled from the Sidebar's dashboard tabs.
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

import { describe, expect, it } from "vitest";
import {
  MAX_NOTIFICATIONS,
  deriveNotification,
  deserializeNotifications,
  filterChipLabel,
  filterNotifications,
  initialNotificationsState,
  isSessionOnScreen,
  notificationSubtitle,
  notificationsReducer,
  relativeTime,
  serializeNotifications,
  type NotificationContext,
  type NotificationEntry,
} from "./notifications";
import type { SessionStatus, SessionStatusEvent } from "./sessionStatus";
import type { TabInfo } from "./sessions";

const TAB: TabInfo = {
  id: "sess-1",
  project: "p1",
  engine: "claude",
  cwd: "/repo/p1",
  createdAt: 0,
  group: "g1",
};

function event(status: SessionStatus, notify: boolean, id = "sess-1"): SessionStatusEvent {
  return { id, status, notify, engine: "claude" };
}

/** Default context: a BACKGROUND session (nothing focused) — the case that
 * should notify. Each test overrides only what it's about. */
function ctx(over: Partial<NotificationContext> = {}): NotificationContext {
  return {
    event: event("ready", true),
    tab: TAB,
    projectLabel: "Project One",
    focusedTabId: null,
    selectedProjectId: "p1",
    view: "workspace",
    windowVisible: true,
    now: 1_000_000,
    ...over,
  };
}

describe("deriveNotification — the backend's notify flag is the rule", () => {
  it("records an entry for a notifying event on a background session", () => {
    const entry = deriveNotification(ctx());
    expect(entry).not.toBeNull();
    expect(entry).toMatchObject({
      sessionId: "sess-1",
      project: "p1",
      projectLabel: "Project One",
      cwd: "/repo/p1",
      engine: "claude",
      status: "ready",
      title: "claude",
      createdAt: 1_000_000,
      read: false,
    });
  });

  it("records nothing when the backend says notify:false", () => {
    // thinking/tool_execution — the rule Bruno stated, implemented once in
    // Rust and carried on the payload. This must not be re-derived here.
    expect(deriveNotification(ctx({ event: event("thinking", false) }))).toBeNull();
    expect(deriveNotification(ctx({ event: event("tool_execution", false) }))).toBeNull();
  });

  it("trusts the flag even for a status that usually would notify", () => {
    // If the backend ever says "don't", the UI doesn't argue: one source of
    // truth, no second copy of the rule.
    expect(deriveNotification(ctx({ event: event("ready", false) }))).toBeNull();
  });

  it("records nothing for a session this app has no pane for", () => {
    expect(deriveNotification(ctx({ tab: undefined }))).toBeNull();
  });

  it("uses the session's own title when it has one, else the engine name", () => {
    expect(deriveNotification(ctx({ tab: { ...TAB, label: "wire session restore" } }))?.title).toBe(
      "wire session restore",
    );
    expect(deriveNotification(ctx({ tab: { ...TAB, label: "" } }))?.title).toBe("claude");
  });

  it("carries all three notifying statuses", () => {
    for (const status of ["ready", "awaiting_approval", "error"] as SessionStatus[]) {
      expect(deriveNotification(ctx({ event: event(status, true) }))?.status).toBe(status);
    }
  });
});

describe("deriveNotification — the focused-session suppression rule", () => {
  const focusedOnScreen = ctx({ focusedTabId: "sess-1" });

  it("suppresses an event on the focused pane of the project on screen", () => {
    expect(deriveNotification(focusedOnScreen)).toBeNull();
    expect(isSessionOnScreen(focusedOnScreen)).toBe(true);
  });

  it("notifies for a background pane in the very same project", () => {
    expect(deriveNotification(ctx({ focusedTabId: "sess-other" }))).not.toBeNull();
  });

  it("notifies when the focused pane's project isn't the one on screen", () => {
    // Focused, but its grid isn't displayed — the user is in another
    // workspace, exactly Bruno's "or even workspace" case.
    expect(deriveNotification(ctx({ focusedTabId: "sess-1", selectedProjectId: "p2" }))).not.toBeNull();
  });

  it("notifies when the user is on the brain map instead of the workspace", () => {
    expect(deriveNotification(ctx({ focusedTabId: "sess-1", view: "map" }))).not.toBeNull();
  });

  it("notifies when the window isn't visible at all", () => {
    expect(deriveNotification(ctx({ focusedTabId: "sess-1", windowVisible: false }))).not.toBeNull();
  });

  it("suppresses only when every condition holds at once", () => {
    expect(isSessionOnScreen(ctx({ focusedTabId: "sess-1", view: "map" }))).toBe(false);
    expect(isSessionOnScreen(ctx({ focusedTabId: null }))).toBe(false);
    expect(isSessionOnScreen(ctx({ focusedTabId: "sess-1", selectedProjectId: "p2" }))).toBe(false);
    expect(isSessionOnScreen(ctx({ focusedTabId: "sess-1", windowVisible: false }))).toBe(false);
  });
});

describe("notificationSubtitle", () => {
  it("says what happened, in the panel's own voice", () => {
    expect(notificationSubtitle("ready")).toBe("Task completed.");
    expect(notificationSubtitle("awaiting_approval")).toBe("Needs your approval.");
    expect(notificationSubtitle("error")).toBe("Error occurred.");
  });
});

describe("notificationsReducer", () => {
  const entry = (id: string, sessionId = "sess-1", status: SessionStatus = "ready"): NotificationEntry => ({
    id,
    sessionId,
    project: "p1",
    projectLabel: "Project One",
    cwd: "/repo/p1",
    engine: "claude",
    status,
    title: "claude",
    createdAt: 1,
    read: false,
  });

  it("prepends — newest first", () => {
    const one = notificationsReducer(initialNotificationsState, { type: "notification/added", entry: entry("a") });
    const two = notificationsReducer(one, { type: "notification/added", entry: entry("b", "sess-2") });
    expect(two.entries.map((e) => e.id)).toEqual(["b", "a"]);
  });

  it("collapses an immediate repeat of the same session and status", () => {
    const one = notificationsReducer(initialNotificationsState, { type: "notification/added", entry: entry("a") });
    const two = notificationsReducer(one, { type: "notification/added", entry: entry("b") });
    expect(two.entries.map((e) => e.id)).toEqual(["b"]);
  });

  it("keeps both when the repeat is a different status", () => {
    const one = notificationsReducer(initialNotificationsState, { type: "notification/added", entry: entry("a") });
    const two = notificationsReducer(one, {
      type: "notification/added",
      entry: entry("b", "sess-1", "awaiting_approval"),
    });
    expect(two.entries.map((e) => e.id)).toEqual(["b", "a"]);
  });

  it("keeps both when another session notified in between", () => {
    let state = notificationsReducer(initialNotificationsState, { type: "notification/added", entry: entry("a") });
    state = notificationsReducer(state, { type: "notification/added", entry: entry("b", "sess-2") });
    state = notificationsReducer(state, { type: "notification/added", entry: entry("c") });
    expect(state.entries.map((e) => e.id)).toEqual(["c", "b", "a"]);
  });

  it("caps the list", () => {
    let state = initialNotificationsState;
    for (let i = 0; i < MAX_NOTIFICATIONS + 10; i++) {
      state = notificationsReducer(state, { type: "notification/added", entry: entry(`e${i}`, `sess-${i}`) });
    }
    expect(state.entries).toHaveLength(MAX_NOTIFICATIONS);
    expect(state.entries[0].id).toBe(`e${MAX_NOTIFICATIONS + 9}`);
  });

  it("dismisses one entry, clears all", () => {
    let state = notificationsReducer(initialNotificationsState, { type: "notification/added", entry: entry("a") });
    state = notificationsReducer(state, { type: "notification/added", entry: entry("b", "sess-2") });
    expect(notificationsReducer(state, { type: "notification/dismissed", id: "a" }).entries.map((e) => e.id)).toEqual([
      "b",
    ]);
    expect(notificationsReducer(state, { type: "notifications/cleared" }).entries).toEqual([]);
  });

  it("marks everything read, and doesn't churn when nothing is unread", () => {
    const state = notificationsReducer(initialNotificationsState, { type: "notification/added", entry: entry("a") });
    const read = notificationsReducer(state, { type: "notifications/read" });
    expect(read.entries.every((e) => e.read)).toBe(true);
    expect(notificationsReducer(read, { type: "notifications/read" })).toBe(read);
  });

  it("restores a persisted list, capped", () => {
    const entries = Array.from({ length: MAX_NOTIFICATIONS + 5 }, (_, i) => entry(`e${i}`, `s${i}`));
    expect(notificationsReducer(initialNotificationsState, { type: "notifications/restored", entries }).entries).toHaveLength(
      MAX_NOTIFICATIONS,
    );
  });
});

describe("relativeTime", () => {
  const now = 10_000_000_000;
  it("reads the way the reference panel reads", () => {
    expect(relativeTime(now, now)).toBe("Just now");
    expect(relativeTime(now - 59_000, now)).toBe("Just now");
    expect(relativeTime(now - 60_000, now)).toBe("1m");
    expect(relativeTime(now - 45 * 60_000, now)).toBe("45m");
    expect(relativeTime(now - 3 * 3_600_000, now)).toBe("3h");
    expect(relativeTime(now - 26 * 3_600_000, now)).toBe("1 day");
    expect(relativeTime(now - 3 * 86_400_000, now)).toBe("3 days");
  });

  it("never reads negative for a clock that jumped", () => {
    expect(relativeTime(now + 5000, now)).toBe("Just now");
  });
});

describe("notifications persistence", () => {
  const entry: NotificationEntry = {
    id: "sess-1:5",
    sessionId: "sess-1",
    project: "p1",
    projectLabel: "Project One",
    cwd: "/repo/p1",
    engine: "claude",
    status: "awaiting_approval",
    title: "wire session restore",
    createdAt: 5,
    read: false,
  };

  it("round-trips", () => {
    expect(deserializeNotifications(serializeNotifications([entry]))).toEqual([entry]);
  });

  it("keeps the read flag across a relaunch", () => {
    const read = { ...entry, read: true };
    expect(deserializeNotifications(serializeNotifications([read]))[0].read).toBe(true);
  });

  it("returns nothing for missing or corrupt rows instead of throwing", () => {
    expect(deserializeNotifications(null)).toEqual([]);
    expect(deserializeNotifications("")).toEqual([]);
    expect(deserializeNotifications("{{{")).toEqual([]);
    expect(deserializeNotifications('{"entries":"nope"}')).toEqual([]);
  });

  it("drops individual malformed entries, keeping the good ones", () => {
    const raw = JSON.stringify({ entries: [entry, { id: "x" }, null, { ...entry, createdAt: "soon" }] });
    expect(deserializeNotifications(raw)).toEqual([entry]);
  });

  it("refuses a persisted entry whose status could never have notified", () => {
    const raw = JSON.stringify({ entries: [{ ...entry, status: "thinking" }] });
    expect(deserializeNotifications(raw)).toEqual([]);
  });

  it("caps a bloated persisted list", () => {
    const raw = JSON.stringify({
      entries: Array.from({ length: MAX_NOTIFICATIONS + 20 }, (_, i) => ({ ...entry, id: `e${i}` })),
    });
    expect(deserializeNotifications(raw)).toHaveLength(MAX_NOTIFICATIONS);
  });
});

describe("filterNotifications", () => {
  const entry = (id: string, project: string): NotificationEntry => ({
    id,
    sessionId: `sess-${id}`,
    project,
    projectLabel: project,
    cwd: `/repo/${project}`,
    engine: "claude",
    status: "ready",
    title: "claude",
    createdAt: 1,
    read: false,
  });
  const entries = [entry("a", "p1"), entry("b", "p2"), entry("c", "p1")];

  it("passes everything through for the all filter", () => {
    expect(filterNotifications(entries, "all", "p1", new Set())).toBe(entries);
  });

  it("keeps only the selected project's entries", () => {
    expect(filterNotifications(entries, "project", "p1", new Set()).map((e) => e.id)).toEqual(["a", "c"]);
  });

  it("shows nothing rather than everything when no project is selected", () => {
    expect(filterNotifications(entries, "project", null, new Set())).toEqual([]);
  });

  it("labels each chip with its own count", () => {
    expect(filterChipLabel("all", 3, "OmniAgent ADE")).toBe("All 3");
    expect(filterChipLabel("project", 2, "OmniAgent ADE")).toBe("This workspace 2");
    expect(filterChipLabel("project", 0, null)).toBe("This workspace 0");
  });
});

const T0 = new Date(2026, 6, 27, 14, 0, 0).getTime(); // local 2pm

function n(over: Partial<NotificationEntry> = {}): NotificationEntry {
  return {
    id: "n1",
    sessionId: "s1",
    project: "p1",
    projectLabel: "Demo",
    cwd: "/tmp/p1",
    engine: "claude",
    status: "awaiting_approval",
    title: "stripe webhook retries",
    createdAt: T0,
    read: false,
    ...over,
  };
}

describe("approveKeystroke", () => {
  it("knows Claude's numbered permission dialog: '1' selects Yes", async () => {
    const { approveKeystroke } = await import("./notifications");
    expect(approveKeystroke("claude")).toBe("1");
  });
  it("returns null for every engine without a known approve gesture", async () => {
    const { approveKeystroke } = await import("./notifications");
    for (const engine of ["codex", "shell", "copilot", "antigravity", "unknown"]) {
      expect(approveKeystroke(engine)).toBeNull();
    }
  });
});

describe("isActionable", () => {
  it("true only for an awaiting_approval entry whose session still awaits right now", async () => {
    const { isActionable } = await import("./notifications");
    const awaiting = new Set(["s1"]);
    expect(isActionable(n(), awaiting)).toBe(true);
    expect(isActionable(n({ status: "ready" }), awaiting)).toBe(false); // frozen status wasn't approval
    expect(isActionable(n(), new Set())).toBe(false); // prompt already answered in the pane
  });
});

describe("groupNotifications", () => {
  it("splits actionable / today / older", async () => {
    const { groupNotifications } = await import("./notifications");
    const awaiting = new Set(["s1"]);
    const needsYou = n();
    const today = n({ id: "n2", sessionId: "s2", status: "ready", createdAt: T0 - 60_000 });
    const older = n({ id: "n3", sessionId: "s3", status: "error", createdAt: T0 - 24 * 3600_000 });
    const groups = groupNotifications([needsYou, today, older], awaiting, T0);
    expect(groups.needsYou.map((e) => e.id)).toEqual(["n1"]);
    expect(groups.earlierToday.map((e) => e.id)).toEqual(["n2"]);
    expect(groups.older.map((e) => e.id)).toEqual(["n3"]);
  });

  it("an awaiting entry whose session no longer awaits is a plain row, not NEEDS YOU", async () => {
    const { groupNotifications } = await import("./notifications");
    const groups = groupNotifications([n()], new Set(), T0);
    expect(groups.needsYou).toEqual([]);
    expect(groups.earlierToday.map((e) => e.id)).toEqual(["n1"]);
  });
});

describe("needs_you filter", () => {
  it("keeps only actionable entries", async () => {
    const entries = [n(), n({ id: "n2", sessionId: "s2", status: "ready" })];
    const { filterNotifications } = await import("./notifications");
    expect(filterNotifications(entries, "needs_you", null, new Set(["s1"])).map((e) => e.id)).toEqual(["n1"]);
  });
  it("chip labels use the design file's copy — no parens, 'This workspace' for the project chip", async () => {
    const { filterChipLabel } = await import("./notifications");
    expect(filterChipLabel("needs_you", 1, null)).toBe("Needs you 1");
    expect(filterChipLabel("all", 3, null)).toBe("All 3");
    expect(filterChipLabel("project", 2, "Demo")).toBe("This workspace 2");
  });
});

describe("relativeTime — design file drops the ' ago' suffix", () => {
  it("bare durations", () => {
    expect(relativeTime(T0 - 30_000, T0)).toBe("Just now");
    expect(relativeTime(T0 - 14 * 60_000, T0)).toBe("14m");
    expect(relativeTime(T0 - 2 * 3600_000, T0)).toBe("2h");
    expect(relativeTime(T0 - 26 * 3600_000, T0)).toBe("1 day");
  });
});

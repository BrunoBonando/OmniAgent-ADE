# Notification Approvals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user approve a session's pending tool-permission prompt directly from the notifications panel — plus restyle the panel to the founder's new reference design (NEEDS YOU section with Approve/Open pane buttons, engine tag chips, Needs-you filter, day grouping).

**Architecture:** Zero Rust changes. `sessions.rs` already detects Claude Code's "Do you want to" permission prompt and reports `awaiting_approval` status, and `SessionManager::write` already calls `mark_user_input()` which clears the attention latch (`sessions.rs:1619` → `:964-:979`) — so approving is exactly one existing command: `sessionWrite(sessionId, "1")` ("1" selects "Yes" in Claude Code's numbered permission dialog). Everything new is frontend: pure helpers in `state/notifications.ts`, rendering in `NotificationsPanel.tsx`, wiring in `App.tsx`/`AppChrome.tsx`.

**Tech Stack:** React 19 + TypeScript, Vitest + Testing Library (jsdom), existing Tauri command wrappers in `ui/src/lib/tauri.ts`. All commands run from `ui/`.

## Global Constraints

- No new dependencies.
- `state/notifications.ts` stays pure — zero React/Tauri imports (house style, see its module doc).
- The backend's `notify`/status flags are consumed as-is, never re-derived (existing rule in `notifications.ts`).
- `src-tauri/` is untouched by this plan.
- Conventional commits (`feat:`, `test:`), one per task.
- Every task ends with `npx vitest run <file>` green; final task runs the whole suite + `npx tsc --noEmit`.

## The reference design

**Authoritative source (checked in): `design/OmniAgent ADE.dc.html`, the "NOTIFICATIONS POPOVER" section (~lines 590–668).** Read it before Task 2 — every color, font size, padding and copy string below comes from there. Deltas it settles beyond the screenshot description:

- Chip copy has **no parentheses** and the project chip says **"This workspace"**, not the project's name: `All 3` · `This workspace 2` · `Needs you 1`.
- Timestamps are bare: `1m`, `14m`, `2h` — no " ago" suffix.
- The needs-you row: `background: rgba(240,180,70,.07)`, `border-left: 2px solid` amber; the app's amber token is `--status-approval` (used by `.session-light[data-status="awaiting_approval"]`, `App.css:1525`) — use the token, not the mock's raw `#f0b446`.
- Approve button: amber fill, near-black text `#1a1400`, `font 600 10.5px`, `padding 6px 11px`, `border-radius 6px`. Open pane: `border .5px solid rgba(255,255,255,.16)`, `background rgba(255,255,255,.05)`, color `#c2c2cb`, same radius.
- Band labels: `font 600 9.5px`, `letter-spacing .09em`, muted (use `--ink-faint`), with a `.5px` hairline `border-top` separating bands.
- Engine tags: `font 600 9.5px`, colored per engine. The mock's per-engine hexes are approximations — use `ENGINE_COLOR` (theme.ts), the product's single source for engine hues.

(Founder screenshot description kept below for the row anatomy; where the two disagree, the checked-in design file wins.)

A dark popover panel:

- Header row: **"Notifications"** + muted "3 new" + "Clear all" + × close.
- Filter chips: **"All 3"** (active), **"bridgemind-api 2"** (the selected project), **"Needs you 1"**.
- Section header **"NEEDS YOU"** (small caps, muted). Under it, one row with an amber left edge: amber status dot · title **"stripe webhook retries"** · engine tag **"CODEX"** in the engine's brand color (small caps) · time "1m" right-aligned · subtitle "Wants to write 3 files outside `src/stripe/` · main" · two buttons: **"Approve"** (solid amber, dark text) and **"Open pane"** (outlined, neutral).
- Section header **"EARLIER TODAY"**. Normal rows: green dot · title · engine tag ("AG", "CLAUDE") · time · subtitle ("Done · migration ready, 2 files +16 −1" / "Failed · `stream.service.spec.ts` 3 failing · bridgemind-ui") · × dismiss.

What we deliberately do NOT build (data we don't have — PTY scraping doesn't parse prompt contents): the rich subtitles ("Wants to write 3 files outside…", "+16 −1"). Rows keep the existing `notificationSubtitle` copy ("Needs your approval." / "Task completed." / "Error occurred."). Everything else in the reference is in scope.

## Key existing code (read before starting)

| What | Where |
|---|---|
| Panel component + row rendering | `ui/src/components/NotificationsPanel.tsx` |
| Pure state: entries, filter, reducer, persistence | `ui/src/state/notifications.ts` |
| Panel mount + all props | `ui/src/components/AppChrome.tsx:106-116`, `ui/src/App.tsx:1324-1336` |
| Live per-tab status (`TabInfo.status`) | `ui/src/state/sessions.ts:140`, updated by `tab/status` at `App.tsx:498` |
| PTY write wrapper | `ui/src/lib/tauri.ts:107` (`sessionWrite`) — App.tsx does **not** import it yet |
| Engine display tokens | `ui/src/theme.ts` (`ENGINE_LABEL`, `ENGINE_COLOR`) |
| Panel CSS | `ui/src/App.css` (search `notifications-`) |
| Existing tests to extend | `ui/src/state/notifications.test.ts`, `ui/src/components/NotificationsPanel.test.tsx`, `ui/src/App.notifications.test.tsx` |

**Critical trap:** 12 `App.*.test.tsx` files mock `./lib/tauri` with a `vi.mock` factory. When Task 3 makes `App.tsx` import `sessionWrite`, every one of those factories MUST gain a `sessionWrite` key or those suites fail with "No 'sessionWrite' export is defined on the mock". The full list: `App.closeWorkspace`, `App.bootRestore`, `App.agentInstallation.integration`, `App.closePane`, `App.newWorkspace`, `App.import`, `App.newSession`, `App.crossProjectPersistence`, `App.notifications`, `App.sessionRestore`, `App.requestNewTab`, `App.sessionNaming`.

---

### Task 1: Pure state — actionability, Needs-you filter, day grouping

**Files:**
- Modify: `ui/src/state/notifications.ts`
- Test: `ui/src/state/notifications.test.ts`

**Interfaces:**
- Consumes: existing `NotificationEntry`, `NotificationFilter`, `filterNotifications`, `filterChipLabel`.
- Produces (Tasks 2–3 rely on these exact signatures):
  - `approveKeystroke(engine: string): string | null`
  - `isActionable(entry: NotificationEntry, awaiting: ReadonlySet<string>): boolean`
  - `type NotificationFilter = "all" | "project" | "needs_you"`
  - `filterNotifications(entries, filter, projectId, awaiting: ReadonlySet<string>)` (4th param added)
  - `filterChipLabel(filter, count, projectLabel)` handles `"needs_you"` → `Needs you (N)`
  - `groupNotifications(entries: NotificationEntry[], awaiting: ReadonlySet<string>, now: number): { needsYou: NotificationEntry[]; earlierToday: NotificationEntry[]; older: NotificationEntry[] }`

- [ ] **Step 1: Write the failing tests**

Append to `ui/src/state/notifications.test.ts` (reuse its existing `entry()` fixture helper if one exists; otherwise this local one):

```ts
import {
  approveKeystroke,
  isActionable,
  groupNotifications,
  filterNotifications,
  filterChipLabel,
  type NotificationEntry,
} from "./notifications";

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
  it("knows Claude's numbered permission dialog: '1' selects Yes", () => {
    expect(approveKeystroke("claude")).toBe("1");
  });
  it("returns null for every engine without a known approve gesture", () => {
    for (const engine of ["codex", "shell", "copilot", "antigravity", "unknown"]) {
      expect(approveKeystroke(engine)).toBeNull();
    }
  });
});

describe("isActionable", () => {
  it("true only for an awaiting_approval entry whose session still awaits right now", () => {
    const awaiting = new Set(["s1"]);
    expect(isActionable(n(), awaiting)).toBe(true);
    expect(isActionable(n({ status: "ready" }), awaiting)).toBe(false); // frozen status wasn't approval
    expect(isActionable(n(), new Set())).toBe(false); // prompt already answered in the pane
  });
});

describe("groupNotifications", () => {
  it("splits actionable / today / older", () => {
    const awaiting = new Set(["s1"]);
    const needsYou = n();
    const today = n({ id: "n2", sessionId: "s2", status: "ready", createdAt: T0 - 60_000 });
    const older = n({ id: "n3", sessionId: "s3", status: "error", createdAt: T0 - 24 * 3600_000 });
    const groups = groupNotifications([needsYou, today, older], awaiting, T0);
    expect(groups.needsYou.map((e) => e.id)).toEqual(["n1"]);
    expect(groups.earlierToday.map((e) => e.id)).toEqual(["n2"]);
    expect(groups.older.map((e) => e.id)).toEqual(["n3"]);
  });

  it("an awaiting entry whose session no longer awaits is a plain row, not NEEDS YOU", () => {
    const groups = groupNotifications([n()], new Set(), T0);
    expect(groups.needsYou).toEqual([]);
    expect(groups.earlierToday.map((e) => e.id)).toEqual(["n1"]);
  });
});

describe("needs_you filter", () => {
  it("keeps only actionable entries", () => {
    const entries = [n(), n({ id: "n2", sessionId: "s2", status: "ready" })];
    expect(filterNotifications(entries, "needs_you", null, new Set(["s1"])).map((e) => e.id)).toEqual(["n1"]);
  });
  it("chip labels use the design file's copy — no parens, 'This workspace' for the project chip", () => {
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run src/state/notifications.test.ts`
Expected: FAIL — `approveKeystroke`, `isActionable`, `groupNotifications` not exported; `filterNotifications` arity/behavior.

- [ ] **Step 3: Implement in `ui/src/state/notifications.ts`**

Add (near `notificationSubtitle`, keeping the module's comment voice):

```ts
/** The keystroke that answers an engine's pending permission prompt with
 * "yes", written straight into its PTY (`sessionWrite`) — the same input
 * path typing in the pane uses, which also clears the Rust-side attention
 * latch (`sessions.rs`'s `mark_user_input`). Claude Code's dialog is a
 * numbered select where the digit picks the option outright, so `"1"` is
 * "Yes" without trusting where the highlight currently sits.
 *
 * ponytail: version-coupled to Claude Code's own dialog, exactly like the
 * `ATTENTION_MARKERS` scrape that detects the prompt in the first place —
 * one assumption, both sides of it. Other engines return `null` (no known
 * gesture) and their rows offer "Open pane" only; add an entry here when an
 * engine's prompt gesture is verified against a real session. */
const APPROVE_KEYSTROKES: Record<string, string> = { claude: "1" };

export function approveKeystroke(engine: string): string | null {
  return APPROVE_KEYSTROKES[engine] ?? null;
}

/** Actionable = this row froze an `awaiting_approval` AND that session is
 * still awaiting right now (`awaiting` = live status, passed in by the
 * caller). Both halves matter: without the live check, Approve would type
 * into whatever replaced the prompt since. */
export function isActionable(entry: NotificationEntry, awaiting: ReadonlySet<string>): boolean {
  return entry.status === "awaiting_approval" && awaiting.has(entry.sessionId);
}

/** The reference panel's three bands: NEEDS YOU (actionable, whatever their
 * age — a blocked session doesn't stop being blocked at midnight), then
 * EARLIER TODAY / OLDER by local calendar day. */
export function groupNotifications(
  entries: NotificationEntry[],
  awaiting: ReadonlySet<string>,
  now: number,
): { needsYou: NotificationEntry[]; earlierToday: NotificationEntry[]; older: NotificationEntry[] } {
  const startOfToday = new Date(now).setHours(0, 0, 0, 0);
  const needsYou: NotificationEntry[] = [];
  const earlierToday: NotificationEntry[] = [];
  const older: NotificationEntry[] = [];
  for (const entry of entries) {
    if (isActionable(entry, awaiting)) needsYou.push(entry);
    else if (entry.createdAt >= startOfToday) earlierToday.push(entry);
    else older.push(entry);
  }
  return { needsYou, earlierToday, older };
}
```

Change the filter type and the two existing functions:

```ts
export type NotificationFilter = "all" | "project" | "needs_you";

export function filterNotifications(
  entries: NotificationEntry[],
  filter: NotificationFilter,
  projectId: string | null,
  awaiting: ReadonlySet<string>,
): NotificationEntry[] {
  if (filter === "all") return entries;
  if (filter === "needs_you") return entries.filter((e) => isActionable(e, awaiting));
  if (projectId === null) return [];
  return entries.filter((e) => e.project === projectId);
}
```

Rewrite `filterChipLabel` to the design file's copy (no parentheses; the project chip reads "This workspace" regardless of `projectLabel` — the parameter stays for signature stability but is no longer rendered):

```ts
export function filterChipLabel(
  filter: NotificationFilter,
  count: number,
  _projectLabel: string | null,
): string {
  const name = filter === "all" ? "All" : filter === "needs_you" ? "Needs you" : "This workspace";
  return `${name} ${count}`;
}
```

And in `relativeTime`, drop the " ago" suffixes (design file: `14m`, `2h`): `` `${minutes}m` ``, `` `${hours}h` ``, `"1 day"` / `` `${days} days` ``. Existing tests in this file and `NotificationsPanel.test.tsx` that pin the old copy ("All sessions (3)", "14m ago") must be updated to the new strings as part of this task.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run src/state/notifications.test.ts`
Expected: PASS (new tests AND the file's pre-existing ones — the existing `filterNotifications` tests need their call sites updated to pass `new Set()` as the 4th argument; do that as part of this step).

- [ ] **Step 5: Commit**

```bash
git add ui/src/state/notifications.ts ui/src/state/notifications.test.ts
git commit -m "feat(notifications): approve keystrokes, needs-you filter, day grouping"
```

---

### Task 2: Panel UI — NEEDS YOU band, engine tags, Approve/Open pane, CSS

**Files:**
- Modify: `ui/src/components/NotificationsPanel.tsx`
- Modify: `ui/src/theme.ts`
- Modify: `ui/src/App.css`
- Test: `ui/src/components/NotificationsPanel.test.tsx`

**Interfaces:**
- Consumes (Task 1): `approveKeystroke`, `isActionable`, `groupNotifications`, `filterNotifications` (4-arg), `filterChipLabel("needs_you", …)`.
- Produces (Task 3 relies on): two new `NotificationsPanelProps`:
  - `awaitingSessionIds: string[]` — sessions whose **current** status is `awaiting_approval`
  - `onApprove: (entry: NotificationEntry) => void`

- [ ] **Step 1: Add `ENGINE_TAG` to `ui/src/theme.ts`**

Next to `ENGINE_LABEL` (the reference's rows tag each entry with a short caps mark — "CODEX", "CLAUDE", "AG"):

```ts
/** The notification row's short caps tag — the reference design abbreviates
 * where the full label would crowd the title ("AG", not "ANTIGRAVITY"). */
export const ENGINE_TAG: Record<Engine, string> = {
  claude: "CLAUDE",
  codex: "CODEX",
  shell: "SHELL",
  copilot: "COPILOT",
  antigravity: "AG",
};
```

- [ ] **Step 2: Write the failing component tests**

Append to `ui/src/components/NotificationsPanel.test.tsx` — its `setup()` builds props with spread-over defaults; add the two new keys to the defaults first (`awaitingSessionIds: []`, `onApprove: vi.fn()`), then:

```ts
describe("needs-you band and approval", () => {
  const awaitingEntry = () =>
    entry({ id: "a1", sessionId: "sess-1", status: "awaiting_approval", title: "stripe webhook retries" });

  it("an actionable row sits under NEEDS YOU with Approve and Open pane", () => {
    setup({ entries: [awaitingEntry()], awaitingSessionIds: ["sess-1"] });
    openPanel();
    expect(screen.getByText("NEEDS YOU")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /approve stripe webhook retries/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /open pane/i })).toBeInTheDocument();
  });

  it("Approve fires onApprove with the entry and keeps the panel open", () => {
    const props = setup({ entries: [awaitingEntry()], awaitingSessionIds: ["sess-1"] });
    openPanel();
    fireEvent.click(screen.getByRole("button", { name: /approve stripe webhook retries/i }));
    expect(props.onApprove).toHaveBeenCalledWith(expect.objectContaining({ id: "a1" }));
    expect(screen.getByText("NEEDS YOU")).toBeInTheDocument(); // still open
  });

  it("a session that stopped awaiting renders as a plain row — no Approve, no NEEDS YOU", () => {
    setup({ entries: [awaitingEntry()], awaitingSessionIds: [] });
    openPanel();
    expect(screen.queryByText("NEEDS YOU")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /approve/i })).not.toBeInTheDocument();
  });

  it("an engine with no approve keystroke gets Open pane only", () => {
    setup({
      entries: [entry({ id: "a2", sessionId: "sess-1", status: "awaiting_approval", engine: "codex" })],
      awaitingSessionIds: ["sess-1"],
    });
    openPanel();
    expect(screen.getByText("NEEDS YOU")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /approve/i })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /open pane/i })).toBeInTheDocument();
  });

  it("the Needs you chip filters to actionable rows", () => {
    setup({
      entries: [awaitingEntry(), entry({ id: "n2", sessionId: "s2", status: "ready" })],
      awaitingSessionIds: ["sess-1"],
    });
    openPanel();
    fireEvent.click(screen.getByRole("button", { name: /needs you 1/i }));
    expect(screen.getByText("stripe webhook retries")).toBeInTheDocument();
    expect(screen.queryByText("wire session restore")).not.toBeInTheDocument();
  });
});

describe("engine tag and day bands", () => {
  it("rows carry the engine's short caps tag", () => {
    setup({ entries: [entry({ engine: "codex" })] });
    openPanel();
    expect(screen.getByText("CODEX")).toBeInTheDocument();
  });

  it("today's rows sit under EARLIER TODAY, yesterday's under OLDER", () => {
    setup({
      entries: [
        entry({ id: "n1", sessionId: "s1" }),
        entry({ id: "n2", sessionId: "s2", createdAt: NOW - 26 * 3600_000 }),
      ],
    });
    openPanel();
    expect(screen.getByText("EARLIER TODAY")).toBeInTheDocument();
    expect(screen.getByText("OLDER")).toBeInTheDocument();
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npx vitest run src/components/NotificationsPanel.test.tsx`
Expected: FAIL — unknown props, missing sections/buttons. (Pre-existing tests may also fail on the new required props until `setup()`'s defaults gain them — that edit is part of Step 2.)

- [ ] **Step 4: Implement the panel changes**

In `NotificationsPanel.tsx`:

1. Props: add `awaitingSessionIds: string[]` and `onApprove: (entry: NotificationEntry) => void` to `NotificationsPanelProps` and destructure them.
2. Imports: `approveKeystroke`, `groupNotifications` from `../state/notifications`; `ENGINE_TAG`, `ENGINE_COLOR` from `../theme`; `type Engine` from `../state/sessions`.
3. Derive:

```ts
const awaiting = useMemo(() => new Set(awaitingSessionIds), [awaitingSessionIds]);
const visible = filterNotifications(entries, filter, selectedProjectId, awaiting);
const projectCount = filterNotifications(entries, "project", selectedProjectId, awaiting).length;
const needsYouCount = filterNotifications(entries, "needs_you", null, awaiting).length;
const groups = groupNotifications(visible, awaiting, clock);
```

4. Chips row: after the project chip, add (mirroring the existing chip markup exactly):

```tsx
<button
  type="button"
  className={`notifications-chip${filter === "needs_you" ? " is-active" : ""}`}
  aria-pressed={filter === "needs_you"}
  onClick={() => setFilter("needs_you")}
>
  {filterChipLabel("needs_you", needsYouCount, null)}
</button>
```

5. Replace the single `<ul className="notifications-list">` with three banded lists, each rendered only when non-empty — one small local component keeps it flat:

```tsx
function Band({ label, items }: { label: string; items: NotificationEntry[] }) {
  if (items.length === 0) return null;
  return (
    <>
      <h3 className="notifications-band-label">{label}</h3>
      <ul className="notifications-list">
        {items.map((e) => (
          <NotificationRow
            key={e.id}
            entry={e}
            now={clock}
            actionable={label === "NEEDS YOU"}
            canJump={live.has(e.sessionId) || projects.has(e.project)}
            onSelect={() => { onSelect(e); setOpen(false); }}
            onApprove={() => onApprove(e)}
            onDismiss={() => onDismiss(e.id)}
          />
        ))}
      </ul>
    </>
  );
}
```

used as:

```tsx
<Band label="NEEDS YOU" items={groups.needsYou} />
<Band label="EARLIER TODAY" items={groups.earlierToday} />
<Band label="OLDER" items={groups.older} />
```

(The empty-state `<p>` keeps its existing condition, now `visible.length === 0`.)

6. `NotificationRow`: add `actionable: boolean` and `onApprove: () => void` props. Inside the body, after the title, the engine tag; after the subtitle, the action row when actionable:

```tsx
<span className="notification-row-title">
  {entry.title}
  <span
    className="notification-row-engine"
    style={{ color: ENGINE_COLOR[entry.engine as Engine] }}
  >
    {ENGINE_TAG[entry.engine as Engine] ?? entry.engine.toUpperCase()}
  </span>
</span>
```

```tsx
{actionable && (
  <span className="notification-row-actions">
    {approveKeystroke(entry.engine) !== null && (
      <button
        type="button"
        className="notification-approve"
        onClick={(e) => { e.stopPropagation(); onApprove(); }}
        aria-label={`Approve ${entry.title} in ${entry.projectLabel}`}
      >
        Approve
      </button>
    )}
    <button
      type="button"
      className="notification-open-pane"
      onClick={(e) => { e.stopPropagation(); onSelect(); }}
    >
      Open pane
    </button>
  </span>
)}
```

Add `is-actionable` to the row's className when `actionable`, driving the amber left edge. Because these buttons now nest conceptually inside a clickable row, change `notification-row-main` from a `<button>` wrapper to a `<div role="button" tabIndex={0}` with `onClick`/`onKeyDown`(Enter/Space) — nested real buttons inside a button are invalid HTML and jsdom/screen-reader hostile. Keep its existing `aria-label`.

7. CSS in `App.css`, next to the other `notification-` rules — values from `design/OmniAgent ADE.dc.html`'s NOTIFICATIONS POPOVER section; the amber token is `--status-approval` (already used at `App.css:1525`):

```css
/* Band labels + the NEEDS YOU row treatment — design/OmniAgent ADE.dc.html,
   NOTIFICATIONS POPOVER. */
.notifications-band-label {
  padding: 9px 12px 5px;
  border-top: 0.5px solid rgba(255, 255, 255, 0.06);
  font-size: 9.5px;
  font-weight: 600;
  letter-spacing: 0.09em;
  color: var(--ink-faint);
}

.notification-row.is-actionable {
  background: rgba(240, 180, 70, 0.07);
  border-left: 2px solid var(--status-approval);
}

.notification-row.is-actionable:hover {
  background: rgba(240, 180, 70, 0.11);
}

.notification-row-engine {
  margin-left: 7px;
  font-size: 9.5px;
  font-weight: 600;
  letter-spacing: 0.02em;
}

.notification-row-actions {
  display: flex;
  gap: 6px;
  margin-top: 7px;
}

.notification-approve {
  appearance: none;
  border: 0;
  background: var(--status-approval);
  color: #1a1400;
  font-size: 10.5px;
  font-weight: 600;
  padding: 6px 11px;
  border-radius: 6px;
}

.notification-approve:hover {
  filter: brightness(1.1);
}

.notification-open-pane {
  appearance: none;
  border: 0.5px solid rgba(255, 255, 255, 0.16);
  background: rgba(255, 255, 255, 0.05);
  color: #c2c2cb;
  font-size: 10.5px;
  font-weight: 500;
  padding: 6px 10px;
  border-radius: 6px;
}

.notification-open-pane:hover {
  background: rgba(255, 255, 255, 0.1);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npx vitest run src/components/NotificationsPanel.test.tsx`
Expected: PASS — new tests and every pre-existing one (row-click navigation, dismiss, badge, filters).

- [ ] **Step 6: Commit**

```bash
git add ui/src/components/NotificationsPanel.tsx ui/src/theme.ts ui/src/App.css ui/src/components/NotificationsPanel.test.tsx
git commit -m "feat(notifications): NEEDS YOU band with Approve/Open pane, engine tags, day bands"
```

---

### Task 3: Wiring — App.tsx approve handler, AppChrome pass-through, end-to-end test

**Files:**
- Modify: `ui/src/App.tsx`
- Modify: `ui/src/components/AppChrome.tsx`
- Modify (mechanical, one line each): the 12 `App.*.test.tsx` `vi.mock("./lib/tauri")` factories listed in Global Constraints' trap note
- Test: `ui/src/App.notifications.test.tsx`

**Interfaces:**
- Consumes: `sessionWrite(id, data)` (`lib/tauri.ts:107`), `approveKeystroke` (Task 1), panel props (Task 2), `TabInfo.status` (`state/sessions.ts:140`).
- Produces: nothing downstream — this is the last wiring layer.

- [ ] **Step 1: Write the failing end-to-end test**

In `App.notifications.test.tsx`: add `sessionWriteMock: vi.fn()` to its `tauriMocks` and `sessionWrite: tauriMocks.sessionWriteMock` to its factory; reset it in `beforeEach` with `mockResolvedValue(undefined)`. Then, following the file's existing pattern of driving a real `session-status:` event (`emitStatus`-style helper already in the file) and opening the panel:

```ts
it("Approve writes the engine's yes-keystroke to the session and clears the row", async () => {
  await bootWithTabs(); // whatever the file's existing boot helper is called
  // Drive the session to awaiting_approval while the user is on another project,
  // so a notification is recorded AND the tab's live status is awaiting.
  emitStatus("tab-1", { id: "tab-1", status: "awaiting_approval", notify: true, engine: "claude" });

  fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
  fireEvent.click(await screen.findByRole("button", { name: /^Approve / }));

  await waitFor(() => expect(tauriMocks.sessionWriteMock).toHaveBeenCalledWith("tab-1", "1"));
  await waitFor(() =>
    expect(screen.queryByRole("button", { name: /^Approve / })).not.toBeInTheDocument(),
  );
});
```

(Adapt helper names to the file's actual ones — it already boots projects/tabs and fires status events; reuse those verbatim rather than inventing new scaffolding.)

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/App.notifications.test.tsx`
Expected: FAIL — App passes no `awaitingSessionIds`/`onApprove` (TypeScript will already flag the missing panel props from Task 2; that pre-existing redness is this task's job to fix).

- [ ] **Step 3: Implement the wiring**

`App.tsx`:

1. Import `sessionWrite` alongside the other `./lib/tauri` imports, `approveKeystroke` + `type NotificationEntry` from `./state/notifications` (NotificationEntry may already be imported).
2. Derive the awaiting set near the other tab-derived memos:

```ts
const awaitingSessionIds = useMemo(
  () => state.tabs.filter((t) => t.status === "awaiting_approval").map((t) => t.id),
  [state.tabs],
);
```

3. The handler, next to `handleNotificationSelect` (`App.tsx:1134`):

```ts
// Approve-from-the-panel (founder ask, 2026-07-27: the notification row's
// own Approve button, so a pending tool-permission prompt never forces a
// trip to the pane). One write of the engine's yes-keystroke down the same
// PTY path typing uses — which also clears the Rust attention latch, so the
// amber state resolves exactly as if the user had answered in the pane.
// Re-checked against the CURRENT status at click time: a prompt already
// answered in the pane must not get a stray "1" typed into whatever
// replaced it.
const handleNotificationApprove = useCallback(
  async (entry: NotificationEntry) => {
    const keystroke = approveKeystroke(entry.engine);
    const tab = state.tabs.find((t) => t.id === entry.sessionId);
    if (!keystroke || !tab || tab.status !== "awaiting_approval") return;
    try {
      await sessionWrite(entry.sessionId, keystroke);
      notificationsDispatch({ type: "notification/dismissed", id: entry.id });
    } catch (err) {
      console.error("approve from notifications failed", err);
      setErrorBanner(`Couldn't approve "${entry.title}" — open its pane and answer there.`);
    }
  },
  [state.tabs],
);
```

4. Pass both through `<AppChrome …>`:

```tsx
awaitingSessionIds={awaitingSessionIds}
onApproveNotification={(entry) => void handleNotificationApprove(entry)}
```

`AppChrome.tsx`: add `awaitingSessionIds: string[]` and `onApproveNotification: (entry: NotificationEntry) => void` to `AppChromeProps`, forward as the panel's `awaitingSessionIds`/`onApprove`.

The 12 test factories: add `sessionWrite: vi.fn(async () => undefined),` (or a hoisted named mock where the file's style uses them) to each `vi.mock("./lib/tauri", …)` factory.

- [ ] **Step 4: Run the notifications suite, then the full suite**

Run: `npx vitest run src/App.notifications.test.tsx` → PASS
Run: `npx vitest run` → PASS (proves all 12 factories were patched)
Run: `npx tsc --noEmit` → clean

- [ ] **Step 5: Commit**

```bash
git add ui/src/App.tsx ui/src/components/AppChrome.tsx ui/src/App.notifications.test.tsx ui/src/App.*.test.tsx
git commit -m "feat(notifications): approve a pending permission prompt from the panel"
```

---

### Task 4: Verify against the real app

- [ ] **Step 1: Run the dev app**

Run: `cd src-tauri && cargo tauri dev` (or build the `.app`: `cd src-tauri && ../ui/node_modules/.bin/tauri build`).

- [ ] **Step 2: Manual script**

1. Open a workspace with a Claude session; ask Claude to do something permission-gated (e.g. "create a file called probe.txt").
2. Switch to a different project so the prompt fires a notification (the on-screen suppression rule would otherwise swallow it).
3. Open the notifications panel: the row must sit under **NEEDS YOU** with the amber edge, CLAUDE tag, Approve + Open pane.
4. Click **Approve**: the row disappears, and back in the pane Claude has proceeded (file created) — no keystroke residue in the input.
5. Repeat once but answer in the *pane* first, then open the panel: the row must have dropped to EARLIER TODAY with no Approve button.
6. "Needs you" chip shows the live count; "Clear all", dismiss ×, and row-click navigation all still work.

- [ ] **Step 3: Commit anything the manual pass shook out, then hand back for review**

## Self-review notes

- Spec coverage: Approve action ✓ (T1 keystroke, T2 button, T3 write), Open pane ✓ (T2, existing onSelect), Needs-you chip ✓ (T1+T2), NEEDS YOU / EARLIER TODAY bands ✓ (T1+T2), engine tags ✓ (T2), rich diff subtitles — explicitly out of scope (no data), stated up front.
- The one behavioral risk — Approve racing a prompt answered in the pane — is guarded twice: render-time (`awaitingSessionIds` gates the button) and click-time (handler re-checks `tab.status`).
- Non-Claude engines: `approveKeystroke` returns `null` → Open pane only. Today only Claude ever *reaches* `awaiting_approval` (detection scrapes Claude's own prompt copy), so this is future-proofing, not dead UI: the band renders for any engine the backend ever flags.

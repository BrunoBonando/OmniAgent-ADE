# Terminal Agent Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hovering a pane's `+` opens a menu of installed agents that spawns one on click; ⌘T opens a logo-button modal with the default preselected and full keyboard control.

**Architecture:** One detection hook (`useInstalledAgents`) feeds two dumb presentational components — `AgentMenu` (popover, reuses `.pane-menu` CSS) and `AgentPicker` (modal, replaces the dead `EnginePicker.tsx`, reuses `.engine-picker` CSS). `requestNewTab` gains an optional `engine` argument; every other caller is behaviourally unchanged.

**Tech Stack:** React 19, TypeScript 5.8, Vitest 4 + @testing-library/react, Tauri 2 (Rust backend untouched by this plan).

**Spec:** `docs/superpowers/specs/2026-07-26-terminal-agent-picker-design.md`

## Global Constraints

- **All five agents are offerable.** As of commit `1b34dee` ("make the five-agent list actually
  work end to end", a parallel session, 2026-07-26 17:5x) the backend supports every agent the
  frontend names:
  - `build_engine_argv` (`src-tauri/src/sessions.rs:2208`) gained a
    `name @ ("copilot" | "antigravity")` arm that spawns the agent bare via `binary_for(name)`.
  - `src-tauri/src/commands/agents.rs` now holds one `AGENTS` table of `{name, binary, install}`.
    `shell` has `binary: None` and is always reported installed; `antigravity`'s binary is `agy`.
  - `agents_check_installed` filters on `binary`, not `name` — so its answer is now **correct as
    given** and needs no frontend correction.

  This replaces an earlier draft of this plan that carried a `SPAWNABLE` literal and a
  shell special-case to work around those two bugs. Both are now fixed at the source; do not
  reintroduce either. `ENGINES` (= `AVAILABLE_AGENTS`, all five) is once again a truthful list.
- **Do not edit `ui/src/state/agents.ts` or `src-tauri/src/commands/agents.rs`.** The Rust test
  `agents_match_frontend` pins the two to the same five names in the same order. This plan
  consumes that list and never redefines it.
- **`shell` is always installed.** `agents_check_installed` runs `which::which("shell")`, which never resolves; shell spawns `$SHELL` and cannot fail to be available.
- **Do not wire `agents.ts`'s reducer.** Its install-state machine belongs to the parallel
  agent-installation work. This plan reads the installed list via `agentCheckInstalled()` only.
- **Do not change behaviour of the sidebar `+` or the map's "Open terminal here."** Both keep spawning the default silently.
- No new npm dependencies. Icon geometry is inlined, not fetched.
- Run tests from `ui/`: `npm test`.
- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`.
- Baseline at branch point (`1b34dee`): 60 test files, 1024 tests, all passing. Any failure you
  see is yours.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `ui/src/components/Icon.tsx` | Modify | Add `agent-claude`, `agent-codex`, `agent-shell` to `IconName` + `PATHS` |
| `ui/src/theme.ts` | Modify | Add `AGENT_ICON: Record<Engine, IconName>` beside the existing per-engine maps |
| `ui/src/lib/useInstalledAgents.ts` | Create | `installedEngines(names)` pure filter + `useInstalledAgents()` hook |
| `ui/src/lib/useInstalledAgents.test.ts` | Create | Filter + hook coverage |
| `ui/src/components/AgentMenu.tsx` | Create | Hover popover listing installed agents |
| `ui/src/components/AgentMenu.test.tsx` | Create | Row rendering + pick callback |
| `ui/src/components/PaneHeader.tsx` | Modify | `+` opens `AgentMenu`; `onSplit` takes an `Engine` |
| `ui/src/components/PaneHeader.test.tsx` | Modify | 4 existing `<PaneHeader>` renders need the new `agents` prop; add hover/pick tests |
| `ui/src/components/AgentPicker.tsx` | Create | ⌘T modal — logo grid, keyboard nav |
| `ui/src/components/AgentPicker.test.tsx` | Create | Default preselect, arrows, digits, Escape |
| `ui/src/components/EnginePicker.tsx` | **Delete** | Dead since the instant-default-engine change |
| `ui/src/components/Workspace.tsx` | Modify | Thread `agents` down, pass engine up through `onSplit` |
| `ui/src/App.tsx` | Modify | `useInstalledAgents()`, `requestNewTab(project, engine?)`, ⌘T opens the picker |
| `ui/src/App.css` | Modify | `.agent-menu-logo`, `.agent-picker-grid`, `.agent-picker-btn` |
| `ui/src/App.agentPicker.test.tsx` | Create | ⌘T opens picker; confirm spawns chosen engine; sidebar `+` unchanged |

---

## Task 1: Agent logos

**Files:**
- Modify: `ui/src/components/Icon.tsx:14-28` (the `IconName` union), `ui/src/components/Icon.tsx:30` (the `PATHS` record)
- Modify: `ui/src/theme.ts` (append after `ENGINE_HINT`, line 43)
- Test: `ui/src/components/Icon.test.tsx` (create if absent)

**Interfaces:**
- Consumes: nothing.
- Produces: `IconName` gains `"agent-claude" | "agent-codex" | "agent-shell"`. `theme.ts` exports `AGENT_ICON: Record<Engine, IconName>`.

**Background the implementer needs:** `Icon.tsx` renders one shared `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor">`. Brand marks are *solid* shapes, not strokes, so each sets `fill="currentColor" stroke="none"` on its own `<path>` — exactly how the existing `more` icon overrides the shared attributes for its dots (`Icon.tsx:76-80`). No prop or signature change to `Icon`.

**`AGENT_ICON` must cover all five agents.** `Engine` aliases `Agent` (commit `f9bf83c`), so `Record<Engine, IconName>` will not type-check without `copilot` and `antigravity` keys — and `theme.ts` already carries all five in `ENGINE_LABEL`/`ENGINE_COLOR`/`ENGINE_HINT` (commit `8867d57`). All five genuinely reach the ⌘T picker on a machine that has them installed, since commit `1b34dee` made every one spawnable. These marks are user-facing for all five, not placeholders for two of them.

Claude, codex and copilot geometry is copied from [simple-icons](https://github.com/simple-icons/simple-icons) (`claude.svg`, `openai.svg`, `githubcopilot.svg`), which is CC0 — that licence is why we use their traced paths rather than copying marks off a vendor site.

Two icons are not brand marks, for stated reasons:
- `agent-shell` is Lucide's `terminal` glyph (ISC, the source of every other icon in this file), chosen over simple-icons' `gnubash` hexagon: 2 stroke paths instead of a 2KB filled logo, and "shell" here means `$SHELL`, not GNU Bash specifically.
- `agent-antigravity` is a hand-drawn rising-arrow glyph. simple-icons has **no** `antigravity` slug (verified: 404), so there is no CC0 mark to copy and none gets invented from memory.

- [ ] **Step 1: Write the failing test**

Create `ui/src/components/Icon.test.tsx`:

```tsx
import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import Icon from "./Icon";
import { AGENT_ICON } from "../theme";
import { ENGINES } from "../state/sessions";

describe("agent logos", () => {
  it("has a distinct icon for every engine", () => {
    const names = ENGINES.map((e) => AGENT_ICON[e]);
    expect(new Set(names).size).toBe(ENGINES.length);
  });

  it("renders a non-empty path for each agent icon", () => {
    for (const engine of ENGINES) {
      const { container } = render(<Icon name={AGENT_ICON[engine]} />);
      const paths = container.querySelectorAll("path");
      expect(paths.length).toBeGreaterThan(0);
      expect(paths[0].getAttribute("d")).toBeTruthy();
    }
  });

  it("draws the brand marks as fills, not strokes", () => {
    for (const engine of ["claude", "codex", "copilot"] as const) {
      const { container } = render(<Icon name={AGENT_ICON[engine]} />);
      expect(container.querySelector("path")?.getAttribute("fill")).toBe("currentColor");
    }
  });

  // `Engine` aliases `Agent` since commit f9bf83c, so this map has to cover
  // all five installable agents or `Record<Engine, IconName>` won't compile.
  it("covers every installable agent, not just the spawnable ones", () => {
    for (const engine of ENGINES) expect(AGENT_ICON[engine]).toBeTruthy();
    expect(ENGINES.length).toBe(5);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ui && npx vitest run src/components/Icon.test.tsx`
Expected: FAIL — `AGENT_ICON` is not exported from `../theme`.

- [ ] **Step 3: Add the three icons**

In `ui/src/components/Icon.tsx`, extend the union (after `| "plus"`):

```tsx
  | "plus"
  | "agent-claude"
  | "agent-codex"
  | "agent-copilot"
  | "agent-antigravity"
  | "agent-shell"
  | "x";
```

Add to `PATHS`, immediately after the `plus` entry:

```tsx
  // Brand marks from simple-icons (CC0) — filled shapes, so they override
  // the shared stroke attributes the way `more` does. Tinted by the caller
  // via `currentColor` + ENGINE_COLOR, so a pane header's engine dot and
  // this logo are always the same hue.
  "agent-claude": (
    <path
      fill="currentColor"
      stroke="none"
      d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
    />
  ),
  "agent-codex": (
    <path
      fill="currentColor"
      stroke="none"
      d="M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"
    />
  ),
  "agent-copilot": (
    <path
      fill="currentColor"
      stroke="none"
      d="M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1 0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644-1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952C7.255 2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132 2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605 2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1-.355.508c-.77.947-1.918 1.492-3.508 1.492-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403 1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558-2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462.472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394 2.344-.938.475-.584.742-1.44.878-2.497Z"
    />
  ),
  // No simple-icons slug exists for Antigravity, so this is a plain
  // rising-arrow glyph in the house stroke style rather than a guessed
  // brand mark. Swap it for the real one if a CC0 trace ever lands.
  "agent-antigravity": (
    <>
      <path d="M12 20V5" />
      <path d="m6 11 6-6 6 6" />
    </>
  ),
  "agent-shell": (
    <>
      <path d="m4 17 6-6-6-6" />
      <path d="M12 19h8" />
    </>
  ),
```

In `ui/src/theme.ts`, add the import and the map:

```ts
import type { IconName } from "./components/Icon";
```

```ts
/** Which mark stands for each agent — the fourth per-engine lookup, kept
 * here with LABEL/COLOR/HINT so adding one means editing a single file.
 * Covers all five agents, matching the other three maps. Which of them a
 * given machine is offered is `lib/useInstalledAgents.ts`'s question, not
 * this map's — every agent has a mark whether or not it is installed. */
export const AGENT_ICON: Record<Engine, IconName> = {
  claude: "agent-claude",
  codex: "agent-codex",
  copilot: "agent-copilot",
  antigravity: "agent-antigravity",
  shell: "agent-shell",
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ui && npx vitest run src/components/Icon.test.tsx`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add ui/src/components/Icon.tsx ui/src/components/Icon.test.tsx ui/src/theme.ts
git commit -m "feat(ui): add per-agent logo icons"
```

---

## Task 2: Installed-agent detection

**Files:**
- Create: `ui/src/lib/useInstalledAgents.ts`
- Test: `ui/src/lib/useInstalledAgents.test.ts`

**Interfaces:**
- Consumes: `agentCheckInstalled(): Promise<string[]>` from `ui/src/lib/tauri.ts:562`; `ENGINES`, `isEngine`, `Engine` from `ui/src/state/sessions.ts:12,28`.
- Produces: `useInstalledAgents(): Engine[]` — hook, returns all of `ENGINES` until detection resolves.

**Background the implementer needs:** as of commit `1b34dee` the backend's answer is correct on its own — `agents_check_installed` reports built-ins (`shell`) as always present and probes everything else by its real binary (`agy` for antigravity). There is nothing left to correct here, so this hook does almost nothing: call, validate, store.

The one thing it does add is `isEngine` (`state/sessions.ts:28`) as a filter. That is not defensive padding against the current backend — it is the seam where a future backend/frontend list drift shows up as a missing button rather than as an `unsupported engine` crash at spawn time. `agents_match_frontend` pins the two lists today; `isEngine` is what keeps a broken pin cheap.

**Do not** reintroduce a `SPAWNABLE` literal or a `shell` special-case. An earlier draft of this plan had both, as workarounds for bugs commit `1b34dee` has since fixed at the source. Duplicating the agent list in the frontend is the exact drift that caused the original break.

- [ ] **Step 1: Write the failing test**

Create `ui/src/lib/useInstalledAgents.test.ts`:

```ts
import { renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const { agentCheckInstalledMock } = vi.hoisted(() => ({ agentCheckInstalledMock: vi.fn() }));
vi.mock("./tauri", () => ({ agentCheckInstalled: agentCheckInstalledMock }));

const { useInstalledAgents } = await import("./useInstalledAgents");

describe("useInstalledAgents", () => {
  beforeEach(() => agentCheckInstalledMock.mockReset());

  it("offers every agent until detection resolves", () => {
    agentCheckInstalledMock.mockReturnValue(new Promise(() => {}));
    const { result } = renderHook(() => useInstalledAgents());
    expect(result.current).toEqual(["claude", "codex", "shell", "copilot", "antigravity"]);
  });

  it("narrows to what the backend reports, in the order it reports", async () => {
    agentCheckInstalledMock.mockResolvedValue(["claude", "shell", "antigravity"]);
    const { result } = renderHook(() => useInstalledAgents());
    await waitFor(() => expect(result.current).toEqual(["claude", "shell", "antigravity"]));
  });

  it("trusts the backend about shell — no frontend special-case re-adds it", async () => {
    agentCheckInstalledMock.mockResolvedValue(["codex"]);
    const { result } = renderHook(() => useInstalledAgents());
    await waitFor(() => expect(result.current).toEqual(["codex"]));
  });

  // The seam that keeps a frontend/backend list drift cheap: an unknown name
  // becomes a missing button, not an `unsupported engine` crash at spawn.
  it("drops names it does not recognise as engines", async () => {
    agentCheckInstalledMock.mockResolvedValue(["claude", "cursor", "shell"]);
    const { result } = renderHook(() => useInstalledAgents());
    await waitFor(() => expect(result.current).toEqual(["claude", "shell"]));
  });

  it("falls back to every agent when detection fails", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    agentCheckInstalledMock.mockRejectedValue(new Error("no ipc"));
    const { result } = renderHook(() => useInstalledAgents());
    await waitFor(() => expect(err).toHaveBeenCalled());
    expect(result.current).toEqual(["claude", "codex", "shell", "copilot", "antigravity"]);
    err.mockRestore();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ui && npx vitest run src/lib/useInstalledAgents.test.ts`
Expected: FAIL — cannot resolve `./useInstalledAgents`.

- [ ] **Step 3: Write the implementation**

Create `ui/src/lib/useInstalledAgents.ts`:

```ts
// Which agents this machine can actually start a terminal with.
//
// Thin on purpose. `agents_check_installed` (src-tauri/src/commands/agents.rs)
// answers exactly this question as of commit 1b34dee: it walks the one
// `AGENTS` table, counts built-ins (`shell`, which has no binary) as always
// present, and probes everything else by its real executable — `agy` for
// antigravity, whose name and binary differ. There is no distortion left for
// the frontend to correct.
//
// An earlier draft of this module re-derived the spawnable set here, with a
// hardcoded three-engine list and a `shell` special-case, because the backend
// was wrong on both counts. It isn't anymore, and a second copy of the agent
// list in the frontend is precisely the drift that broke it the first time.
// If an agent is missing from the picker, fix `AGENTS` — not this file.
import { useEffect, useState } from "react";
import { agentCheckInstalled } from "./tauri";
import { ENGINES, isEngine, type Engine } from "../state/sessions";

export function useInstalledAgents(): Engine[] {
  // Starts permissive: detection is async, and a picker that opens empty for
  // a frame — or forever, if the IPC call fails — leaves the user with no way
  // to open a terminal at all. Over-offering degrades to a spawn that fails
  // loudly and legibly; under-offering is a dead end with no error to read.
  const [installed, setInstalled] = useState<Engine[]>(() => [...ENGINES]);

  useEffect(() => {
    let alive = true;
    agentCheckInstalled()
      .then((names) => {
        // `isEngine` is the seam, not paranoia: if `AGENTS` and
        // `AVAILABLE_AGENTS` ever drift past the `agents_match_frontend`
        // test that pins them, an unknown name becomes a button this UI
        // simply doesn't draw — instead of one that reaches `session_create`
        // and dies with "unsupported engine".
        if (alive) setInstalled(names.filter(isEngine));
      })
      .catch((err) => {
        console.error("agent detection failed, offering every agent", err);
      });
    return () => {
      alive = false;
    };
  }, []);

  return installed;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ui && npx vitest run src/lib/useInstalledAgents.test.ts`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add ui/src/lib/useInstalledAgents.ts ui/src/lib/useInstalledAgents.test.ts
git commit -m "feat(ui): detect which agents can actually spawn a terminal"
```

---

## Task 3: AgentMenu popover

**Files:**
- Create: `ui/src/components/AgentMenu.tsx`
- Test: `ui/src/components/AgentMenu.test.tsx`
- Modify: `ui/src/App.css` (append after the `.pane-menu-check` block, ~line 1800)

**Interfaces:**
- Consumes: `AGENT_ICON`, `ENGINE_COLOR`, `ENGINE_LABEL`, `ENGINE_HINT` from `../theme`; `Icon` from `./Icon`; `Engine` from `../state/sessions`.
- Produces:
  ```ts
  interface AgentMenuProps {
    agents: Engine[];
    onPick: (engine: Engine) => void;
    onClose: () => void;
  }
  export default function AgentMenu(props: AgentMenuProps): JSX.Element
  ```

**Background the implementer needs:** this reuses the `.pane-menu` / `.pane-menu-backdrop` / `.pane-menu-row` classes that `PaneMenu.tsx` and `ProjectMenu.tsx` already share (`App.css:1695-1800`) — do not write a new popover frame. Rows are `<button>`s, so Tab and Enter reach them through native focus order; **do not** autofocus anything, because this menu opens on hover and stealing focus would pull the caret out of a live terminal. `PaneMenu` has no arrow-key navigation and neither does this.

- [ ] **Step 1: Write the failing test**

Create `ui/src/components/AgentMenu.test.tsx`:

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import AgentMenu from "./AgentMenu";

describe("AgentMenu", () => {
  it("renders one row per installed agent and nothing else", () => {
    render(<AgentMenu agents={["claude", "shell"]} onPick={() => {}} onClose={() => {}} />);
    expect(screen.getByRole("menuitem", { name: /Claude Code/ })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: /Shell/ })).toBeInTheDocument();
    expect(screen.queryByRole("menuitem", { name: /Codex/ })).not.toBeInTheDocument();
  });

  it("passes the picked engine up", () => {
    const onPick = vi.fn();
    render(<AgentMenu agents={["claude", "codex", "shell"]} onPick={onPick} onClose={() => {}} />);
    fireEvent.click(screen.getByRole("menuitem", { name: /Codex/ }));
    expect(onPick).toHaveBeenCalledWith("codex");
  });

  it("closes on Escape", () => {
    const onClose = vi.fn();
    render(<AgentMenu agents={["shell"]} onPick={() => {}} onClose={onClose} />);
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onClose).toHaveBeenCalled();
  });

  it("does not steal focus from the terminal underneath", () => {
    render(<AgentMenu agents={["claude", "shell"]} onPick={() => {}} onClose={() => {}} />);
    expect(document.activeElement).toBe(document.body);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ui && npx vitest run src/components/AgentMenu.test.tsx`
Expected: FAIL — cannot resolve `./AgentMenu`.

- [ ] **Step 3: Write the component**

Create `ui/src/components/AgentMenu.tsx`:

```tsx
// The pane "+"'s hover menu (founder ask, 2026-07-26: "when we hover the
// plus, I want to choose which terminal we'll have: show the agents
// available and shell. User simply selects and the new terminal is
// created"). One click from resting on "+" to a running terminal — no
// confirm step, because the picking IS the confirmation.
//
// Frame, rows and backdrop are `.pane-menu`'s, shared with PaneMenu and
// ProjectMenu — this is the app's one utility-popover shape and it does not
// get a second implementation.
//
// ponytail: no arrow-key cursor. Rows are buttons, so Tab/Enter already
// work, and PaneMenu doesn't have one either. The keyboard story for
// choosing an agent lives in AgentPicker (⌘T), which is the keyboard door.
import { useEffect } from "react";
import type { Engine } from "../state/sessions";
import { AGENT_ICON, ENGINE_COLOR, ENGINE_HINT, ENGINE_LABEL } from "../theme";
import Icon from "./Icon";

interface AgentMenuProps {
  /** Only what can actually spawn — see `lib/useInstalledAgents.ts`. */
  agents: Engine[];
  onPick: (engine: Engine) => void;
  onClose: () => void;
}

export default function AgentMenu({ agents, onPick, onClose }: AgentMenuProps) {
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  return (
    <>
      <div className="pane-menu-backdrop" onMouseDown={onClose} />
      <div className="pane-menu agent-menu" role="menu" aria-label="New terminal">
        <div className="pane-menu-section-label">New terminal</div>
        <ul className="pane-menu-list">
          {agents.map((engine) => (
            <li key={engine}>
              <button
                type="button"
                role="menuitem"
                className="pane-menu-row"
                draggable={false}
                onMouseDown={(e) => e.stopPropagation()}
                onClick={() => onPick(engine)}
              >
                <span className="agent-menu-logo" style={{ color: ENGINE_COLOR[engine] }}>
                  <Icon name={AGENT_ICON[engine]} size={14} />
                </span>
                <span className="pane-menu-row-text">
                  <span className="pane-menu-row-label">{ENGINE_LABEL[engine]}</span>
                  <span className="pane-menu-row-hint">{ENGINE_HINT[engine]}</span>
                </span>
              </button>
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}
```

Append to `ui/src/App.css`, after the `.pane-menu-check` rule:

```css
/* The agent logo in a `+` hover-menu row — tinted inline with
   ENGINE_COLOR, same hue as that engine's dot everywhere else. */
.agent-menu-logo {
  display: flex;
  align-items: center;
  flex: 0 0 auto;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ui && npx vitest run src/components/AgentMenu.test.tsx`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add ui/src/components/AgentMenu.tsx ui/src/components/AgentMenu.test.tsx ui/src/App.css
git commit -m "feat(ui): add agent hover menu popover"
```

---

## Task 4: Wire the menu to the pane `+`

**Files:**
- Modify: `ui/src/components/PaneHeader.tsx:59-80` (props), `:205-214` (the `+` button)
- Modify: `ui/src/components/PaneHeader.test.tsx` (4 `<PaneHeader>` renders need the new prop)
- Modify: `ui/src/components/Workspace.tsx:129` (props), `:236-250` (the `PaneHeader` render), `:282`, `:311`, `:374`

**Interfaces:**
- Consumes: `AgentMenu` from Task 3.
- Produces:
  - `PaneHeaderProps.agents: Engine[]` (required).
  - `PaneHeaderProps.onSplit: (engine: Engine) => void` (was `() => void`).
  - `WorkspaceProps.agents: Engine[]` (required), threaded to every `PaneHeader`.
  - `WorkspaceProps.onNewTabInProject: (project: ProjectInfo, engine?: Engine) => void`.

**Background the implementer needs:** `PaneHeader.tsx:178` already wraps the 3-dot button in `<span className="pane-header-menu-anchor">`, which is the `position: relative` that `.pane-menu`'s `position: absolute` needs (`App.css:1690`). Reuse that same class for the `+`. `onMouseDown={stopForDrag}` on the button is load-bearing — the whole header is a react-mosaic drag handle, and without it grabbing `+` starts a pane rearrange.

`agents` is a **required** prop rather than one defaulting to `ENGINES`: a default would silently offer engines that are uninstalled — and, since `ENGINES` widened in commit `f9bf83c`, ones that cannot spawn at all. There are exactly 4 `<PaneHeader>` renders in `PaneHeader.test.tsx` to update.

⚠️ **`PaneHeader.tsx` and `Workspace.tsx` have uncommitted edits from a parallel session** (the pane header label now shows `ENGINE_LABEL[tab.engine]` in place of the project name). Rebase or coordinate before starting this task — do not `git checkout` over that work.

- [ ] **Step 1: Write the failing tests**

Append to `ui/src/components/PaneHeader.test.tsx` inside the existing `describe("PaneHeader", ...)`:

```tsx
  it("opens the agent menu on hovering +, without spawning anything", () => {
    const { onSplit } = setup({ agents: ["claude", "shell"] });
    fireEvent.mouseEnter(screen.getByLabelText("New terminal in bridgemind-api").parentElement!);
    expect(screen.getByRole("menuitem", { name: /Claude Code/ })).toBeInTheDocument();
    expect(onSplit).not.toHaveBeenCalled();
  });

  it("spawns the engine the user picked from the menu", () => {
    const { onSplit } = setup({ agents: ["claude", "codex", "shell"] });
    fireEvent.mouseEnter(screen.getByLabelText("New terminal in bridgemind-api").parentElement!);
    fireEvent.click(screen.getByRole("menuitem", { name: /Codex/ }));
    expect(onSplit).toHaveBeenCalledWith("codex");
  });

  it("closes the menu once an engine is picked", () => {
    setup({ agents: ["claude", "shell"] });
    const anchor = screen.getByLabelText("New terminal in bridgemind-api").parentElement!;
    fireEvent.mouseEnter(anchor);
    fireEvent.click(screen.getByRole("menuitem", { name: /Shell/ }));
    expect(screen.queryByRole("menuitem")).not.toBeInTheDocument();
  });

  it("opens the same menu on click, so the + is reachable without a pointer", () => {
    setup({ agents: ["claude", "shell"] });
    fireEvent.click(screen.getByLabelText("New terminal in bridgemind-api"));
    expect(screen.getByRole("menuitem", { name: /Claude Code/ })).toBeInTheDocument();
  });

  it("closes the menu when the pointer leaves the + entirely", () => {
    setup({ agents: ["claude", "shell"] });
    const anchor = screen.getByLabelText("New terminal in bridgemind-api").parentElement!;
    fireEvent.mouseEnter(anchor);
    fireEvent.mouseLeave(anchor);
    expect(screen.queryByRole("menuitem")).not.toBeInTheDocument();
  });
```

Update the `setup` helper's `render` call to pass the new prop, and add `agents` to its override type:

```tsx
function setup(overrides: Partial<Parameters<typeof PaneHeader>[0]> = {}) {
  const onFocus = vi.fn();
  const onClose = vi.fn();
  const onSplit = vi.fn();
  const onRename = vi.fn();
  render(
    <PaneHeader
      tab={tab()}
      projectLabel="bridgemind-api"
      isFocused={false}
      agents={["claude", "codex", "shell"]}
      onFocus={onFocus}
      onClose={onClose}
      onSplit={onSplit}
      onRename={onRename}
      {...overrides}
    />,
  );
  return { onFocus, onClose, onSplit, onRename };
}
```

Add `agents={["claude", "codex", "shell"]}` to the other 3 direct `<PaneHeader ...>` renders in the file.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ui && npx vitest run src/components/PaneHeader.test.tsx`
Expected: FAIL — no `menuitem` role in the document (the `+` still calls `onSplit` directly).

- [ ] **Step 3: Wire the menu into PaneHeader**

In `ui/src/components/PaneHeader.tsx`, add the import:

```tsx
import AgentMenu from "./AgentMenu";
```

Change the props (`PaneHeaderProps`):

```tsx
  /** Which agents this machine can spawn — `lib/useInstalledAgents.ts`.
   * Required, not defaulted to ENGINES: a default would quietly offer
   * uninstalled engines anywhere the wiring was missed. */
  agents: Engine[];
  onClose: () => void;
  /** The "+"'s hover menu picked this engine. Since 2026-07-26 the button
   * asks first (founder: "when we hover the plus, I want to choose which
   * terminal we'll have") instead of spawning the project default. */
  onSplit: (engine: Engine) => void;
```

Add `agents` to the destructured parameter list alongside `onSplit`, and add the state beside the existing `menuOpen`:

```tsx
const [splitMenuOpen, setSplitMenuOpen] = useState(false);
```

Replace the `+` button (`:205-214`) with:

```tsx
      <span
        className="pane-header-menu-anchor"
        onMouseEnter={() => setSplitMenuOpen(true)}
        onMouseLeave={() => setSplitMenuOpen(false)}
      >
        <button
          className={`pane-header-btn${splitMenuOpen ? " is-active" : ""}`}
          draggable={false}
          onMouseDown={stopForDrag}
          onClick={() => setSplitMenuOpen((open) => !open)}
          aria-label={`New terminal in ${projectLabel}`}
          aria-haspopup="menu"
          aria-expanded={splitMenuOpen}
          title="New terminal in this project"
        >
          +
        </button>
        {splitMenuOpen && (
          <AgentMenu
            agents={agents}
            onPick={(engine) => {
              setSplitMenuOpen(false);
              onSplit(engine);
            }}
            onClose={() => setSplitMenuOpen(false)}
          />
        )}
      </span>
```

- [ ] **Step 4: Thread `agents` through Workspace**

In `ui/src/components/Workspace.tsx`, add `agents: Engine[];` to both props interfaces (`:129` and `:282`), widen `onNewTabInProject` in both to `(project: ProjectInfo, engine?: Engine) => void`, add `agents` to both destructured parameter lists (`:161`, `:311`), pass `agents={agents}` down at `:374`, and change the `PaneHeader` render at `:236`:

```tsx
                    <PaneHeader
                      tab={tab}
                      projectLabel={projectLabel}
                      isFocused={tab.id === activeTabId}
                      agents={agents}
                      onFocus={() => onActivateTab(tab.id)}
                      onClose={() => onCloseTab(tab.id)}
                      onSplit={(engine) => {
                        const project = projects.find((p) => p.id === projectId);
                        if (project) onNewTabInProject(project, engine);
                      }}
```

Ensure `Engine` is in `Workspace.tsx`'s import from `../state/sessions`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ui && npx vitest run src/components/PaneHeader.test.tsx && npx tsc --noEmit`
Expected: PASS, and `tsc` reports errors only in `App.tsx` (which does not yet pass `agents` to `Workspace` — fixed in Task 6).

- [ ] **Step 6: Commit**

```bash
git add ui/src/components/PaneHeader.tsx ui/src/components/PaneHeader.test.tsx ui/src/components/Workspace.tsx
git commit -m "feat(ui): pane + opens an agent menu instead of spawning the default"
```

---

## Task 5: AgentPicker modal

**Files:**
- Create: `ui/src/components/AgentPicker.tsx`
- Test: `ui/src/components/AgentPicker.test.tsx`
- Delete: `ui/src/components/EnginePicker.tsx`
- Modify: `ui/src/App.newWorkspace.test.tsx:101`, `ui/src/App.import.test.tsx:76` (drop the stale `EnginePicker` mocks)
- Modify: `ui/src/App.css` (append after `.engine-picker-footer`, ~line 2030)

**Interfaces:**
- Consumes: `AGENT_ICON`, `ENGINE_COLOR`, `ENGINE_LABEL`, `ENGINE_HINT` from `../theme`; `ProjectInfo`, `Engine` from `../state/sessions`.
- Produces:
  ```ts
  interface AgentPickerProps {
    project: ProjectInfo;
    agents: Engine[];
    defaultEngine: Engine;
    onConfirm: (engine: Engine) => void;
    onCancel: () => void;
  }
  export default function AgentPicker(props: AgentPickerProps): JSX.Element
  ```

**Background the implementer needs:** `EnginePicker.tsx` is the same modal minus logos — read it before deleting it; its keyboard model is being kept, not reinvented. That model (focus on mount, Escape cancels, Enter confirms, digits `1..n` select **and** confirm in one keystroke, hover-selects / click-confirms) is shared with `NewChooserModal.tsx` and `state/keyboardShortcuts.ts`'s `chooserKeyAction`.

Two things change. Rows become a horizontal grid of buttons, so `ArrowLeft`/`ArrowRight` join `ArrowUp`/`ArrowDown`. And selection wraps over the **`agents` array** — do **not** use `cycleEngine` (`state/sessions.ts:411`), which wraps over all of `ENGINES` and would step the selection onto an agent this machine has not installed.

The grid holds **up to five** tiles, so `1`-`5` are all live digit keys and the frame is sized for two rows.

`defaultEngine` may not be in `agents` (a project configured for codex on a machine without it), so the initial selection falls back to `agents[0]`.

Reuse the `.engine-picker` frame (`App.css:1941`) and `.engine-picker-eyebrow` / `-footer`; only the grid is new.

- [ ] **Step 1: Write the failing test**

Create `ui/src/components/AgentPicker.test.tsx`:

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import AgentPicker from "./AgentPicker";
import type { ProjectInfo } from "../state/sessions";

const project: ProjectInfo = { id: "p1", label: "bridgemind-api", path: "/tmp/p1" };

function setup(overrides: Partial<Parameters<typeof AgentPicker>[0]> = {}) {
  const onConfirm = vi.fn();
  const onCancel = vi.fn();
  render(
    <AgentPicker
      project={project}
      agents={["claude", "codex", "shell"]}
      defaultEngine="claude"
      onConfirm={onConfirm}
      onCancel={onCancel}
      {...overrides}
    />,
  );
  return { onConfirm, onCancel, dialog: screen.getByRole("dialog") };
}

describe("AgentPicker", () => {
  it("preselects the default so Enter alone reproduces the old one-keystroke flow", () => {
    const { onConfirm, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "Enter" });
    expect(onConfirm).toHaveBeenCalledWith("claude");
  });

  it("moves right with ArrowRight", () => {
    const { onConfirm, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "ArrowRight" });
    fireEvent.keyDown(dialog, { key: "Enter" });
    expect(onConfirm).toHaveBeenCalledWith("codex");
  });

  it("wraps over the installed list, never onto an engine that cannot spawn", () => {
    const { onConfirm, dialog } = setup({ agents: ["claude", "shell"], defaultEngine: "claude" });
    fireEvent.keyDown(dialog, { key: "ArrowLeft" });
    fireEvent.keyDown(dialog, { key: "Enter" });
    expect(onConfirm).toHaveBeenCalledWith("shell");
  });

  it("confirms outright on a digit key", () => {
    const { onConfirm, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "2" });
    expect(onConfirm).toHaveBeenCalledWith("codex");
  });

  it("confirms on click", () => {
    const { onConfirm } = setup();
    fireEvent.click(screen.getByRole("button", { name: /Shell/ }));
    expect(onConfirm).toHaveBeenCalledWith("shell");
  });

  it("cancels on Escape without spawning", () => {
    const { onConfirm, onCancel, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(onCancel).toHaveBeenCalled();
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it("falls back to the first installed agent when the default is not installed", () => {
    const { onConfirm, dialog } = setup({ agents: ["codex", "shell"], defaultEngine: "claude" });
    fireEvent.keyDown(dialog, { key: "Enter" });
    expect(onConfirm).toHaveBeenCalledWith("codex");
  });

  it("only offers installed agents", () => {
    setup({ agents: ["claude", "shell"] });
    expect(screen.queryByRole("button", { name: /Codex/ })).not.toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ui && npx vitest run src/components/AgentPicker.test.tsx`
Expected: FAIL — cannot resolve `./AgentPicker`.

- [ ] **Step 3: Write the component**

Create `ui/src/components/AgentPicker.tsx`:

```tsx
// ⌘T's agent picker (founder ask, 2026-07-26: "if the user does cmd + t it
// should show a modal window with beautiful buttons for each agent with
// their respective logos, the default is pre selected. user can select
// using the keyboard and hit enter. or maybe just click with the mouse").
//
// Replaces `EnginePicker.tsx`, which had been dead since the
// instant-default-engine change and whose interaction model this keeps
// wholesale: focus on mount, Escape cancels, Enter confirms the selection,
// a digit selects AND confirms in one keystroke, hover selects / click
// confirms. That model is shared with NewChooserModal and
// `state/keyboardShortcuts.ts` — it is the app's chooser idiom, not this
// file's invention.
//
// What is new: rows became a grid of logo buttons, so ArrowLeft/Right join
// ArrowUp/Down. Selection wraps over `agents` — the INSTALLED list — and
// deliberately not via `cycleEngine`, which wraps over all of ENGINES and
// would land on an engine this machine cannot spawn.
//
// This is the one entry point that asks. The sidebar "+" and the map's
// "Open terminal here" still spawn the project default silently, per the
// 2026-07-24 "no blocking picker" ask that ⌘T is the deliberate exception to.
import { useEffect, useRef, useState } from "react";
import type { Engine, ProjectInfo } from "../state/sessions";
import { AGENT_ICON, ENGINE_COLOR, ENGINE_HINT, ENGINE_LABEL } from "../theme";
import Icon from "./Icon";

interface AgentPickerProps {
  project: ProjectInfo;
  /** Only what can actually spawn — see `lib/useInstalledAgents.ts`. */
  agents: Engine[];
  /** Resolved by `App.defaultEngineFor`. May not be installed on this
   * machine, which is why the initial selection falls back to `agents[0]`. */
  defaultEngine: Engine;
  onConfirm: (engine: Engine) => void;
  onCancel: () => void;
}

export default function AgentPicker({
  project,
  agents,
  defaultEngine,
  onConfirm,
  onCancel,
}: AgentPickerProps) {
  const [selected, setSelected] = useState<Engine>(() =>
    agents.includes(defaultEngine) ? defaultEngine : agents[0],
  );
  const panelRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  /** Wraps over the installed list, in either direction. */
  function step(direction: 1 | -1) {
    setSelected((cur) => {
      const idx = agents.indexOf(cur);
      return agents[(idx + direction + agents.length) % agents.length];
    });
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      onCancel();
      return;
    }
    if (e.key === "Enter") {
      e.preventDefault();
      onConfirm(selected);
      return;
    }
    if (e.key === "ArrowRight" || e.key === "ArrowDown" || e.key === "j") {
      e.preventDefault();
      step(1);
      return;
    }
    if (e.key === "ArrowLeft" || e.key === "ArrowUp" || e.key === "k") {
      e.preventDefault();
      step(-1);
      return;
    }
    const digit = Number(e.key);
    if (Number.isInteger(digit) && digit >= 1 && digit <= agents.length) {
      e.preventDefault();
      const engine = agents[digit - 1];
      setSelected(engine);
      onConfirm(engine);
    }
  }

  return (
    <div className="overlay-backdrop" onMouseDown={onCancel}>
      <div
        ref={panelRef}
        className="engine-picker agent-picker"
        role="dialog"
        aria-label={`New terminal in ${project.label}`}
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="engine-picker-eyebrow">NEW TERMINAL — {project.label.toUpperCase()}</div>
        <div className="agent-picker-grid">
          {agents.map((engine, i) => (
            <button
              key={engine}
              type="button"
              className={`agent-picker-btn${engine === selected ? " is-selected" : ""}`}
              onMouseEnter={() => setSelected(engine)}
              onClick={() => onConfirm(engine)}
              aria-pressed={engine === selected}
            >
              <span className="agent-picker-logo" style={{ color: ENGINE_COLOR[engine] }}>
                <Icon name={AGENT_ICON[engine]} size={34} strokeWidth={1.75} />
              </span>
              <span className="agent-picker-name">{ENGINE_LABEL[engine]}</span>
              <span className="agent-picker-hint">{ENGINE_HINT[engine]}</span>
              <span className="engine-picker-key">{i + 1}</span>
              {engine === defaultEngine && <span className="engine-picker-default">default</span>}
            </button>
          ))}
        </div>
        <div className="engine-picker-footer">
          <span>&#8629; confirm</span>
          <span>&larr;&rarr; choose</span>
          <span>esc cancel</span>
        </div>
      </div>
    </div>
  );
}
```

Append to `ui/src/App.css`, after `.engine-picker-footer`:

```css
/* ⌘T's agent grid — the "beautiful buttons with their respective logos"
   half of the 2026-07-26 picker ask. Wider than the shared 420px chooser
   frame so three tiles per row breathe; `auto-fit` reflows to two rows at
   four or five agents, and centres one or two on a sparse machine. */
.agent-picker {
  width: 560px;
}

.agent-picker-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
  gap: 8px;
}

.agent-picker-btn {
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  padding: 18px 12px 14px;
  background: transparent;
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  color: var(--ink);
  cursor: pointer;
  text-align: center;
}

.agent-picker-btn.is-selected {
  background: var(--panel-raised);
  border-color: var(--signal-dim);
  outline: 1px solid var(--signal-dim);
}

.agent-picker-logo {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 34px;
}

.agent-picker-name {
  font-family: var(--mono);
  font-size: 13px;
  font-weight: 600;
}

.agent-picker-hint {
  font-style: italic;
  font-size: 10px;
  line-height: 1.35;
  color: var(--ink-dim);
}

.agent-picker-btn .engine-picker-key {
  position: absolute;
  top: 6px;
  left: 6px;
}

.agent-picker-btn .engine-picker-default {
  position: absolute;
  top: 6px;
  right: 6px;
}
```

- [ ] **Step 4: Delete the dead picker and its stale mocks**

```bash
git rm ui/src/components/EnginePicker.tsx
```

Remove this line from both `ui/src/App.newWorkspace.test.tsx:101` and `ui/src/App.import.test.tsx:76`:

```tsx
vi.mock("./components/EnginePicker", () => ({ default: () => null }));
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ui && npx vitest run src/components/AgentPicker.test.tsx src/App.newWorkspace.test.tsx src/App.import.test.tsx`
Expected: PASS (8 new + both existing App suites still green)

- [ ] **Step 6: Commit**

```bash
git add ui/src/components/AgentPicker.tsx ui/src/components/AgentPicker.test.tsx ui/src/App.css ui/src/App.newWorkspace.test.tsx ui/src/App.import.test.tsx
git rm --cached ui/src/components/EnginePicker.tsx 2>/dev/null || true
git commit -m "feat(ui): add cmd+T agent picker modal, replacing dead EnginePicker"
```

---

## Task 6: App wiring

**Files:**
- Modify: `ui/src/App.tsx:633-688` (`requestNewTab`), `:1160-1194` (the ⌘T handler), the single `<Workspace>` render (`:1324`), and the render tree for the new modal
- Test: `ui/src/App.agentPicker.test.tsx` (create)

**Interfaces:**
- Consumes: `useInstalledAgents` (Task 2), `AgentPicker` (Task 5), `agents`/`onNewTabInProject` props on `Workspace` (Task 4).
- Produces: `requestNewTab(project: ProjectInfo, engine?: Engine): Promise<void>` — when `engine` is given, `defaultEngineFor` is skipped entirely.

**Background the implementer needs:** `requestNewTab` (`App.tsx:633`) currently resolves the engine itself at `:661`. Everything else in it — `setSelectedProjectId`, `reopenWorkspace`, the `MAX_PANES` guard, session-group joining, `nextSessionName`, the error banner — is unchanged and must stay exactly where it is. Only the engine source moves.

⌘T lives in the `onKeyDown` handler at `:1162`. It currently calls `requestNewTab(selectedProject)`; it now opens the picker instead. The picker needs a resolved default, and `defaultEngineFor` is async, so the handler stores `{ project, defaultEngine }` once resolved.

- [ ] **Step 1: Write the failing test**

Create `ui/src/App.agentPicker.test.tsx`. Copy the mock preamble from `ui/src/App.requestNewTab.test.tsx:29-80` verbatim (the `tauriMocks` hoist, the `vi.mock("./lib/tauri", ...)`, the `@tauri-apps/api/event` mock, and the `Sidebar`/`Workspace` stubs), then add `agentCheckInstalled` to both the hoist and the `./lib/tauri` mock:

```tsx
const tauriMocks = vi.hoisted(() => ({
  agentCheckInstalledMock: vi.fn(),
  getBriefingMock: vi.fn(),
  // ...the rest, copied from App.requestNewTab.test.tsx
}));

vi.mock("./lib/tauri", () => ({
  FILE_TREE_VISIBLE_SETTING_KEY: "file_tree_visible",
  agentCheckInstalled: tauriMocks.agentCheckInstalledMock,
  // ...the rest, copied from App.requestNewTab.test.tsx
}));
```

Then the suite:

```tsx
describe("cmd+T agent picker", () => {
  beforeEach(() => {
    // Same default wiring App.requestNewTab.test.tsx sets up in its own
    // beforeEach — one project, no stored engine overrides, sessions that
    // create successfully. Copy that block.
    // Includes "shell" explicitly: since commit 1b34dee the backend reports
    // built-ins itself, and the hook no longer re-adds shell on the frontend.
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "codex", "shell"]);
  });

  it("opens the picker instead of spawning, preselecting the resolved default", async () => {
    render(<App />);
    await screen.findByText("new-tab-p1");
    fireEvent.keyDown(window, { key: "t", metaKey: true });
    expect(await screen.findByRole("dialog", { name: /New terminal in/ })).toBeInTheDocument();
    expect(tauriMocks.sessionCreateMock).not.toHaveBeenCalled();
  });

  it("spawns the engine the user confirmed, not the default", async () => {
    render(<App />);
    await screen.findByText("new-tab-p1");
    fireEvent.keyDown(window, { key: "t", metaKey: true });
    const dialog = await screen.findByRole("dialog", { name: /New terminal in/ });
    fireEvent.click(screen.getByRole("button", { name: /Shell/ }));
    await waitFor(() =>
      expect(tauriMocks.sessionCreateMock).toHaveBeenCalledWith("p1", "shell", expect.any(String), undefined),
    );
    expect(dialog).not.toBeInTheDocument();
  });

  it("spawns nothing when the picker is cancelled", async () => {
    render(<App />);
    await screen.findByText("new-tab-p1");
    fireEvent.keyDown(window, { key: "t", metaKey: true });
    const dialog = await screen.findByRole("dialog", { name: /New terminal in/ });
    fireEvent.keyDown(dialog, { key: "Escape" });
    await waitFor(() => expect(dialog).not.toBeInTheDocument());
    expect(tauriMocks.sessionCreateMock).not.toHaveBeenCalled();
  });

  it("leaves the sidebar + on its silent default-spawn", async () => {
    render(<App />);
    fireEvent.click(await screen.findByText("new-tab-p1"));
    await waitFor(() => expect(tauriMocks.sessionCreateMock).toHaveBeenCalled());
    expect(screen.queryByRole("dialog", { name: /New terminal in/ })).not.toBeInTheDocument();
  });

  it("only offers agents this machine has installed", async () => {
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);
    render(<App />);
    await screen.findByText("new-tab-p1");
    fireEvent.keyDown(window, { key: "t", metaKey: true });
    await screen.findByRole("dialog", { name: /New terminal in/ });
    await waitFor(() => expect(screen.queryByRole("button", { name: /Codex/ })).not.toBeInTheDocument());
    expect(screen.getByRole("button", { name: /Claude Code/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Shell/ })).toBeInTheDocument();
  });

  it("offers copilot and antigravity too, now that both can spawn", async () => {
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["shell", "copilot", "antigravity"]);
    render(<App />);
    await screen.findByText("new-tab-p1");
    fireEvent.keyDown(window, { key: "t", metaKey: true });
    await screen.findByRole("dialog", { name: /New terminal in/ });
    await waitFor(() => expect(screen.getByRole("button", { name: /Copilot/ })).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: /AntiGravity/ }));
    await waitFor(() =>
      expect(tauriMocks.sessionCreateMock).toHaveBeenCalledWith("p1", "antigravity", expect.any(String), undefined),
    );
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ui && npx vitest run src/App.agentPicker.test.tsx`
Expected: FAIL — ⌘T spawns a session directly; no dialog appears.

- [ ] **Step 3: Add the optional engine to `requestNewTab`**

In `ui/src/App.tsx`, change the signature at `:633` and the resolution at `:661`:

```tsx
  const requestNewTab = useCallback(
    async (project: ProjectInfo, engine?: Engine) => {
```

```tsx
      // Given by ⌘T's picker; resolved from settings for every other entry
      // point, which still spawns the project default without asking.
      const resolved = engine ?? (await defaultEngineFor(project.id));
```

Then replace the two later uses of `engine` in that function body with `resolved`:

```tsx
        const tab = await createSessionTab(project, resolved, group, groupLabel);
```

```tsx
        setErrorBanner(`Couldn't start ${resolved} in ${project.label}: ${err}`);
```

- [ ] **Step 4: Add the hook, the picker state, and the ⌘T branch**

Add the imports:

```tsx
import AgentPicker from "./components/AgentPicker";
import { useInstalledAgents } from "./lib/useInstalledAgents";
```

Add near the other `useState` declarations:

```tsx
  const installedAgents = useInstalledAgents();
  // ⌘T's picker: null when closed. Carries its own resolved default so the
  // async `defaultEngineFor` settles before the modal ever renders — the
  // picker is a pure component and never awaits anything itself.
  const [agentPicker, setAgentPicker] = useState<{ project: ProjectInfo; defaultEngine: Engine } | null>(null);
```

Replace the ⌘T branch at `:1162`:

```tsx
      if (e.key.toLowerCase() === "t") {
        e.preventDefault();
        // Since 2026-07-26 this asks which agent instead of spawning the
        // default outright (founder: "if the user does cmd + t it should
        // show a modal window with beautiful buttons for each agent").
        // The deliberate exception to the 2026-07-24 no-blocking-picker
        // ask — the sidebar "+" and the map still spawn silently.
        if (selectedProject) {
          const project = selectedProject;
          void defaultEngineFor(project.id).then((defaultEngine) =>
            setAgentPicker({ project, defaultEngine }),
          );
        }
      } else if (e.key.toLowerCase() === "k") {
```

Add `defaultEngineFor` to that `useEffect`'s dependency array at `:1194`.

Render the picker in the return tree, immediately after the `{errorBanner && ...}` block:

```tsx
      {agentPicker && (
        <AgentPicker
          project={agentPicker.project}
          agents={installedAgents}
          defaultEngine={agentPicker.defaultEngine}
          onConfirm={(engine) => {
            setAgentPicker(null);
            void requestNewTab(agentPicker.project, engine);
          }}
          onCancel={() => setAgentPicker(null)}
        />
      )}
```

Pass `agents={installedAgents}` to the `<Workspace>` render — there is exactly one, at `App.tsx:1324`. (The nearby `onNewTabInProject`/`onOpenTerminal` props at `:1243`, `:1286`, `:1315` and `:1359` belong to `Sidebar`, `EmptyWorkspace` and `BrainMap`; those keep the silent default-spawn and need no change.)

- [ ] **Step 5: Run the full suite and the type check**

Run: `cd ui && npm test && npx tsc --noEmit`
Expected: PASS, zero type errors.

- [ ] **Step 6: Commit**

```bash
git add ui/src/App.tsx ui/src/App.agentPicker.test.tsx
git commit -m "feat(ui): cmd+T opens the agent picker before spawning"
```

---

## Task 7: Verify in the running app

**Files:** none — this task only runs things.

- [ ] **Step 1: Type-check and test the whole UI**

Run: `cd ui && npx tsc --noEmit && npm test`
Expected: zero type errors, all suites pass.

- [ ] **Step 2: Build the app**

Run: `cd src-tauri && cargo build`
Expected: compiles clean. (No Rust changed in this plan; this catches nothing but costs a minute and proves it.)

- [ ] **Step 3: Launch and check the two flows by hand**

Run: `cd src-tauri && cargo tauri dev`

Confirm, in order:
1. Resting the pointer on a pane's `+` opens the menu without spawning anything.
2. Clicking an agent row spawns that engine — its pane header shows that engine's colour and label.
3. ⌘T opens the modal with the default tile outlined and badged `default`.
4. `→` / `←` move the outline and wrap; Enter spawns the outlined agent.
5. Pressing `2` spawns the second agent in one keystroke.
6. Escape closes the modal with nothing spawned.
7. The sidebar's per-workspace `+` still spawns immediately, no modal.

- [ ] **Step 4: Commit anything the manual pass turned up**

If steps 1-7 all pass, there is nothing to commit — say so rather than inventing a change.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| 1. `useInstalledAgents` — trusts the backend, `isEngine` drift seam, error fallback | Task 2 |
| 2. Logos in `Icon.tsx` + `AGENT_ICON` in `theme.ts` | Task 1 |
| 3. `AgentMenu` popover, `.pane-menu` reuse, native focus order, `onSplit(engine)` | Tasks 3, 4 |
| 4. `AgentPicker` modal, grid, wrap over installed, `defaultEngineFor` preselect | Task 5 |
| 5. `requestNewTab(project, engine?)`, ⌘T opens the picker | Task 6 |
| Testing table (all 11 rows) | Tasks 2, 5, 4, 6 |
| Out of scope: copilot/antigravity, install-on-select, sidebar `+` | Not implemented; Task 6 test asserts the sidebar `+` is unchanged |

**Placeholder scan:** none — every code step carries the code.

**Type consistency:** `installedEngines`/`useInstalledAgents` (Task 2) match their Task 6 usage. `AgentMenuProps` (Task 3) matches the Task 4 call site. `AgentPickerProps` (Task 5) matches the Task 6 render. `onSplit: (engine: Engine) => void` is consistent across Tasks 3, 4. `AGENT_ICON` (Task 1) is consumed identically in Tasks 3 and 5.

# Terminal agent picker — hover menu + ⌘T modal

> 2026-07-26 · Bruno

## Problem

Two ways to open a terminal exist today, and neither asks what should run in it:

- **⌘T** (`App.tsx:1162`) → `requestNewTab(project)` → resolves the default engine and spawns it.
- **The pane header `+`** (`PaneHeader.tsx:205` → `Workspace.tsx:242`) → the same `requestNewTab`.

Founder ask, verbatim:

> To add a new terminal we have two options: either we combine the cmd + t or we click on the plus of each terminal window. I want to make a change when we hover the plus, I want to choose which terminal we'll have: show the agents available and shell. User simply selects and the new terminal is created. but if the user does cmd + t it should show a modal window with beautiful buttons for each agent with their respective logos, the default is pre selected. user can select using the keyboard and hit enter. or maybe just click with the mouse.

So: the `+` grows a hover menu, and ⌘T grows a modal.

### This reverses a prior decision, deliberately and partially

`requestNewTab`'s doc comment (App.tsx:590-599) records the 2026-07-24 founder ask
*"When a new terminal is created, it should automatically open the default one"* — no blocking
picker. That decision holds for every entry point **except ⌘T**. The sidebar's per-project `+`
and the map's "Open terminal here" keep spawning the default silently. The pane `+` gains a
menu but is still one gesture to a running terminal.

## Constraints discovered in the code

Three facts shaped the design and must not be re-litigated during implementation:

1. **`session_create` only supports three engines.** `build_engine_argv`
   (`src-tauri/src/sessions.rs:2117`) matches `"shell" | "codex" | "claude"` and its fallback arm
   returns `unsupported engine: {other:?}`. `copilot` and `antigravity` are in
   `SUPPORTED_AGENTS` (`src-tauri/src/commands/agents.rs:8`) and installable, but spawning
   either **errors**. Offering them in a picker would ship a button that crashes.

2. **`agents_check_installed` cannot detect `shell`.** It runs `which::which(agent)` over all
   five names (`agents.rs:21`); no binary is named `shell`, so shell always reports as *not
   installed* — while being the one engine that can never fail to spawn (`build_engine_argv`
   reads `$SHELL`, defaulting to `/bin/zsh`).

3. **`EnginePicker.tsx` is dead code.** 91 lines, rendered nowhere; only test mocks
   (`App.newWorkspace.test.tsx:101`, `App.import.test.tsx:76`) and comments still name it. It is
   already the modal this spec calls for, minus logos and a grid layout.

## Design

### 1. Which agents to offer — `ui/src/lib/useInstalledAgents.ts` (new)

```ts
export function useInstalledAgents(): Engine[]
```

Calls `agentCheckInstalled()` once on mount and maps the result to spawnable engines:

```
ENGINES.filter(e => e === "shell" || names.includes(e))
```

- `shell` is unconditional — constraint 2.
- Intersecting with `ENGINES` (not `AVAILABLE_AGENTS`) drops `copilot`/`antigravity` — constraint 1.
- On rejection: keep all of `ENGINES` and `console.error`. A detection failure must not leave
  the user with an empty menu and no way to open a terminal.

Called once in `App.tsx`; the resulting `Engine[]` is passed to `Workspace` (→ `PaneHeader`) and
to the ⌘T modal. `state/agents.ts`'s reducer stays untouched and unwired — it belongs to the
separate agent-installation design and this spec does not adopt it.

### 2. Logos — `ui/src/components/Icon.tsx`

Three new entries in the existing icon map, alongside the current `plus`/etc.:

| Icon name | Mark | Source |
|---|---|---|
| `agent-claude` | Anthropic burst | simple-icons `claude.svg` |
| `agent-codex` | OpenAI knot | simple-icons `openai.svg` |
| `agent-shell` | terminal `>_` | simple-icons `gnubash.svg` |

Paths are copied inline (the app is a Tauri desktop build — no CDN fetch at runtime).
simple-icons is CC0, which avoids shipping copied brand SVGs under unclear terms. Each mark is
`fill="currentColor"`; callers tint with `ENGINE_COLOR[engine]` (`theme.ts:33`) so a pane header's
engine dot and its picker button read as the same colour.

A `AGENT_ICON: Record<Engine, IconName>` map lives in `theme.ts` next to `ENGINE_LABEL`/
`ENGINE_COLOR`/`ENGINE_HINT`, so all four per-engine lookups stay in one file.

### 3. Hover menu on the pane `+` — `ui/src/components/AgentMenu.tsx` (new)

A popover reusing the existing `.pane-menu` CSS (`App.css:1701`), same shape as `PaneMenu` and
`ProjectMenu`. One row per installed engine: tinted logo, `ENGINE_LABEL`, `ENGINE_HINT`.

Wiring in `PaneHeader.tsx`:

- `onMouseEnter` on the `+` opens the menu; `onClick` opens it too. One behaviour, so keyboard
  and touch reach it — hover is an accelerator, not the only door.
- Closes on: pointer leaving the `+`-plus-menu region, `Escape`, outside mousedown, or a pick.
- Rows are `<button>`s, so Tab/Enter already reach them via native focus order. No custom
  arrow-key handling — `PaneMenu` has none either (its `.is-selected` marks the *current*
  engine/theme, not a keyboard cursor), and the modal is where the keyboard story lives.

Prop change, threaded through `Workspace.tsx:242`:

```diff
-onSplit: () => void
+onSplit: (engine: Engine) => void
```

### 4. ⌘T modal — `ui/src/components/AgentPicker.tsx`

`EnginePicker.tsx` renamed and reworked; the file is deleted and its stale test mocks removed.

Kept as-is from `EnginePicker`: focus-on-mount, `Escape` cancels, `Enter` confirms the
selection, digit keys `1..n` select **and** confirm in one keystroke, hover-selects/click-confirms.
This is the interaction model `NewChooserModal` and `keyboardShortcuts.ts`'s `chooserKeyAction`
already share — it does not get reinvented here.

Changed: rows become a horizontal **grid of buttons**, each a large tinted logo above its
`ENGINE_LABEL`, so `ArrowLeft`/`ArrowRight` join `ArrowUp`/`ArrowDown` in moving the selection.
Both wrap over the *installed* list — a two-line index step inside the component, **not**
`cycleEngine` (`sessions.ts:411`), which is hardcoded to wrap over all of `ENGINES` and would
land on an uninstalled engine. Frame reuses `.engine-picker` CSS (`App.css:1941`); the grid gets
a new `.agent-picker-grid`.

Preselection: `defaultEngineFor(project.id)` (`App.tsx:616`) — the same
per-project-override → global → claude chain every other entry point resolves. If that engine
is not in the installed list, fall back to the list's first entry.

### 5. `requestNewTab` gains an optional engine

```diff
-const requestNewTab = useCallback(async (project: ProjectInfo) => {
+const requestNewTab = useCallback(async (project: ProjectInfo, engine?: Engine) => {
...
-  const engine = await defaultEngineFor(project.id);
+  const resolved = engine ?? await defaultEngineFor(project.id);
```

Every existing caller passes no engine and is unchanged in behaviour. The MAX_PANES guard, the
session-group joining, and the error banner all stay exactly where they are.

⌘T's handler stops calling `requestNewTab` directly and instead sets `pickerProject`, which
renders `AgentPicker`; its `onConfirm(engine)` calls `requestNewTab(project, engine)`.

## Testing

| Unit | Check |
|---|---|
| `useInstalledAgents` | `shell` present even when `agentCheckInstalled` omits it |
| | `copilot`/`antigravity` filtered out when reported installed |
| | rejection falls back to all of `ENGINES` |
| `AgentPicker` | Enter alone confirms the resolved default |
| | ArrowRight then Enter confirms the neighbour |
| | Escape cancels without spawning |
| | default not installed → first installed entry preselected |
| `PaneHeader` | hovering `+` opens the menu |
| | clicking a row calls `onSplit` with that engine |
| `App` | ⌘T opens the picker instead of spawning; confirming spawns the chosen engine |
| | sidebar `+` still spawns the default with no picker |

## Explicitly out of scope

- **Spawning `copilot`/`antigravity`.** Needs a new `build_engine_argv` arm plus widening
  `Engine` across `theme.ts`, `PaneMenu`, `cycleEngine`, `resolveDefaultEngine` and their tests.
  Add when those two agents are actually wanted live.
- **Install-on-select.** `PaneInstallOverlay.tsx` and `agents_install` exist but are unwired;
  the picker only ever offers what is already installed.
- **The sidebar's per-project `+`** (`Sidebar.tsx:477`) and the map's "Open terminal here" keep
  today's silent default-spawn.

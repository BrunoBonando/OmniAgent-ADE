# OmniAgent ADE — Design Analysis

Source: claude.ai/design project `74a2e92e-516e-4410-abdd-cd74696bea32` ("Redesigned OmniAgent interface").
Saved here as `OmniAgent ADE.dc.html` (+ `support.js` runtime and the assets it references, mirrored at their original relative paths so the file renders standalone).

The file is a single interactive design-doc: one 1440×900 window mock with a state rail on top that switches between **9 views** (see the `VIEWS` array + `DCLogic` component at the bottom of the HTML, lines ~910–963). All styling is inline; `sc-if`/`sc-for` are the design runtime's conditionals/loops, `style-hover` is its hover syntax.

---

## 1. The 9 views (state machine)

| id | What it shows | Entry point in the mock |
|----|---------------|------------------------|
| `workspace` | Default shell: title bar + sidebar + 2×2 pane grid + status bar | default state / `closeAll` |
| `focus` | One terminal zoomed over a blurred backdrop | pane-header focus button (⌃⌘F) |
| `review` | 382px git-review column docked right of the grid | diff pill in title bar (⇧⌘G) |
| `notifications` | 392px popover anchored top-right | bell in title bar |
| `workspaceMenu` | 264px dropdown under the sidebar switcher | workspace switcher button |
| `newTerminal` | ⌘T modal — name + engine, joins open session | "New terminal" sidebar row |
| `newSession` | ⌘N modal — prompt-as-name, layout, engines, folder | "+" next to SESSIONS |
| `newWorkspace` | Modal — folder, ingest stats, toggles | workspace menu footer |
| `firstRun` | Onboarding hero ("Where do your projects live?") | state rail only |

Only one overlay is open at a time; every scrim click routes back to `workspace`. Toggles (`toggleReview`, `toggleNotif`) flip between their view and `workspace`.

---

## 2. Layout skeleton (workspace view)

```
┌────────────────────────────────────────── 1440×900 ─┐
│ Title bar 30px  (z-40, blur)                        │
├──────────┬──────────────────────────────┬───────────┤
│ Sidebar  │ Pane grid (2×2, 7px gap/pad) │ Git review│
│ 238px    │ flex:1                       │ 382px     │
│          │                              │ (sc-if)   │
├──────────┴──────────────────────────────┴───────────┤
│ Status bar 24px                                     │
└─────────────────────────────────────────────────────┘
Overlays: focus (z-65, inset 30px/24px), notif popover (z-60),
workspace menu (z-60), modals (z-70), scrims (z-50).
```

### Title bar (line ~34)
- Traffic lights drawn manually (12px circles), divider, sidebar-toggle icon button.
- **Centered identity chip** (absolute, pointer-events:none): logo 13px + `OmniAgent / session restore · 4 terminals`. Comment says the native AppKit title is set to `""` at runtime so nothing doubles up. First-run shows just "OmniAgent".
- **Top-right cluster** (shell only): diff pill `+1284 −312 14f` (opens review; bg highlights while open), bell with red badge `3` (opens notifications). Nothing shown at first run.

### Sidebar (line ~111)
- **Workspace switcher** button: logo 20px, name + monospace path, "WORKSPACE" microlabel, up/down chevrons → workspace menu.
- **SESSIONS** header with count + "+" button (→ new session).
- **Session rows**: selected row has 2.5px accent bar on the left, indigo tint bg, rotated chevron (expanded), name, a **cluster of 5px status dots** (one per terminal, colored by state — blue pulsing/amber/green/gray), layout badge `2×2`. Collapsed rows show chevron right + dots + count.
- **Terminal rows** (indented 24px, under the expanded session): engine logo 11px, task name, and a 12px **status mark** — the OmniAgent logo used as a CSS mask (`ui/src/assets/omniagent-mark-mask.png`), tinted by state color with a matching `drop-shadow` glow, pulsing while busy.
- **"New terminal" row** with ⌘T hint, indigo text.
- **FILES section**: `FILES` header + `14 changed` (green), a fake filter input, then a Finder-like tree — one indent unit per level, folder rows show a green/amber **changed-count badge**, file rows show git letter `M` (amber) / `A` (green). Selected file row has subtle bg.
- **Account row**: gradient BB avatar, name, green sub-line `Brain indexed · 8m ago`, settings gear.

### Pane grid — the 4 pane states (lines ~291–426)
Each pane: header 30px / scrolling terminal body / footer. The four panes demo the four states:

1. **Working (focused)** — the signature element: an animated "comet" border. Structure: outer wrapper `position:relative` → an `inset:-1px` clipped layer containing a 180%-size square filled with a **conic-gradient** (transparent → accent tail → bright #a7afff head → transparent) spinning via `om-spin 3s linear infinite` → the actual pane surface layered on top with `inset:0`. Body shows Claude Code transcript: `● Read/Edit/Bash` lines, italic indigo "thinking" lines (✻), red/green diff blocks with 2px left borders, blinking block cursor. Footer: `❯ Prompt Claude Code and press Enter… ⌘⇵ run · ⌘K palette`.
2. **Awaiting approval** — static amber ring (`box-shadow: 0 0 0 1px rgba(240,180,70,.35)`), amber-tinted **approval banner** as footer: "Needs approval — write 3 files outside `src/stripe/`?" + solid amber `Approve` + ghost `Deny`.
3. **Done** — green mark (no pulse), normal footer with a green `memory note saved` chip.
4. **Idle shell** — gray mark, plain zsh transcript, dim prompt, no engine pulse.

**Pane header anatomy** (consistent across states): status mark 15px (masked logo, state-colored, glow, pulse when busy) · task title · **engine badge** (brand-tinted chip: Claude Code orange `#f08a5d` on `rgba(240,138,93,.14)`, Codex cyan `#a2e7f9`, AntiGravity blue `#6ea8ff`, Shell gray) · **git branch chip** (branch icon + `main` / `db/schema` / `feat/voice-latency`) · actions `⋮`, focus (hover tints indigo), close (hover tints red).

### Git review column (line ~430)
- Header: repo path, branch chip, close ×; then `Uncommitted · 14 files · +1284 −312` + solid indigo **Commit** button.
- Filter tabs: `All 14` / `By terminal` / `Staged 3`.
- Files **grouped by generating terminal**: microlabel headers `CLAUDE CODE · token rotation`, `CODEX · webhook retries`, `ANTIGRAVITY · users.last_seen_at`.
- One card expanded: indigo-tinted border, chevron down, path (rtl-ellipsized), `+21 −4` chip on black, revert + open-in-editor icon buttons, and an **inline diff** (line numbers, red/green tinted rows) on `#08080a`.
- Collapsed cards: chevron right, path, +/− chip, git letter.
- Footer: "Memory note will be written on commit." + `⇧⌘G`.

### Status bar (line ~524)
Shell: `● 4 sessions live` · `brain 41,208 nodes · queue 0` · spacer · `CPU 34% · RAM 6.1G` · `● MCP wired` · `⌘K`. First run: `Nothing indexed yet` · `Choose a folder to start ingesting`.

---

## 3. Overlays

### Focused terminal (`focus`, line ~541)
Scrim covers between title bar and status bar (`top:30px; bottom:24px`) with `blur(16px) saturate(70%)`. Centered 1080×≤720 pane, same comet border, larger type (13px mono, 34px header). Header adds context line "session restore · terminal 1 of 4" and an **"Exit focus · esc"** button. Footer hints: `⌃⌘F focus · ⌘⇧] next terminal`. Click-outside closes; inner click stopped.

### Notifications popover (`notifications`, line ~591)
392px, top:36 right:8, heavy blur. Header "Notifications · 3 new · Clear all · ×". Tabs `All 3` / `This workspace 2` / `Needs you 1`. Sections:
- **NEEDS YOU** — amber-tinted row with 2px amber left border: pulsing amber mark, task + engine tag (`CODEX`), age, description ("Wants to write 3 files outside src/stripe/ · session restore"), inline **Approve** (solid amber) + **Open pane** (ghost) buttons.
- **EARLIER TODAY** — done item (green mark, "Done · migration ready, 2 files +16 −1"), failed item (red mark pulsing fast 1.1s, "Failed · stream.service.spec.ts 3 failing · Voice workspace"), per-row dismiss ×.

### Workspace dropdown (`workspaceMenu`, line ~660)
264px under the switcher. WORKSPACES header + count; active row indigo-tinted with checkmark; inactive rows desaturated logos, session counts ("1 session", "no sessions"); divider; **New workspace** row with dashed-border plus tile.

### New terminal modal (`newTerminal`, ⌘T, line ~705)
452px. Header: mark + "New terminal · in session restore · 4 of 8 used · ⌘T". NAME field pre-filled "Terminal #5" (focused style: indigo border + 3px glow ring, blinking caret) with helper "rename any time by double-clicking the terminal header". ENGINE list: Claude Code (selected, "Pre-briefed from the brain, MCP-wired", ⌘1), Codex ("Stock spawn, no ADE wiring", ⌘2), AntiGravity ("Schema and migration agent", ⌘3), Shell ("Your default $SHELL", ⌘0), **GitHub Copilot at 50% opacity — "Not installed — install CLI"**. Footer: "Opens in the session's next free slot." + Cancel / **Open terminal ⏎**.

### New session modal (`newSession`, ⌘N, line ~762)
560px. Field label is **"WHAT ARE YOU DOING?"** — the answer "Becomes the session name and the first prompt. Leave empty for a bare terminal." TERMINAL LAYOUT picker: `1 · 1×2 · 2×2 (selected) · 2×3 · 2×4` as mini-grid thumbnails, "max 8 terminals per session". ENGINE PER TERMINAL: 2×2 grid of numbered dropdown rows (1 Claude Code brand-tinted, 2 Codex, 3 AntiGravity, 4 Shell). WORKING FOLDER row with Change link. Footer: "● 4 terminals boot briefed on 41,208 brain nodes" + Cancel / **Start session ⏎**.

### New workspace modal (`newWorkspace`, line ~860)
520px. PROJECT FOLDER path + Browse…. **FOUND IN THIS FOLDER** stat strip: `1,842 files to walk · TS · Rust languages · git ✓ 4 branches`. Two toggles: "Ingest into the brain now" (on) and "Review memory notes before commit" (off, "Off: session notes auto-commit to your repo"). Footer: "Scoped access — only this folder is readable." + Cancel / **Add workspace ⏎**.

### First run (`firstRun`, line ~86)
Radial-gradient backdrop (`#151520` glow at top). 64px logo, H1 "Where do your projects live?", copy "Point OmniAgent at one folder. Everything inside gets walked, parsed and linked into your local brain — nothing leaves this machine.", solid **Choose folder…** + ghost **Skip for now**, then a 3-column value strip: Local-first / Stock engines / No setup. Title bar shows plain "OmniAgent", no right cluster; status bar swaps to onboarding copy.

---

## 4. Design tokens

### Color
| Role | Value |
|------|-------|
| Canvas / app / pane bg | `#08080a` / `#0a0a0c` / `#0c0c0f` |
| Titlebar / sidebar / review bg | `rgba(24,24,27,.86)` / `rgba(23,23,26,.94)` / `rgba(20,20,23,.97)` |
| Popover / modal bg | `rgba(30,30,34,.97)` / `rgba(32,32,36,.98)` + heavy backdrop blur |
| Accent (brand indigo) | `#8b95ff`, bright `#a7afff`, button `#5f6bff` (hover `#7079ff`), selected tint `rgba(139,149,255,.14–.18)` |
| Status: working | `#5f9dff` (blue, pulses) |
| Status: needs-you | `#f0b446` (amber) |
| Status: done | `#4ec97a` (green) |
| Status: failed | `#f2555a` (red, fast pulse) |
| Status: idle | `#6b6b75` / `#55555e` |
| Engine brands | Claude `#d97757` icon / `#f08a5d` text; Codex `#a2e7f9`; AntiGravity `#6ea8ff`; Shell `#9a9ca6` |
| Text ramp (bright→faint) | `#f0f0f4 → #e8e8ee → #d8d8de → #c6c6d0 → #9a9aa4 → #8b8b95 → #6d6d78 → #5c5c66 → #4a4a53 → #41414a` |
| Hairlines | `.5px solid rgba(255,255,255,.06–.14)` |

Diff colors: added `#4ec97a` text on `rgba(78,201,122,.1–.13)`, removed `#f2555a` on `rgba(242,85,90,.1–.13)`, with 2px solid left borders in transcripts.

### Type
- UI: `-apple-system / SF Pro Text` stack; mono: `ui-monospace, SFMono-Regular, Menlo`.
- Sizes are small and tight: microlabels 9–10px w/ letter-spacing `.07–.1em`, body 10.5–12px, terminal 12px/1.65 (13px/1.7 focused), modal titles 14px, first-run H1 25px.
- Weights: 600 for names/labels, 500 secondary, 400 body.

### Shape & depth
- Radii: chips 5–6, rows/buttons 6–8, panes 9, window/cards 11–12, modals 14.
- Shadows: window `0 30px 80px rgba(0,0,0,.65)`, modals `0 40px 90px rgba(0,0,0,.7)`, popover `0 24px 60px rgba(0,0,0,.6)`.
- Focused input: `border:1px solid rgba(139,149,255,.55)` + `box-shadow:0 0 0 3px rgba(139,149,255,.16)`.

### Animation (keyframes defined at line ~15)
| Name | Use | Timing |
|------|-----|--------|
| `om-spin` | comet border rotation | 3s linear infinite |
| `om-pulse` | busy status marks/dots | 1.8s (Claude) / 2.2s (Codex) ease-in-out; 1.1s for failed |
| `om-blink` | terminal caret | 1.1s step-end |
| `om-breathe` | amber attention ring (defined, used implicitly) | box-shadow expand/fade |

### Signature motifs (reuse everywhere)
1. **Status mark**: OmniAgent logo as CSS `mask` on a colored span + same-color `drop-shadow` glow; pulse while busy. Appears in pane headers, sidebar terminal rows, notifications, modal headers. Asset: `ui/src/assets/omniagent-mark-mask.png`.
2. **Comet ring**: conic-gradient square spinning inside an overflow-clipped inset layer. Only the *focused working* pane gets it; other states use static box-shadow rings.
3. **Brand-tinted chips** for engines; neutral chips for git branch.
4. **Session dot cluster**: one 5px dot per terminal in sidebar rows — a session's health at a glance.

---

## 5. Mapping to the existing codebase (`ui/src/`)

Mostly a **restyle/upgrade of components that already exist**, not new architecture:

| Design piece | Existing component | Delta |
|--------------|--------------------|-------|
| Title bar + identity chip + diff pill + bell | `AppChrome.tsx` | New centered chip, diff pill, bell badge cluster |
| Sidebar (switcher, sessions, terminals) | `Sidebar.tsx`, `SidebarSessionRow.tsx`, `SessionStatusLight.tsx` | Dot clusters, layout badge, masked status marks, New-terminal row |
| File tree + git badges | `FileTree.tsx`, `FileIcon.tsx` | changed-count badges, M/A letters, filter input |
| Account row | `AccountBadge.tsx` | "Brain indexed · Xm ago" sub-line |
| Pane grid + states | `Workspace.tsx`, `PaneHeader.tsx`, `Terminal.tsx` | Comet ring exists in repo already (see recent commits about busy-border comet + pane-ring CSS specificity); align colors/anatomy to this spec |
| Approval banner in pane | — (new) | New footer strip + Approve/Deny |
| Git review column | `CodeReviewPanel.tsx` / `ReviewPanel.tsx` | Group-by-terminal, inline diff cards, commit header |
| Notifications popover | `NotificationsPanel.tsx` | Needs-you section w/ inline actions, tabs |
| Workspace dropdown | `ProjectMenu.tsx` | Session counts, active checkmark, New-workspace row |
| New terminal modal | `NewChooserModal.tsx` + `EnginePicker.tsx` | Name field, slots-used counter, disabled Copilot row |
| New session modal | `NewSessionModal.tsx` | Prompt-as-name, layout thumbnails, engine-per-terminal grid |
| New workspace modal | `NewWorkspaceModal.tsx` | Folder stats strip, two toggles, scoped-access footer |
| First run | `onboarding/`, `EmptyWorkspace.tsx` | Hero + value strip |
| Focused terminal overlay | — (new?) | Scrim + zoomed pane, esc/⌃⌘F |
| Status bar | — (verify in `AppChrome`) | sessions/brain/CPU/MCP segments |

### Suggested work packages (for parallel agents, roughly independent)
1. **Tokens first** (blocking): extract §4 into `theme.ts` / CSS variables — colors, text ramp, radii, keyframes.
2. Title bar + status bar.
3. Sidebar (sessions + terminals + files + account).
4. Pane chrome (header anatomy, 4 state treatments, approval banner, comet ring alignment).
5. Git review column.
6. Notifications popover.
7. Modals (new terminal / new session / new workspace) + workspace dropdown.
8. First run + focused-terminal overlay.

Package 1 must land before the rest; 2–8 can run in parallel worktrees afterward.

### Keyboard map shown in the design
`⌘T` new terminal · `⌘N` new session · `⌘K` palette · `⌘⏎` run prompt · `⌃⌘F` focus terminal · `esc` exit focus · `⌘⇧]` next terminal · `⇧⌘G` git review · `⌘1/2/3/0` engine pick in modal.

### Fictional/demo content (do not implement literally)
Diff numbers (+1284 −312 14f), brain node count (41,208), CPU/RAM figures, the specific transcripts, session/task names, "8m ago" — all placeholder narrative to sell the states. Real counterparts come from PTY output, git status, and brain.db.

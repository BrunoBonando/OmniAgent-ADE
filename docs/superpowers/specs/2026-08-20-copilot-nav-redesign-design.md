# Copilot-Style Navigation Redesign — Design Spec

- **Date:** 2026-08-20
- **Status:** Approved (interactively, by Bruno)
- **Scope:** Native macOS app (`macos/`) only

## Context

The native macOS app's sidebar is a two-level sliding track (workspace picker → per-workspace nav/sessions/files). This redesign replaces it with GitHub Copilot's navigation structure — one flat sidebar column, workspaces as expandable groups, sessions as the primary rows — rendered in the app's existing design language (ShellPalette tokens; liquid-glass only where the app already uses it). It also adds a right-side review panel (Changes / Files / Browser / Insights) toggled from the content top bar. The design below was approved interactively on 2026-08-20.

## 1. Shell

- The app stays **single-window**.
- The sidebar becomes **one flat column** (Copilot structure: straight, squared) rendered in the app's existing design language — ShellPalette tokens; liquid-glass only where the app already uses it.
- Do **not** change the window `styleMask` or titlebar config.
- Content top bar: session name + exactly **one** button top-right: **Toggle review panel** (Cmd-Opt-B).

## 2. Sidebar (top to bottom)

### Fixed nav rows

- **Home**, **To Do List**, **Search** — SF Symbols approximating Copilot: `house`, `checklist`, `magnifyingglass`.
- Home and To Do List select placeholder content views ("Under development").
- Search is **not** a selection — it fires the existing command palette (Ctrl-Space also keeps working).

### "Workspaces" section header

Small gap, then a section header **"Workspaces"** with two small icon buttons: **Group-by** and **Plus**.

- **Group-by menu:** "Group by" title, then:
  - **Project** (default, checkmark)
  - **Status** — sessions bucketed under headers: *Needs attention* (`awaiting_approval`/`error`), *Working* (`thinking`/`tool_execution`), *Idle* (`ready`/none)
  - **Last updated** — flat session list, most recent status event first
  - Persist the choice.
- **Plus menu:**
  - "Start session in" + one item per open workspace
  - "Add project from" + "Local folder or repository…" (**only** that)
  - separator
  - "Resume remote session…" — **visible but disabled** (future)

### Workspace rows

- Folder icon (open-folder variant when expanded) tinted by the workspace's custom color; display name; disclosure to expand/collapse (persisted).
- "No sessions yet" dim row when empty.
- **No "Chats" row.**

### Session rows

- Name + status dots **only** (one dot per pane, existing ShellDotsView colors).
- **Pane rows are removed** from the sidebar entirely, as are per-session add-pane rows.
- Pinned sessions sort first within their workspace.
- Nested sessions render indented under their parent with a small tree connector line and the workspace name dimmed at the row's right edge.
- Hover cards and double-click inline rename keep working.
- Clicking **any** session (any workspace) switches to that workspace and activates that session's panes.

### Bottom pinned

- Placeholder user row (generic avatar circle + "Not signed in") + settings gear that opens the app's existing settings surface.

## 3. Context Menus

### Workspace row

New session · Show in Finder · Open on GitHub (only when a github.com remote exists; opens the repo page) · separator · Customize… · separator · Remove workspace (destructive red, with confirmation).

**Customize… dialog** (match app language, e.g. a PaneAsk-style card or sheet):

- Title: "Customize Workspace"
- Display name field, placeholder = folder name, caption "Leave blank to use \<folder name\>"
- Color row of 8 swatches: gray, green, blue, purple, pink, red, orange, gold
- Cancel / Save
- Persist per workspace; tint the folder icon (and reuse the display name wherever the workspace label shows).

### Session row

Rename (triggers inline rename) · Pin session / Unpin session · Open in… submenu · Create nested session · separator · Delete session.

- **Open in…:** only **installed** apps from: VS Code, VS Code Insiders, Terminal, Cursor, Xcode, iTerm, Warp, Ghostty — detect via NSWorkspace bundle-id lookup; opens the session's cwd.
- **Delete session:** destructive red; confirmation naming the session and its pane count; kills all its daemon sessions.
- **Nested session** = a normal new session recorded with parent = the right-clicked session's group; **depth 1 only**.

## 4. Content Routing

- Home / To Do List = placeholder views.
- Session selected = the pane workspace **exactly as today** (grid, focus mode, editor panes untouched).
- The Desk spatial canvas loses its **sidebar entry only** — it stays reachable via the existing menu/palette entries and all its code stays.
- The sidebar files tree is **removed from the sidebar** (it returns inside the review panel).

## 5. Review Panel (right side of session content)

- Toggled by the top-bar button / Cmd-Opt-B.
- **Split layout:** a third split item on the right; the pane grid squeezes; resizable divider.
- Panel state (open/closed, tabs open, active tab, width, open file) persists **per session** and restores when switching sessions.
- Tab bar across the panel top (tabs closable with an x, "+" menu adds views) + expand-to-full-width button.

### Changes tab

- Read-only working-tree diff for the workspace — changed-file list (git status) and a diff view of the selected file.
- Centered empty state: "No changes to compare / Make changes in this workspace to see them here".
- **No staging or committing.**
- Refresh on activation + a refresh button.

### Files tab

- "Filter files…" field; lazy file tree.
- Settings gear popover: Show hidden files toggle; File tree position: Left / Right.
- A hide-file-tree toggle button.
- Clicking a file opens it Monaco-style inside the panel.
- Right-click in the tree: New file / New folder.

### Browser tab

- WKWebView + URL bar + back/forward/reload.
- Detects dev-server ports (`localhost:NNNN`) from the session's terminal output and offers them as quick suggestions.

### Insights tab

- Agent-activity view from the data the app actually has (daemon status events + PaneActivityLedger + UsageAnalytics).
- Header: "Agent activity: \<active time\> · \<n\> tool runs".
- Per-pane timeline lanes colored by status since launch.
- A Time-by-status breakdown.
- Simple horizontal zoom.
- No context-percentage chart — that data does not exist yet; noted as future work.

## 6. Out of Scope

- **Editor panes:** untouched this project.
- **Desk canvas code:** untouched.

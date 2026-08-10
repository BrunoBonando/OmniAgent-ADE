repo: BrunoBonando/OmniAgent-ADE
branch: main

## Last sync
date: 2026-07-26T21:46:40Z

### Updated in this project
- Status glyph per terminal now uses the repo's real OmniAgent mark mask (`ui/src/assets/omniagent-mark-mask.png`), tinted per status like `SessionStatusLight`.
- Hierarchy corrected: Workspace > Session (max 8 terminals, layout presets 1/1x2/2x2/2x3/2x4) > Terminals.
- Per-terminal focus mode (zoom + blur the rest); layout control removed from the top right.
- New terminal modal (Cmd-T: name pre-filled "Terminal #5" + engine), new session (Cmd-N), workspace dropdown with "+ New workspace".

## Sync history

### 2026-07-26T21:07:13Z
- Rebuilt the app shell as a hi-fi mock: `OmniAgent ADE.dc.html` (1440×900, clickable states).
- Title bar redesigned so the app owns the centered window identity (fixes the double title overlap).
- New top-right cluster: git diff pill → right-hand review column, notifications inbox, layout controls.
- Sidebar reworked: workspace switcher, session rows with status + agent, Finder-like file tree with git state.

## Screen map
| Screen / state | Built from |
| --- | --- |
| Title bar + top-right cluster | ui/src/components/AppChrome.tsx, ui/src/components/NotificationsPanel.tsx |
| Pane grid + pane headers | ui/src/components/PaneHeader.tsx, ui/src/components/Workspace.tsx, ui/src/theme.ts |
| Sidebar (sessions + files) | ui/src/components/Sidebar.tsx, SidebarSessionRow.tsx, FileTree.tsx |
| Git review column | ui/src/components/CodeReviewPanel.tsx, docs/reference/warp-code-review-panel.png |
| Notifications panel | ui/src/components/NotificationsPanel.tsx, docs/reference/warp-notifications-panel.png |
| New session / workspace / engine picker | NewSessionModal.tsx, NewWorkspaceModal.tsx, EnginePicker.tsx |
| First run | ui/src/onboarding/, README.md "First run" |

# Workspace-first startup

## Problem

OmniAgent currently renders its full shell while the boot effect restores every
persisted terminal sequentially. Each Claude pane may fetch a briefing before
`session_create` reconnects or starts its backend session. The window therefore
looks ready while expensive startup work is still running, and a saved layout
with several panes can feel frozen.

Startup also auto-selects the first available workspace. This starts work before
the user has chosen what they want to work on.

## Goals

- Make the first screen feel intentional and distinctly OmniAgent.
- Never restore a terminal before the user selects a workspace.
- Let the user choose an existing workspace or start from scratch.
- Restore only the selected workspace's visible session.
- Keep the interface responsive and informative while terminals reconnect.
- Preserve the existing workspace, session, pane, and terminal persistence
  behavior after selection.

## Non-goals

- Changing the frozen MCP command shapes.
- Replacing the existing new-workspace flow.
- Restoring hidden sessions or panes speculatively.
- Adding a new animation, state-management, or routing dependency.
- Redesigning the normal workspace shell.

## Startup state model

The application has three user-visible phases:

1. `booting`: read the minimum metadata required to present the landing page.
2. `choosing-workspace`: show the workspace landing page; no terminal is live.
3. `workspace-active`: mount the existing shell and lazily restore the visible
   session for the selected workspace.

The state is held in `App.tsx`; no new state library or abstraction is needed.
Persisted layout data is parsed during boot but treated as metadata. Calling
`getBriefing` and `sessionCreate` is deferred until workspace/session selection.
Session restoration uses the native PTY daemon; this design adds no tmux path
or tmux-specific behavior.

Every application launch returns to workspace selection. The application does
not automatically enter the previously selected or first workspace.

## Boot screen

The initial window uses a clean, dark, empty background with no application
chrome, sidebar, map, terminal, dialog, or workspace mounted.

The center contains:

- the existing OmniAgent mark at a large size;
- an electric-blue terminal-like blink/glow;
- `Loading…` below it in the existing monospace type.

The animation is restrained and continuous rather than a spinner. With
`prefers-reduced-motion: reduce`, the mark uses a steady blue glow and no
position or opacity animation.

Only lightweight startup reads belong in this phase:

- closed-workspace preferences;
- project metadata;
- root/onboarding state;
- persisted layout metadata;
- authentication-gate settings needed to determine the next screen.

Agent installation checks, notification restoration, ingestion polling, and
other non-blocking shell data may continue independently, but they must not
delay the workspace landing page.

## Transition to workspace selection

When required metadata is ready, the existing mark remains visible and becomes
the anchor of the landing page:

- it moves upward by roughly 15% of the window height;
- it shrinks into a compact brand mark;
- `OmniAgent` fades in beside or below it;
- `Loading…` disappears;
- workspace choices rise gently into view.

This continuity avoids replacing one splash screen with an unrelated page. The
motion uses CSS only and is disabled under reduced-motion preferences.

## Workspace landing page

The landing page remains outside the normal application shell. Beneath the
OmniAgent identity it shows the heading `Choose your workspace` and a centered
horizontal row.

The first item is a visually distinct `Start from scratch` card. Activating it
opens the existing new-workspace flow, reusing its native folder picker,
validation, preferences, and project creation behavior. Creating a workspace
selects it and proceeds to the existing new-session experience; creation alone
does not start a terminal.

The remaining cards represent open, existing workspaces. Each card shows:

- workspace name;
- shortened path;
- the existing deterministic workspace color/avatar treatment.

The row scrolls horizontally when required. Cards are buttons with visible
keyboard focus. Tab reaches the row and arrow keys move among workspace cards.
Enter or Space selects the focused card.

When there are no existing workspaces, `Start from scratch` is the single,
centered primary action. Closed workspaces remain excluded according to the
existing closed-workspace setting.

## Selecting a workspace

Selecting an existing workspace immediately enters the normal application
shell for that workspace. Project/session metadata appears without waiting for
a terminal process.

Only the session that should initially be visible is restored:

- use the first persisted session for the workspace, preserving persisted tab
  order;
- when no session was persisted, show the existing empty-workspace/new-session
  experience.

All panes belonging to that one visible session may restore because the pane
grid is the visible unit. Persisted sessions belonging to other workspaces or
hidden sessions remain metadata-only.

Selecting a metadata-only session later routes through the same restoration
path. A session already restored in this app is reused and never started twice.

## Session loading state

While the selected session reconnects through the native PTY daemon, the
workspace shell stays responsive.
The terminal area displays:

- a smaller blinking blue OmniAgent mark;
- `Loading session…`;
- the existing workspace/sidebar context around it.

Each pane replaces its loading surface when its backend session is ready.
Terminal creation remains sequential initially because the current restore
contract and ordering are proven; parallel restoration is deferred until
measurement shows it is necessary.

If a pane cannot reattach with its persisted ID, retain the existing fallback
to one fresh `sessionCreate` call. If both attempts fail, that pane shows
`Couldn’t restore this terminal` and a `Retry` action. One failed pane does not
block the workspace or other panes.

## Data flow

```text
Tauri setup
  -> React mounts boot screen
  -> read project/layout metadata only
  -> workspace landing page
       -> Start from scratch -> existing creation flow -> new-session flow
       -> existing workspace -> mount shell
            -> resolve visible persisted session
            -> show session loading surface
            -> fetch briefing/create only its panes
            -> terminal panes become live
            -> later session selection lazily repeats this path
```

The Rust setup remains responsible for opening the store and registering
managed state. The principal freeze is addressed in the frontend boot flow,
where persisted pane restoration is currently coupled to project loading.

## Testing

Add focused Vitest coverage that proves:

- the boot screen is shown while project metadata is pending;
- no `getBriefing` or `sessionCreate` call happens before workspace selection;
- metadata readiness shows `Start from scratch` and existing workspace cards;
- an empty project list emphasizes `Start from scratch`;
- selecting a workspace restores only its visible persisted session;
- hidden sessions and other workspaces remain unrestored until selected;
- the session loading surface remains until restoration resolves;
- a failed restore exposes Retry without blocking the shell;
- reduced-motion CSS disables blinking and movement.

Retain and adapt the existing boot-restore and session-restore regression tests
so their persistence guarantees move behind explicit workspace selection.

Run:

```sh
npm --prefix ui run test
npm --prefix ui run build
```

Rust commands and MCP shapes are unchanged, so Rust contract changes are not
expected.

## Scope discipline

Use the existing logo assets, theme tokens, workspace colors, new-workspace
flow, persisted layout format, reducers, and Tauri wrappers. Add no dependency
and no speculative prefetching. The implementation should touch the fewest
frontend files needed to introduce the landing/loading views and defer the
existing restore loop.

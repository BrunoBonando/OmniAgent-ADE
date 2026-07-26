# Terminal Focus and Keyboard Navigation

## Scope

Make the focused terminal visible outside its title bar and add keyboard
navigation for panes and sessions. No shortcut preferences or new navigation
state are introduced.

## Terminal focus

The pane body whose tab ID matches `activeTabId` receives a focused class. CSS
renders a subtle one-pixel inset accent outline, so the cue does not affect
layout or cover terminal text.

## Pane navigation

`Ctrl+Tab` is handled by the visible session grid. It follows the pane order in
the grid's mosaic tree, activates the next pane, and wraps from the final pane
to the first. With fewer than two visible panes it does nothing.

## Session navigation

`Ctrl+ArrowDown` and `Ctrl+ArrowUp` move through the selected workspace's
existing session order. Navigation stops at the first and last sessions rather
than wrapping. Entering a session activates its currently focused pane when
available, otherwise its first pane.

## Verification

Focused tests cover the body focus class, forward pane cycling and wraparound,
hidden-grid isolation, session movement, and both session boundaries.

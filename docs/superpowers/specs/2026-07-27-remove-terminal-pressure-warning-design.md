# Remove Terminal Pressure Warning

## Goal

Remove the top workspace warning shown when more than six terminals are open.

## Design

Delete the warning render block from `Workspace`, its now-unused pressure
helper and threshold, their unit tests, and the warning's CSS. Keep the
independent eight-terminal-per-session limit unchanged.

## Verification

Run the focused UI tests for session state and workspace rendering, then run
the UI build to catch unused imports and type errors.

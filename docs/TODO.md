# Leftovers

Deliberate deferrals. Each line says what to do and when it's worth doing.

- Rename the `Desk` destination's internals — `WorkspaceDestination.terminals`,
  `PaneWorkspaceView`, `maxTerminals` — to match the user-facing name. Do it when
  the terminal-only naming starts misleading someone reading the pane code, not
  before; it's a pure rename with no behaviour change.
  (The `Terminals` stat tile in Usage stays — it really does count terminals.)

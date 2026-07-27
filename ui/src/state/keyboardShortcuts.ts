// The app's real keyboard shortcuts, as data — backing the "Keyboard
// shortcuts" row of the account menu (founder ask, 2026-07-26: the user
// menu's reference has one, and unlike most of that menu's rows this app
// genuinely has shortcuts worth listing).
//
// **Every entry here must be a binding that actually exists in the code.**
// This list is the user-facing contract for keys, so an aspirational row
// would be a lie the same way a dead menu item is. Each group names where
// its bindings live so the next person to add a key knows where to keep
// this honest:
//
// - Global (⌘T/⌘K/⌘N): `App.tsx`'s window keydown handler.
// - Dialogs: no single interaction model any more — the two-card ⌘N
//   chooser and `EnginePicker.tsx` that used to define one were both
//   retired (Task 13, 2026-07-27). Each dialog now owns its own key
//   handling: `NewSessionModal.tsx` picks a layout on a bare digit,
//   `NewTerminalModal.tsx`/`state/newTerminalState.ts`'s
//   `terminalKeyAction` picks an engine on ⌘+digit, and
//   `NewWorkspaceModal.tsx`/the `Close*Confirm.tsx` family take only
//   Enter/Escape.
// - Panes: `PaneHeader.tsx` (double-click rename, its Enter/Escape) and
//   `Workspace.tsx`'s mosaic grid.
//
// `keys` is an array so each chord renders as its own <kbd>, and "or"
// alternatives read as separate keys rather than one string with a slash in
// it.

export interface ShortcutGroup {
  title: string;
  shortcuts: Shortcut[];
}

export interface Shortcut {
  keys: string[];
  /** What it does, phrased as the action the person takes. */
  description: string;
}

export const SHORTCUT_GROUPS: ShortcutGroup[] = [
  {
    title: "Anywhere",
    shortcuts: [
      { keys: ["⌘T"], description: "New terminal in the selected project" },
      { keys: ["⌘K"], description: "Command palette — switch session, search the brain" },
      { keys: ["⌘N"], description: "New session — or new workspace, with none selected" },
    ],
  },
  {
    title: "In a dialog",
    shortcuts: [
      { keys: ["⏎"], description: "Confirm — the default is already selected" },
      { keys: ["esc"], description: "Cancel" },
      { keys: ["⌘1", "⌘2", "⌘3", "⌘0"], description: "Pick an engine (New Terminal)" },
      { keys: ["1", "2", "3", "4", "5"], description: "Pick a layout (New Session)" },
    ],
  },
  {
    title: "In a pane",
    shortcuts: [
      { keys: ["double-click"], description: "Rename this session (⏎ to keep, esc to drop it)" },
      { keys: ["drag"], description: "Move a pane by its header to rearrange the grid" },
    ],
  },
];

/** Flat list — used by the tests, and by anything that needs to check a key
 * is documented exactly once. */
export function allShortcuts(): Shortcut[] {
  return SHORTCUT_GROUPS.flatMap((g) => g.shortcuts);
}

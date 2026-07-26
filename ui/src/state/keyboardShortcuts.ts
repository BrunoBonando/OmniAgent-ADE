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
// - Dialogs (arrows/Enter/Escape/digits): `state/newChooserState.ts`'s
//   `chooserKeyAction` and `EnginePicker.tsx`, which share one interaction
//   model on purpose.
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
      { keys: ["⌘N"], description: "New session or workspace" },
    ],
  },
  {
    title: "In a dialog",
    shortcuts: [
      { keys: ["↑", "↓", "←", "→"], description: "Move the selection" },
      { keys: ["⏎"], description: "Confirm — the default is already selected" },
      { keys: ["1", "2"], description: "Pick that card and confirm it" },
      { keys: ["esc"], description: "Cancel" },
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

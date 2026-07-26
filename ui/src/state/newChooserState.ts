// Pure, framework-free state for the ⌘N chooser (founder brief,
// 2026-07-26, verbatim: *"cmd + N now has a new meaning. Either a new
// session or a new workspace. User should be prompted with a window with a
// similar style of the layout options to choose either session or
// workspace. Session is the first and default. Remember to make everything
// always keyboard first, so the user can simply navigate with keyboard."*).
//
// Zero React imports so the whole keyboard state machine is testable as a
// table of (key, current) -> action, which is the only way to be sure
// "keyboard first" actually holds for every key rather than for the three
// anyone remembered to click through.
//
// The interaction model is `EnginePicker.tsx`'s, deliberately — that's this
// codebase's established precedent for a keyboard-first chooser (open with
// the default already selected so Enter alone does the common thing in one
// keystroke; arrows move; digits pick directly; Escape cancels), and a
// second, differently-behaved picker would be the actual usability problem.
// What's new here is the *axis*: these are two side-by-side cards styled
// like `NewWorkspaceModal`'s LAYOUT presets, so left/right moves as well as
// up/down, and Tab (which a keyboard user will try in a two-card dialog)
// moves too rather than tabbing out of the panel into nowhere.

export const CREATE_CHOICES = ["session", "workspace"] as const;
export type CreateChoice = (typeof CREATE_CHOICES)[number];

/** "Session is the first and default" — his words, and the reason Enter on
 * an untouched dialog opens the session flow. */
export const DEFAULT_CREATE_CHOICE: CreateChoice = "session";

export interface CreateChoiceOption {
  id: CreateChoice;
  label: string;
  /** One line under the label — what this choice actually does, in the
   * user's terms (a folder vs. a set of panes), not the implementation's. */
  caption: string;
}

export const CREATE_CHOICE_OPTIONS: CreateChoiceOption[] = [
  {
    id: "session",
    label: "Session",
    caption: "New panes in the project you're in — its folder or a subfolder.",
  },
  {
    id: "workspace",
    label: "Workspace",
    caption: "A new project from another folder on your machine.",
  },
];

/** Wraps at both ends, same as `cycleEngine` — a two-item list where the
 * arrow key sometimes does nothing would be worse than one that cycles. */
export function moveChoice(current: CreateChoice, direction: 1 | -1): CreateChoice {
  const index = CREATE_CHOICES.indexOf(current);
  const next = (index + direction + CREATE_CHOICES.length) % CREATE_CHOICES.length;
  return CREATE_CHOICES[next];
}

export type ChooserKeyAction =
  | { type: "move"; choice: CreateChoice }
  | { type: "confirm"; choice: CreateChoice }
  | { type: "cancel" };

/**
 * The whole keyboard contract, as data. `null` = this key isn't ours, leave
 * it to the browser.
 *
 * - `ArrowRight`/`ArrowDown`/`l`/`j`/`Tab` → next card
 * - `ArrowLeft`/`ArrowUp`/`h`/`k`/`Shift+Tab` → previous card
 * - `Enter`/`Space` → confirm what's selected
 * - `1`/`2` → pick that card *and* confirm it, one keystroke (EnginePicker's
 *   digit precedent — the fastest path for someone who knows what they want)
 * - `Escape` → cancel
 */
export function chooserKeyAction(
  key: string,
  current: CreateChoice,
  shiftKey = false,
): ChooserKeyAction | null {
  if (key === "Escape") return { type: "cancel" };
  if (key === "Enter" || key === " " || key === "Spacebar") return { type: "confirm", choice: current };
  if (key === "Tab") return { type: "move", choice: moveChoice(current, shiftKey ? -1 : 1) };
  if (key === "ArrowRight" || key === "ArrowDown" || key === "l" || key === "j") {
    return { type: "move", choice: moveChoice(current, 1) };
  }
  if (key === "ArrowLeft" || key === "ArrowUp" || key === "h" || key === "k") {
    return { type: "move", choice: moveChoice(current, -1) };
  }
  const digit = Number(key);
  if (Number.isInteger(digit) && digit >= 1 && digit <= CREATE_CHOICES.length) {
    return { type: "confirm", choice: CREATE_CHOICES[digit - 1] };
  }
  return null;
}

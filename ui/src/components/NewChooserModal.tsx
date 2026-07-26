// ⌘N's first step (founder brief, 2026-07-26, verbatim: *"cmd + N now has a
// new meaning. Either a new session or a new workspace. User should be
// prompted with a window with a similar style of the layout options to
// choose either session or workspace. Session is the first and default.
// Remember to make everything always keyboard first, so the user can simply
// navigate with keyboard."*).
//
// "A similar style of the layout options" is literal: these are the same
// selectable cards `NewWorkspaceModal`'s LAYOUT row uses — same shape, same
// selected treatment (`.new-workspace-layout-card.is-selected`), same
// caption-under-the-row pattern — so the chooser reads as the first step of
// the same dialog rather than a different dialog's front door.
//
// Every keyboard decision lives in `state/newChooserState.ts`'s
// `chooserKeyAction`, as a pure (key, current) -> action function. This file
// dispatches it and renders; it decides nothing about keys, which is what
// makes "keyboard first" testable exhaustively rather than by clicking
// through the three combinations someone remembered.
import { useEffect, useRef, useState, type ReactElement } from "react";
import {
  CREATE_CHOICE_OPTIONS,
  DEFAULT_CREATE_CHOICE,
  chooserKeyAction,
  type CreateChoice,
} from "../state/newChooserState";

interface NewChooserModalProps {
  onChoose: (choice: CreateChoice) => void;
  onClose: () => void;
}

/** Two panes side by side — the same CSS-drawn glyph vocabulary as
 * `NewWorkspaceModal`'s `LayoutGlyph`, because a session *is* a set of
 * panes. */
function SessionGlyph() {
  return (
    <span
      className="new-workspace-layout-glyph"
      style={{ gridTemplateRows: "repeat(1, 1fr)", gridTemplateColumns: "repeat(2, 1fr)" }}
      aria-hidden
    >
      <span className="new-workspace-layout-glyph-cell" />
      <span className="new-workspace-layout-glyph-cell" />
    </span>
  );
}

/** A folder — a workspace is a folder on disk, and this is the same path
 * `NewWorkspaceModal`'s own DIRECTORY row draws. */
function WorkspaceGlyph() {
  return (
    <span className="new-workspace-layout-glyph is-folder" aria-hidden>
      <svg viewBox="0 0 20 16" width="26" height="21" fill="none">
        <path
          d="M1 2.5C1 1.67 1.67 1 2.5 1H7l2 2h8.5c.83 0 1.5.67 1.5 1.5v9c0 .83-.67 1.5-1.5 1.5h-15C1.67 15 1 14.33 1 13.5v-11Z"
          stroke="currentColor"
          strokeWidth="1.3"
          strokeLinejoin="round"
        />
      </svg>
    </span>
  );
}

const GLYPHS: Record<CreateChoice, () => ReactElement> = {
  session: SessionGlyph,
  workspace: WorkspaceGlyph,
};

export default function NewChooserModal({ onChoose, onClose }: NewChooserModalProps) {
  const [selected, setSelected] = useState<CreateChoice>(DEFAULT_CREATE_CHOICE);
  const panelRef = useRef<HTMLDivElement | null>(null);

  // Focused on mount so the very first keystroke lands here — with the
  // default already selected, ⌘N then Enter creates a session in two
  // keystrokes and never touches the mouse.
  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  function handleKeyDown(e: React.KeyboardEvent) {
    const action = chooserKeyAction(e.key, selected, e.shiftKey);
    if (!action) return;
    e.preventDefault();
    if (action.type === "cancel") onClose();
    else if (action.type === "move") setSelected(action.choice);
    else onChoose(action.choice);
  }

  const caption = CREATE_CHOICE_OPTIONS.find((o) => o.id === selected)?.caption ?? "";

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        ref={panelRef}
        className="new-chooser-panel"
        role="dialog"
        aria-label="Create new"
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="new-workspace-header">
          <h2 className="new-workspace-title">Create new</h2>
          <button className="new-workspace-close" onClick={onClose} aria-label="Close">
            &#215;
          </button>
        </div>

        <div className="new-workspace-section">
          <div className="new-workspace-layout-row" role="radiogroup" aria-label="What to create">
            {CREATE_CHOICE_OPTIONS.map((option, i) => {
              const Glyph = GLYPHS[option.id];
              const isSelected = option.id === selected;
              return (
                <button
                  key={option.id}
                  type="button"
                  role="radio"
                  aria-checked={isSelected}
                  className={`new-workspace-layout-card new-chooser-card${isSelected ? " is-selected" : ""}`}
                  // Hover selects, click confirms — EnginePicker's exact
                  // mouse behaviour, so the pointer path and the keyboard
                  // path end in the same place.
                  onMouseEnter={() => setSelected(option.id)}
                  onFocus={() => setSelected(option.id)}
                  onClick={() => onChoose(option.id)}
                >
                  <Glyph />
                  <span className="new-workspace-layout-number">{option.label}</span>
                  <span className="new-chooser-card-key" aria-hidden="true">
                    {i + 1}
                  </span>
                </button>
              );
            })}
          </div>
          <p className="new-workspace-layout-caption">{caption}</p>
        </div>

        <div className="engine-picker-footer">
          <span>&#8629; confirm</span>
          <span>&larr;&rarr; choose</span>
          <span>esc cancel</span>
        </div>
      </div>
    </div>
  );
}

// The "Keyboard shortcuts" sheet — one of the two genuinely-wired rows of
// the account menu (see `state/accountBadgeState.ts`'s module doc for why
// most of the reference menu's rows are omitted instead of faked).
//
// A plain overlay panel in the same frame every other dialog uses
// (`.overlay-backdrop` + the shared panel shell in App.css), listing
// `state/keyboardShortcuts.ts` — which is the single source of truth, kept
// deliberately in that pure module so this file has no chance to invent a
// binding that doesn't exist.
import { useEffect, useRef } from "react";
import { SHORTCUT_GROUPS } from "../state/keyboardShortcuts";
import Icon from "./Icon";

interface KeyboardShortcutsSheetProps {
  onClose: () => void;
}

export default function KeyboardShortcutsSheet({ onClose }: KeyboardShortcutsSheetProps) {
  const panelRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        ref={panelRef}
        className="shortcuts-panel"
        role="dialog"
        aria-label="Keyboard shortcuts"
        tabIndex={-1}
        onMouseDown={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          if (e.key === "Escape" || e.key === "Enter") {
            e.preventDefault();
            onClose();
          }
        }}
      >
        <div className="shortcuts-header">
          <h2 className="shortcuts-title">Keyboard shortcuts</h2>
          <button className="new-workspace-close" onClick={onClose} aria-label="Close">
            <Icon name="x" size={15} strokeWidth={2.1} />
          </button>
        </div>

        {SHORTCUT_GROUPS.map((group) => (
          <section key={group.title} className="shortcuts-group">
            <span className="new-workspace-section-label">{group.title}</span>
            <ul className="shortcuts-list">
              {group.shortcuts.map((shortcut) => (
                <li key={shortcut.description} className="shortcuts-row">
                  <span className="shortcuts-keys">
                    {shortcut.keys.map((key) => (
                      <kbd key={key} className="shortcuts-key">
                        {key}
                      </kbd>
                    ))}
                  </span>
                  <span className="shortcuts-description">{shortcut.description}</span>
                </li>
              ))}
            </ul>
          </section>
        ))}

        <p className="shortcuts-footer">esc to close</p>
      </div>
    </div>
  );
}

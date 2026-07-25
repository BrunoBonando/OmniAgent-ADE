// The pane header's 3-dot (⋯) menu — founder ask, verbatim: "it should be
// possible to change the current one by a 3 dot configuration on the upper
// right corner of each terminal." One menu surface, two sections, per the
// task's own framing ("This is the same menu surface for both concerns, not
// two separate UI affordances"):
//
// - CHANGE ENGINE: kills the pane's live session and spawns a NEW one with
//   a different engine, same pane/slot, same project/cwd — you can't
//   hot-swap a live PTY's engine. Labeled "Restart with {Engine}" rather
//   than a plain engine name (the task's own suggested wording) so the
//   restart is clear from the label alone, no separate confirm step.
// - TERMINAL THEME: this pane's xterm color theme (`terminalThemes.ts`),
//   applied and persisted immediately on click — "should be always saved
//   automatically" per the founder, so there's no separate save action.
//
// Same small-popover pattern as `ProjectMenu.tsx` (transparent click-away
// backdrop, anchored under the trigger rather than centered — a utility,
// not a modal moment).
import { ENGINES, type Engine } from "../state/sessions";
import { ENGINE_COLOR, ENGINE_LABEL } from "../theme";
import { TERMINAL_THEME_HINT, TERMINAL_THEME_IDS, TERMINAL_THEME_LABELS, TERMINAL_THEMES, type TerminalThemeId } from "../lib/terminalThemes";

interface PaneMenuProps {
  currentEngine: Engine;
  /** Always a real preset id (never `undefined`) — the caller resolves the
   * pane's override against the global default before rendering this, so
   * the menu never has to know about that fallback rule itself. */
  currentThemeId: TerminalThemeId;
  onChangeEngine: (engine: Engine) => void;
  onChangeTheme: (themeId: TerminalThemeId) => void;
  onClose: () => void;
}

export default function PaneMenu({
  currentEngine,
  currentThemeId,
  onChangeEngine,
  onChangeTheme,
  onClose,
}: PaneMenuProps) {
  return (
    <>
      <div className="pane-menu-backdrop" onMouseDown={onClose} />
      <div className="pane-menu" role="menu" aria-label="Terminal options" onMouseDown={(e) => e.stopPropagation()}>
        <div className="pane-menu-section-label">Change engine</div>
        <ul className="pane-menu-list">
          {ENGINES.map((engine) => {
            const isCurrent = engine === currentEngine;
            return (
              <li key={engine}>
                <button
                  type="button"
                  className="pane-menu-row"
                  disabled={isCurrent}
                  onClick={() => {
                    onChangeEngine(engine);
                    onClose();
                  }}
                >
                  <span className="engine-dot" style={{ background: ENGINE_COLOR[engine] }} aria-hidden />
                  <span className="pane-menu-row-label">
                    {isCurrent ? `${ENGINE_LABEL[engine]} (current)` : `Restart with ${ENGINE_LABEL[engine]}`}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>

        <div className="pane-menu-divider" />

        <div className="pane-menu-section-label">Terminal theme</div>
        <ul className="pane-menu-list">
          {TERMINAL_THEME_IDS.map((themeId) => {
            const isCurrent = themeId === currentThemeId;
            return (
              <li key={themeId}>
                <button
                  type="button"
                  className={`pane-menu-row${isCurrent ? " is-selected" : ""}`}
                  onClick={() => {
                    onChangeTheme(themeId);
                    onClose();
                  }}
                  aria-pressed={isCurrent}
                >
                  <span
                    className="pane-menu-theme-swatch"
                    aria-hidden
                    style={{
                      background: TERMINAL_THEMES[themeId].background,
                      color: TERMINAL_THEMES[themeId].foreground,
                    }}
                  >
                    A
                  </span>
                  <span className="pane-menu-row-text">
                    <span className="pane-menu-row-label">{TERMINAL_THEME_LABELS[themeId]}</span>
                    <span className="pane-menu-row-hint">{TERMINAL_THEME_HINT[themeId]}</span>
                  </span>
                  {isCurrent && (
                    <span className="pane-menu-check" aria-hidden>
                      &#10003;
                    </span>
                  )}
                </button>
              </li>
            );
          })}
        </ul>
      </div>
    </>
  );
}

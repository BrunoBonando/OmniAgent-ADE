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
//
// - CODE REVIEW (founder ask, 2026-07-26, verbatim): "For each session, have
//   a top right menu with three things: Code Review Panel info (number of
//   changes within files that are uncommited) and if clicked, it should show
//   a code review panel for that session". The count is fetched here, on
//   open, for THIS pane's own cwd — this component only mounts while the
//   menu is actually open, so that's exactly one `git status` per menu
//   opening and no background polling at all. A pane whose cwd isn't a git
//   repo simply shows no badge rather than an error.
import { useEffect, useState } from "react";
import { ENGINES, type Engine } from "../state/sessions";
import { ENGINE_COLOR, ENGINE_LABEL } from "../theme";
import { reviewStatus } from "../lib/tauri";
import Icon from "./Icon";
import { TERMINAL_THEME_HINT, TERMINAL_THEME_IDS, TERMINAL_THEME_LABELS, TERMINAL_THEMES, type TerminalThemeId } from "../lib/terminalThemes";

interface PaneMenuProps {
  currentEngine: Engine;
  /** Always a real preset id (never `undefined`) — the caller resolves the
   * pane's override against the global default before rendering this, so
   * the menu never has to know about that fallback rule itself. */
  currentThemeId: TerminalThemeId;
  onChangeEngine: (engine: Engine) => void;
  onChangeTheme: (themeId: TerminalThemeId) => void;
  /** This pane's cwd — what the change count is counted for, and what the
   * panel is scoped to. */
  repoPath?: string;
  /** Opens the review column for this pane. Optional so callers that don't
   * wire it (most existing tests) simply don't get the entry. */
  onOpenCodeReview?: () => void;
  onClose: () => void;
}

export default function PaneMenu({
  currentEngine,
  currentThemeId,
  onChangeEngine,
  onChangeTheme,
  repoPath,
  onOpenCodeReview,
  onClose,
}: PaneMenuProps) {
  // `null` = still counting, `undefined` = not a git repo / lookup failed.
  const [changeCount, setChangeCount] = useState<number | null | undefined>(null);

  useEffect(() => {
    if (!repoPath || !onOpenCodeReview) return;
    let cancelled = false;
    reviewStatus(repoPath)
      .then((s) => {
        if (!cancelled) setChangeCount(s.file_count);
      })
      .catch(() => {
        // Not a git repo is the common, boring case — no badge, no error.
        if (!cancelled) setChangeCount(undefined);
      });
    return () => {
      cancelled = true;
    };
  }, [repoPath, onOpenCodeReview]);

  return (
    <>
      <div className="pane-menu-backdrop" onMouseDown={onClose} />
      <div className="pane-menu" role="menu" aria-label="Terminal options" onMouseDown={(e) => e.stopPropagation()}>
        {onOpenCodeReview && (
          <>
            <div className="pane-menu-section-label">Review</div>
            <ul className="pane-menu-list">
              <li>
                <button
                  type="button"
                  className="pane-menu-row"
                  onClick={() => {
                    onOpenCodeReview();
                    onClose();
                  }}
                >
                  <Icon name="compare" size={14} className="pane-menu-review-glyph" />
                  <span className="pane-menu-row-text">
                    <span className="pane-menu-row-label">Code review</span>
                    <span className="pane-menu-row-hint">
                      {changeCount === null
                        ? "counting uncommitted changes…"
                        : changeCount === undefined
                          ? "this session isn't in a git repo"
                          : changeCount === 0
                            ? "no uncommitted changes"
                            : `${changeCount} uncommitted ${changeCount === 1 ? "change" : "changes"}`}
                    </span>
                  </span>
                  {typeof changeCount === "number" && changeCount > 0 && (
                    <span className="pane-menu-badge" aria-label={`${changeCount} uncommitted changes`}>
                      {changeCount}
                    </span>
                  )}
                </button>
              </li>
            </ul>

            <div className="pane-menu-divider" />
          </>
        )}

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

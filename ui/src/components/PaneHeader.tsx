// One pane's header bar in the terminal grid (BridgeSpace pane-grid
// rebuild — see docs/DESIGN.md and the founder's reference screenshot at
// docs/reference/bridgespace-pane-grid-reference.png). Re-houses every real
// feature `TabBar.tsx`'s pill used to own (engine dot, rename-on-dblclick,
// attention badge, close button — all from prior feedback-round work, none
// dropped here) plus two things the reference added: a git-branch pill and
// a per-pane "+" (split) button. `Workspace.tsx` renders one of these per
// `react-mosaic-component` tile via `MosaicWindow`'s `renderToolbar` — see
// that file's module doc for why the whole returned element becomes the
// drag handle, and why the rename input / branch tag / buttons below all
// set `draggable={false}` (or stop the mousedown) so grabbing them doesn't
// also start a pane-rearrange drag.
//
// ## 2026-07-26 founder round — what this header now shows, and where the
// ## engine colour went
//
// Three asks landed together and all three live here:
//
// 1. *"Can you make the logo of OmniAgent instead of the simple dot but in
//    the colors above?"* — the leading dot is now `SessionStatusLight`: the
//    OmniAgent mark, tinted and animated by this session's live five-state
//    status (`state/sessionStatus.ts`).
// 2. *"terminal title has a dropdown with main, remove it. This must be
//    connected to the session as a tag"* — the git-branch pill is now a tag
//    (`.pane-header-tag`), same data, no control affordance.
// 3. *"for each session, have a hover with more info, like warp does"* +
//    *"on hover, it explains, of course"* — one `SessionHoverCard`, opened
//    by resting on the header, carrying the status explanation *and* the
//    session facts. Deliberately ONE surface: a tooltip on the light nested
//    inside a card on the header would be two popovers racing each other
//    every time the pointer crosses on its way to the close button.
//
// **Engine identity** used to be this header's leading dot
// (`ENGINE_COLOR[tab.engine]`). Status took that slot, so the signal moved
// rather than being dropped: the branch tag is tinted with the engine's
// colour (so "which engine is this pane" is still readable at a glance, in
// the same header, with no extra chrome added), and the hover card names it
// outright — `● Claude Code`, avatar-row style, the way Warp's card does.
// The two never collide because the light is a filled animated glyph and the
// tag is small static text. One honest gap: a session whose cwd isn't a git
// repo has no tag, so its engine shows only in the card (and, until it is
// renamed or auto-titled, in the header label, which still falls back to the
// engine name).
import { useCallback, useEffect, useRef, useState } from "react";
import { tabDisplayLabel, type Engine, type TabInfo } from "../state/sessions";
import { deriveHoverCard } from "../state/sessionHoverCard";
import { useGitBranch } from "../lib/useGitBranch";
import { DEFAULT_TERMINAL_THEME, type TerminalThemeId } from "../lib/terminalThemes";
import PaneMenu from "./PaneMenu";
import SessionHoverCard from "./SessionHoverCard";
import SessionStatusLight from "./SessionStatusLight";

/** How long the pointer must rest on a pane header before its card appears.
 * Long enough that crossing the header on the way to the close button never
 * summons it, short enough that deliberately pointing at a pane feels
 * answered. Closing is immediate — a card that lingers is in the way. */
export const HOVER_CARD_DELAY_MS = 320;

interface PaneHeaderProps {
  tab: TabInfo;
  projectLabel: string;
  isFocused: boolean;
  onFocus: () => void;
  onClose: () => void;
  onSplit: () => void;
  onRename: (label: string) => void;
  /** 3-dot menu (founder ask): "Change engine" kills this pane's live
   * session and spawns a new one with a different engine, same pane/slot —
   * `App.tsx`'s `restartTabWithEngine` owns the actual kill+respawn.
   * Optional so any test/caller that doesn't care about the menu (most of
   * `PaneHeader.test.tsx`'s existing coverage) doesn't have to pass it. */
  onChangeEngine?: (engine: Engine) => void;
  /** 3-dot menu's "Terminal theme" picker — applied and persisted
   * immediately on click (`App.tsx`'s `tab/themeChanged` dispatch). */
  onChangeTheme?: (themeId: TerminalThemeId) => void;
}

/** Stops the click from also bubbling into the header's own
 * `onMouseDown={onFocus}` twice and — more importantly — keeps mousedown
 * from reaching react-mosaic's connected drag source on this element, so
 * pressing a button/input never kicks off a pane drag. */
function stopForDrag(e: React.MouseEvent) {
  e.stopPropagation();
}

export default function PaneHeader({
  tab,
  projectLabel,
  isFocused,
  onFocus,
  onClose,
  onSplit,
  onRename,
  onChangeEngine,
  onChangeTheme,
}: PaneHeaderProps) {
  const branch = useGitBranch(tab.cwd);
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState("");
  const [menuOpen, setMenuOpen] = useState(false);

  // ---- hover card -------------------------------------------------------
  // `cardAnchor` doubles as "is the card open": it holds the header rect
  // measured at open time, which is what the fixed-position card is placed
  // from (see SessionHoverCard's own doc for why fixed).
  const headerRef = useRef<HTMLDivElement>(null);
  const [cardAnchor, setCardAnchor] = useState<DOMRect | null>(null);
  const openTimer = useRef<number | null>(null);

  const closeCard = useCallback(() => {
    if (openTimer.current !== null) {
      window.clearTimeout(openTimer.current);
      openTimer.current = null;
    }
    setCardAnchor(null);
  }, []);

  // Clears a pending open timer if the pane closes (or the grid remounts it)
  // mid-hover, so a card never appears for a session that's gone.
  useEffect(() => () => closeCard(), [closeCard]);

  function scheduleCard() {
    if (openTimer.current !== null) return;
    openTimer.current = window.setTimeout(() => {
      openTimer.current = null;
      setCardAnchor(headerRef.current?.getBoundingClientRect() ?? null);
    }, HOVER_CARD_DELAY_MS);
  }

  function startRename() {
    closeCard();
    setDraft(tabDisplayLabel(tab));
    setRenaming(true);
  }

  function commitRename() {
    onRename(draft);
    setRenaming(false);
  }

  // The card is suppressed while renaming or while the 3-dot menu is open —
  // both are real interactions with this header, and a popover drifting in
  // over them would be noise, not information.
  const cardVisible = cardAnchor !== null && !renaming && !menuOpen;

  return (
    <div
      ref={headerRef}
      className={`pane-header${isFocused ? " is-focused" : ""}${tab.needsAttention ? " has-attention" : ""}`}
      onMouseDown={() => {
        // Also the start of a pane-rearrange drag (this whole element is
        // react-mosaic's drag handle) — a card hanging around mid-drag would
        // follow nothing.
        closeCard();
        onFocus();
      }}
      onMouseEnter={scheduleCard}
      onMouseLeave={closeCard}
    >
      {/* The five-state light: the OmniAgent mark, tinted and animated by
          this session's live status. Replaced the engine-coloured dot that
          used to sit here — engine identity moved to the session tag's tint
          and to the hover card's footer, see this file's module doc. */}
      <SessionStatusLight status={tab.status} />
      {tab.needsAttention && (
        <span
          className="pane-header-attention-dot"
          role="status"
          aria-label={`${tabDisplayLabel(tab)} needs your attention`}
          title="Needs your attention"
        />
      )}
      {renaming ? (
        <input
          className="pane-header-rename-input"
          value={draft}
          autoFocus
          draggable={false}
          size={Math.max(4, draft.length || 1)}
          onMouseDown={stopForDrag}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={commitRename}
          onKeyDown={(e) => {
            e.stopPropagation();
            if (e.key === "Enter") {
              e.preventDefault();
              commitRename();
            } else if (e.key === "Escape") {
              e.preventDefault();
              setRenaming(false);
            }
          }}
        />
      ) : (
        <span className="pane-header-label" onDoubleClick={startRename} title="Double-click to rename">
          <span className="pane-header-label-text">{tabDisplayLabel(tab)}</span>{" "}
          <span className="pane-header-project">· {projectLabel}</span>
        </span>
      )}
      <span className="pane-header-spacer" />
      {/* The session's branch tag (founder ask, 2026-07-26, verbatim:
          "terminal title has a dropdown with main, remove it. This must be
          connected to the session as a tag, that must be tied to the current
          git branch"). Same live `git_branch` data as the pill it replaces —
          what changed is that it no longer *looks* like a control: squared
          off instead of a capsule, no hover/pointer affordance, no tooltip
          promising a menu, and tinted with this session's engine colour so
          the tag reads as belonging to the session rather than as something
          to click. */}
      {branch && (
        <span className="pane-header-tag" data-engine={tab.engine} aria-label={`Branch ${branch}`}>
          <span className="pane-header-tag-glyph" aria-hidden="true">
            ⑂
          </span>
          {branch}
        </span>
      )}
      {(onChangeEngine || onChangeTheme) && (
        <span className="pane-header-menu-anchor">
          <button
            className={`pane-header-btn pane-header-btn-menu${menuOpen ? " is-active" : ""}`}
            draggable={false}
            onMouseDown={stopForDrag}
            onClick={() => {
              closeCard();
              setMenuOpen((open) => !open);
            }}
            aria-label={`${tabDisplayLabel(tab)} options`}
            aria-haspopup="menu"
            aria-expanded={menuOpen}
            title="Terminal options"
          >
            &#8942;
          </button>
          {menuOpen && (
            <PaneMenu
              currentEngine={tab.engine}
              currentThemeId={tab.themeId ?? DEFAULT_TERMINAL_THEME}
              onChangeEngine={(engine) => onChangeEngine?.(engine)}
              onChangeTheme={(themeId) => onChangeTheme?.(themeId)}
              onClose={() => setMenuOpen(false)}
            />
          )}
        </span>
      )}
      <button
        className="pane-header-btn"
        draggable={false}
        onMouseDown={stopForDrag}
        onClick={onSplit}
        aria-label={`New terminal in ${projectLabel}`}
        title="New terminal in this project"
      >
        +
      </button>
      <button
        className="pane-header-btn pane-header-btn-close"
        draggable={false}
        onMouseDown={stopForDrag}
        onClick={onClose}
        aria-label={`Close ${tabDisplayLabel(tab)}`}
        title="Close"
      >
        ×
      </button>
      {cardVisible && (
        <SessionHoverCard model={deriveHoverCard({ tab, projectLabel, branch })} anchor={cardAnchor} />
      )}
    </div>
  );
}

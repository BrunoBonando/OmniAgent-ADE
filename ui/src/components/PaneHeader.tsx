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
// 3. *"on hover, it explains, of course"* — the status light explains
//    itself on hover, and that is the only popover this header has.
//
// ## The status light left, then came straight back — bigger (2026-07-26)
//
// Bruno first asked to drop it for the animated pane border, then: "where's
// the omniagent logo from the terminal title that changes its color
// according to the status? it should be bigger and now it's gone!" So the
// OmniAgent mark is back at the head of the bar, up from its old 15px to
// 20px. Only the title-bar STRIP animation stayed gone — the border
// (`Workspace.tsx`'s `pane-status-*` classes) still carries the full-pane
// rendering of the same fact.
//
// ## The hover card left this header (2026-07-26, later the same day)
//
// It briefly lived here too: resting on the header opened a `SessionHoverCard`
// carrying the status sentence and the session's facts. Bruno, on seeing it:
// *"The hover part is currently wrong: it's not on the terminal itself, but
// on session menu on the left."* It now hangs off the sidebar's session row
// (`SidebarSessionRow.tsx`), scoped to the whole session rather than to one
// terminal, and this header keeps only the light's own tooltip — which is a
// different, deliberate affordance, and the one thing here that genuinely
// describes this single pane.
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
//
// ## The tag is the AGENT now, not the branch (2026-07-26, latest round)
//
// Bruno: *"the current tag with the branch name should be replaced by the
// name of the agent, with their respective colors and strong. exactly the
// same way it shows the branch, but actually the name of the agent. And
// where it currently holds the agent name should be removed."* So the tag
// keeps its exact shape and its engine tint — what changed is the words in
// it — and the `· Claude Code` suffix that used to trail the header label is
// gone, because it was the same fact printed twice. Two things follow: this
// header no longer reads git at all (`useGitBranch` left with the branch),
// and the tag is now unconditional — every pane has an engine, where only a
// pane inside a repo had a branch.
import { useEffect, useState } from "react";
import { tabDisplayLabel, type Engine, type TabInfo } from "../state/sessions";
import { DEFAULT_TERMINAL_THEME, type TerminalThemeId } from "../lib/terminalThemes";
import { reviewStatus, type ReviewStatus } from "../lib/tauri";
import { ENGINE_LABEL } from "../theme";
import PaneMenu from "./PaneMenu";
import SessionStatusLight from "./SessionStatusLight";
import Icon from "./Icon";

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
  /** 3-dot menu's "Code review" entry (founder ask, 2026-07-26): opens the
   * right-hand review column scoped to THIS pane's cwd. Optional, like the
   * two above, so tests that don't care about the menu can omit it. */
  onOpenCodeReview?: () => void;
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
  onOpenCodeReview,
}: PaneHeaderProps) {
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState("");
  const [menuOpen, setMenuOpen] = useState(false);
  const [reviewSummary, setReviewSummary] = useState<ReviewStatus | null>(null);

  useEffect(() => {
    if (!onOpenCodeReview || !tab.cwd) {
      setReviewSummary(null);
      return;
    }
    let cancelled = false;
    reviewStatus(tab.cwd)
      .then((status) => {
        if (!cancelled) setReviewSummary(status);
      })
      .catch(() => {
        // "Not in a git repo" is common and not worth surfacing here.
        if (!cancelled) setReviewSummary(null);
      });
    return () => {
      cancelled = true;
    };
  }, [onOpenCodeReview, tab.cwd]);

  function startRename() {
    setDraft(tabDisplayLabel(tab));
    setRenaming(true);
  }

  function commitRename() {
    onRename(draft);
    setRenaming(false);
  }

  return (
    <div
      // The `has-attention` red border is gone with `needsAttention` itself
      // (2026-07-26): `awaiting_approval` breathes amber and `error` flashes
      // red in the light below, which is the same fact in the language the
      // rest of the app now uses. See `state/sessions.ts`'s `TabInfo` doc.
      className={`pane-header${isFocused ? " is-focused" : ""}`}
      onMouseDown={onFocus}
    >
      {/* The five-state light: the OmniAgent mark, tinted and animated by
          this session's live status. Bigger than the sidebar's 15px — the
          header is where Bruno actually reads it. */}
      <SessionStatusLight status={tab.status} size={20} />
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
          <span className="pane-header-label-text">{tabDisplayLabel(tab)}</span>
        </span>
      )}
      <span className="pane-header-spacer" />
      {/* The pane's AGENT tag — the branch tag's exact shape and engine tint,
          now saying which agent is running here (see the module doc). Still
          not a control: no hover affordance, no tooltip promising a menu. */}
      <span className="pane-header-tag" data-engine={tab.engine} aria-label={`Agent ${ENGINE_LABEL[tab.engine]}`}>
        {ENGINE_LABEL[tab.engine]}
      </span>
      {onOpenCodeReview && reviewSummary && (
        <button
          className="pane-header-review"
          draggable={false}
          onMouseDown={stopForDrag}
          onClick={onOpenCodeReview}
          title={`${reviewSummary.file_count} uncommitted changes (+${reviewSummary.added} -${reviewSummary.removed})`}
          aria-label={`${reviewSummary.file_count} uncommitted changes (+${reviewSummary.added} -${reviewSummary.removed})`}
        >
          <span className="pane-header-review-count">{reviewSummary.file_count}</span>
          <span className="pane-header-review-add">+{reviewSummary.added}</span>
          <span className="pane-header-review-del">-{reviewSummary.removed}</span>
        </button>
      )}
      {(onChangeEngine || onChangeTheme || onOpenCodeReview) && (
        <span className="pane-header-menu-anchor">
          <button
            className={`pane-header-btn pane-header-btn-menu${menuOpen ? " is-active" : ""}`}
            draggable={false}
            onMouseDown={stopForDrag}
            onClick={() => setMenuOpen((open) => !open)}
            aria-label={`${tabDisplayLabel(tab)} options`}
            aria-haspopup="menu"
            aria-expanded={menuOpen}
            title="Terminal options"
          >
            <Icon name="more" size={16} />
          </button>
          {menuOpen && (
            <PaneMenu
              currentEngine={tab.engine}
              currentThemeId={tab.themeId ?? DEFAULT_TERMINAL_THEME}
              onChangeEngine={(engine) => onChangeEngine?.(engine)}
              onChangeTheme={(themeId) => onChangeTheme?.(themeId)}
              repoPath={tab.cwd}
              onOpenCodeReview={onOpenCodeReview}
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
        <Icon name="plus" size={15} />
      </button>
      <button
        className="pane-header-btn pane-header-btn-close"
        draggable={false}
        onMouseDown={stopForDrag}
        onClick={onClose}
        aria-label={`Close ${tabDisplayLabel(tab)}`}
        title="Close"
      >
        <Icon name="x" size={14} strokeWidth={2.1} />
      </button>
    </div>
  );
}

// One pane's header bar in the terminal grid (BridgeSpace pane-grid
// rebuild — see docs/DESIGN.md and the founder's reference screenshot at
// docs/reference/bridgespace-pane-grid-reference.png). Re-houses every real
// feature `TabBar.tsx`'s pill used to own (engine dot, rename-on-dblclick,
// attention badge, close button — all from prior feedback-round work, none
// dropped here) plus two things the reference added: a git-branch pill and
// a per-pane "+" (split) button. `Workspace.tsx` renders one of these per
// `react-mosaic-component` tile via `MosaicWindow`'s `renderToolbar` — see
// that file's module doc for why the whole returned element becomes the
// drag handle, and why the rename input / branch pill / buttons below all
// set `draggable={false}` (or stop the mousedown) so grabbing them doesn't
// also start a pane-rearrange drag.
import { useState } from "react";
import { tabDisplayLabel, type TabInfo } from "../state/sessions";
import { ENGINE_COLOR } from "../theme";
import { useGitBranch } from "../lib/useGitBranch";

interface PaneHeaderProps {
  tab: TabInfo;
  projectLabel: string;
  isFocused: boolean;
  onFocus: () => void;
  onClose: () => void;
  onSplit: () => void;
  onRename: (label: string) => void;
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
}: PaneHeaderProps) {
  const branch = useGitBranch(tab.cwd);
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState("");

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
      className={`pane-header${isFocused ? " is-focused" : ""}${tab.needsAttention ? " has-attention" : ""}`}
      onMouseDown={onFocus}
    >
      <span className="pane-header-dot" style={{ background: ENGINE_COLOR[tab.engine] }} aria-hidden="true" />
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
      {branch && (
        <span className="pane-header-branch" title={`git branch: ${branch}`}>
          ⑂ {branch}
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
    </div>
  );
}

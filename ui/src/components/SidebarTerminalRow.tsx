// One terminal (pane/PTY) inside an expanded sidebar session (Task 5 of the
// left-pane redesign): engine glyph, display label, and the masked-logo
// status mark — the same `SessionStatusLight` the pane header uses, at 12px,
// `decorative` because this row already prints the label as visible text (no
// tooltip-only status like `SidebarSessionRow`'s dot cluster, which has no
// text equivalent).
//
// A real `<button>`, not a `role="button"` div: every other clickable row in
// this sidebar (`.session-row-main`, `.session-row-chevron`,
// `.session-row-close`, `.sidebar-sessions-add`) is a native button so
// Tab/Enter/Space work without hand-rolled key handling, and this row
// matches that. Its accessible name is left to compute naturally from
// content — the engine glyph (`Icon` is `aria-hidden` itself) and the status
// light (`decorative` -> `aria-hidden`) both drop out of that computation, so
// only `.terminal-row-label`'s text ever reaches it. Nothing here nests a
// second labelled control the way Task 4's dot cluster did, so there is no
// leakage to guard against.
import type { TabInfo } from "../state/sessions";
import { tabDisplayLabel } from "../state/sessions";
import { AGENT_ICON, ENGINE_COLOR } from "../theme";
import Icon from "./Icon";
import SessionStatusLight from "./SessionStatusLight";

interface SidebarTerminalRowProps {
  tab: TabInfo;
  /** This pane is the focused pane in the grid. */
  isActive: boolean;
  /** Activate this tab (and its session's grid). */
  onActivate: () => void;
}

export function SidebarTerminalRow({ tab, isActive, onActivate }: SidebarTerminalRowProps) {
  return (
    <button
      type="button"
      className={`terminal-row${isActive ? " is-active" : ""}`}
      onClick={onActivate}
    >
      <span className="terminal-row-engine" style={{ color: ENGINE_COLOR[tab.engine] }} aria-hidden>
        <Icon name={AGENT_ICON[tab.engine]} size={11} />
      </span>
      <span className="terminal-row-label">{tabDisplayLabel(tab)}</span>
      <SessionStatusLight status={tab.status} size={12} decorative />
    </button>
  );
}

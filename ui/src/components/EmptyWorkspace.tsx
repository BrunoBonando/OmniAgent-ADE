// What a workspace with no terminals in it looks like (founder brief,
// 2026-07-26, verbatim: *"in the case of no terminals open in a session,
// show a nice black gradient dark blue background with a window in the
// middle that asks the user what they want to achieve today. and it shows
// the layout options, so it can create (similar to the new session
// flow)"*). It replaces the old `>_ / No terminal open. / ⌘T to start one`
// text block — same slot, same absolute-fill container, now a real front
// door rather than a hint.
//
// "Similar to the new session flow" is taken literally, the way
// `NewChooserModal` already took it: this is `NewSessionModal`'s LAYOUT
// section — the same cards, the same glyph (imported from there, not
// re-drawn), the same caption-under-the-row — inside the same
// `.new-workspace-panel` window, so the empty state reads as the first step
// of the flow the user already knows instead of a second way to start a
// session.
//
// What it deliberately does NOT carry over from that dialog: the folder
// picker and the AI-agents checklist. This is the zero-decision path —
// the project's own folder, the project's default engine (the same
// per-project-else-global-else-claude chain ⌘T resolves), one pane per slot
// in the chosen layout. Anyone who wants a subfolder or a specific mix of
// engines still has ⌘N -> Session, which is exactly what that dialog is
// for.
//
// The goal the user types becomes the SESSION'S NAME (App.tsx's
// `handleQuickStart` -> `handleSessionCreated`'s `name`), so "ship the
// checkout fix" shows up in the sidebar instead of "Session 3".
// ponytail: it is not typed into the agent's prompt — a write racing a
// just-spawned CLI's TUI silently drops characters. If seeding the agent
// itself is wanted later, do it at spawn time in `sessions.rs`
// (`session_create` already carries claude's briefing that way), not with a
// post-spawn `session_write`.
import { useState } from "react";
import { LayoutGlyph } from "./NewSessionModal";
import { LAYOUT_PRESETS, layoutCaption, type LayoutPreset } from "../state/paneGrid";
import type { ProjectInfo } from "../state/sessions";

interface EmptyWorkspaceProps {
  /** The selected workspace this would start a session in — `null` only on
   * an install with no projects at all, which gets the hint instead of the
   * form (there is nowhere to put the panes). */
  project: ProjectInfo | null;
  onStart: (project: ProjectInfo, layout: LayoutPreset, goal: string) => void;
}

export default function EmptyWorkspace({ project, onStart }: EmptyWorkspaceProps) {
  // Same default as `newSessionState.ts`'s `initialNewSessionStateFor` — a
  // side-by-side pair. Written literally, not as `LAYOUT_PRESETS[0]`: the
  // list now starts at the single-terminal preset, and this default is "2",
  // not "whatever happens to be first".
  const [layout, setLayout] = useState<LayoutPreset>(2);
  const [goal, setGoal] = useState("");

  if (project === null) {
    return (
      <div className="empty-workspace">
        <p>No workspace open.</p>
        <p className="empty-workspace-hint">Add a project (+ in the sidebar) to start one.</p>
      </div>
    );
  }

  return (
    <div className="empty-workspace">
      <form
        className="new-workspace-panel empty-workspace-panel"
        onSubmit={(e) => {
          e.preventDefault();
          onStart(project, layout, goal.trim());
        }}
      >
        <h2 className="new-workspace-title empty-workspace-question">
          What do you want to achieve today?
        </h2>
        <p className="empty-workspace-sub">
          in <strong>{project.label}</strong>
        </p>

        <div className="new-workspace-section">
          {/* Unlabelled on purpose: the heading above it is the label. */}
          <input
            className="new-workspace-name-input"
            value={goal}
            onChange={(e) => setGoal(e.target.value)}
            placeholder="Ship the checkout fix…"
            aria-label="What do you want to achieve today?"
            autoFocus
          />
        </div>

        <div className="new-workspace-section">
          <span className="new-workspace-section-label">LAYOUT</span>
          <div className="new-workspace-layout-row">
            {LAYOUT_PRESETS.map((preset) => (
              <button
                key={preset}
                type="button"
                className={`new-workspace-layout-card${layout === preset ? " is-selected" : ""}`}
                onClick={() => setLayout(preset)}
                aria-pressed={layout === preset}
              >
                <LayoutGlyph preset={preset} />
                <span className="new-workspace-layout-number">{preset}</span>
              </button>
            ))}
          </div>
          <p className="new-workspace-layout-caption">{layoutCaption(layout)}</p>
        </div>

        <div className="new-workspace-footer">
          <span className="empty-workspace-keys">&#8629; start</span>
          <button type="submit" className="new-workspace-submit">
            Start session
          </button>
        </div>
      </form>
    </div>
  );
}

// The sidebar's top control (design ANALYSIS.md §2 "Workspace switcher"):
// active workspace identity + the trigger for WorkspaceMenu. The sidebar
// shows exactly one workspace at a time; this is how you leave it.
//
// It replaces the old `.project-list` — a row per open project, every one of
// them carrying its own sessions — which is why the fallback below is a real
// state and not a defensive `?.`: with no projects at all there is nothing to
// select, and "No workspace / choose or add one" is what the button says
// while the menu it opens is the only way out of that.
import type { ProjectInfo } from "../state/sessions";
import { idColor } from "../state/projectColors";

export interface WorkspaceSwitcherProps {
  project: ProjectInfo | null;
  /** Menu open — highlights the control so it reads as "this is the thing
   * the dropdown belongs to". */
  open: boolean;
  onToggle: () => void;
}

export function WorkspaceSwitcher({ project, open, onToggle }: WorkspaceSwitcherProps) {
  return (
    <button
      type="button"
      className={`workspace-switcher${open ? " is-open" : ""}`}
      onClick={onToggle}
      aria-haspopup="menu"
      aria-expanded={open}
      title={project?.path ?? "Choose or add a workspace"}
    >
      {/* Inline background, like every other avatar in this sidebar: the
          colour is derived per-instance from a hash of the id, so it can't be
          a class (see `state/projectColors.ts`). */}
      <span
        className="workspace-switcher-avatar"
        style={{ background: project ? idColor(project.id) : "rgba(255,255,255,.12)" }}
        aria-hidden
      >
        {project ? project.label.slice(0, 1).toUpperCase() : "?"}
      </span>
      <span className="workspace-switcher-identity">
        <span className="workspace-switcher-name">{project?.label ?? "No workspace"}</span>
        <span className="workspace-switcher-path">{project?.path ?? "choose or add one"}</span>
      </span>
      <span className="workspace-switcher-microlabel">WORKSPACE</span>
      <span className="workspace-switcher-chevrons" aria-hidden>
        ⌃⌄
      </span>
    </button>
  );
}

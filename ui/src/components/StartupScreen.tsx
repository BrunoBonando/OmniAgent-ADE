import { useRef, type KeyboardEvent } from "react";
import type { ProjectInfo } from "../state/sessions";
import { idColor } from "../state/projectColors";

interface StartupScreenProps {
  loading: boolean;
  projects: ProjectInfo[];
  onSelectWorkspace: (project: ProjectInfo) => void;
  onStartFromScratch: () => void;
}

export default function StartupScreen({
  loading,
  projects,
  onSelectWorkspace,
  onStartFromScratch,
}: StartupScreenProps) {
  const choices = useRef<(HTMLButtonElement | null)[]>([]);

  const moveFocus = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    const offset = event.key === "ArrowRight" ? 1 : -1;
    const next = (index + offset + projects.length + 1) % (projects.length + 1);
    choices.current[next]?.focus();
  };

  return (
    <main className={`startup-screen${loading ? " is-loading" : " is-ready"}`}>
      <div className="startup-brand" aria-live="polite">
        <span className="startup-logo" aria-hidden />
        {!loading && <h1>OmniAgent</h1>}
        {loading && <p className="startup-loading">Loading…</p>}
      </div>

      {!loading && (
        <section className="startup-chooser" aria-labelledby="startup-title">
          <h2 id="startup-title">Choose your workspace</h2>
          <div className="startup-workspaces">
            <button
              ref={(node) => {
                choices.current[0] = node;
              }}
              type="button"
              className="startup-workspace-card is-new"
              onClick={onStartFromScratch}
              onKeyDown={(event) => moveFocus(event, 0)}
            >
              <span className="startup-new-mark" aria-hidden>
                +
              </span>
              <span>
                <strong>Start from scratch</strong>
                <small>Create or choose a project folder</small>
              </span>
            </button>
            {projects.map((project, index) => (
              <button
                ref={(node) => {
                  choices.current[index + 1] = node;
                }}
                key={project.id}
                type="button"
                className="startup-workspace-card"
                onClick={() => onSelectWorkspace(project)}
                onKeyDown={(event) => moveFocus(event, index + 1)}
              >
                <span
                  className="startup-workspace-avatar"
                  style={{ backgroundColor: idColor(project.id) }}
                  aria-hidden
                >
                  {project.label.slice(0, 1).toUpperCase()}
                </span>
                <span>
                  <strong>{project.label}</strong>
                  <small>{project.path ?? "Folder unavailable"}</small>
                </span>
                <span className="startup-workspace-arrow" aria-hidden>
                  →
                </span>
              </button>
            ))}
          </div>
        </section>
      )}
    </main>
  );
}

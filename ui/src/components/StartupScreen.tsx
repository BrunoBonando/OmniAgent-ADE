import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import type { ProjectInfo } from "../state/sessions";
import { idColor } from "../state/projectColors";
import SessionStatusLight from "./SessionStatusLight";
import Icon from "./Icon";

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
  const [showLoadingOverlay, setShowLoadingOverlay] = useState(loading);
  const loadingShownAtRef = useRef<number | null>(loading ? Date.now() : null);
  const MIN_LOADING_MS = 3000;
  const EXIT_ANIMATION_MS = 260;

  const moveFocus = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    const offset = event.key === "ArrowRight" ? 1 : -1;
    const next = (index + offset + projects.length + 1) % (projects.length + 1);
    choices.current[next]?.focus();
  };

  useEffect(() => {
    if (loading) {
      if (loadingShownAtRef.current === null) loadingShownAtRef.current = Date.now();
      setShowLoadingOverlay(true);
      return;
    }
    const shownAt = loadingShownAtRef.current;
    const elapsed = shownAt === null ? MIN_LOADING_MS : Date.now() - shownAt;
    const waitForMinimum = Math.max(0, MIN_LOADING_MS - elapsed);
    const timeout = window.setTimeout(() => {
      setShowLoadingOverlay(false);
      loadingShownAtRef.current = null;
    }, Math.max(EXIT_ANIMATION_MS, waitForMinimum));
    return () => window.clearTimeout(timeout);
  }, [loading]);

  return (
    <main className={`startup-screen${loading ? " is-loading" : " is-ready"}`}>
      <div className="startup-content" aria-hidden={loading ? true : undefined}>
        <div className="startup-brand" aria-live="polite">
          <span className="startup-logo" aria-hidden />
          <h1>OmniAgent</h1>
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
                  <Icon name="plus" size={20} />
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
      </div>

      {showLoadingOverlay && (
        <div
          className={`startup-loading-overlay${loading ? "" : " is-exiting"}`}
          role="status"
          aria-live="polite"
        >
          <div className="startup-loading-modal">
            <SessionStatusLight status="tool_execution" size={112} decorative />
            <p className="startup-loading">Loading...</p>
          </div>
        </div>
      )}
    </main>
  );
}

// Project list (Task 5.2): `brain_query{kind:"list_projects"}` -> brain-core
// Store::list_projects() directly, no daemon round trip. Renders a real,
// non-broken empty state when the brain has nothing ingested yet — the
// common case on a fresh dev run.
import { useState } from "react";
import logo from "../assets/omniagent-logo.png";
import { PRESSURE_THRESHOLD, isUnderPressure, tabsByProject, type ProjectInfo, type TabInfo } from "../state/sessions";
import AboutPanel from "./AboutPanel";
import ReviewPanel from "./ReviewPanel";

interface SidebarProps {
  projects: ProjectInfo[];
  tabs: TabInfo[];
  activeTabId: string | null;
  selectedProjectId: string | null;
  onSelectProject: (project: ProjectInfo) => void;
  onNewTabInProject: (project: ProjectInfo) => void;
  onActivateTab: (id: string) => void;
  /** Task 6.2: the workspace/map view toggle. Optional so this component
   * still type-checks for any test that doesn't care about it. */
  view?: "workspace" | "map";
  onSetView?: (view: "workspace" | "map") => void;
}

export default function Sidebar({
  projects,
  tabs,
  activeTabId,
  selectedProjectId,
  onSelectProject,
  onNewTabInProject,
  onActivateTab,
  view = "workspace",
  onSetView,
}: SidebarProps) {
  const [aboutOpen, setAboutOpen] = useState(false);
  const [reviewOpen, setReviewOpen] = useState(false);
  const grouped = tabsByProject(tabs);
  const sessionCountByProject = new Map(grouped.map((g) => [g.project, g.tabs.length]));
  const underPressure = isUnderPressure(tabs);

  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        <span className="sidebar-wordmark">OMNIAGENT</span>
        <span
          className={`pressure-badge${underPressure ? " is-hot" : ""}`}
          title={`${tabs.length} live session${tabs.length === 1 ? "" : "s"} (pressure badge past ${PRESSURE_THRESHOLD})`}
        >
          {tabs.length}/{PRESSURE_THRESHOLD}
        </span>
      </div>

      <div className="sidebar-view-toggle" role="tablist" aria-label="View">
        <button
          role="tab"
          aria-selected={view === "workspace"}
          className={view === "workspace" ? "is-active" : ""}
          onClick={() => onSetView?.("workspace")}
          title="Terminal workspace"
        >
          &gt;_ Workspace
        </button>
        <button
          role="tab"
          aria-selected={view === "map"}
          className={view === "map" ? "is-active" : ""}
          onClick={() => onSetView?.("map")}
          title="Brain map"
        >
          &#10022; Map
        </button>
      </div>

      <div className="sidebar-projects">
        {projects.length === 0 ? (
          <div className="sidebar-empty">
            <img src={logo} alt="" className="sidebar-empty-logo" />
            <p className="sidebar-empty-title">No projects ingested yet</p>
            <p className="sidebar-empty-hint">
              Run <code>brain ingest &lt;folder&gt;</code> to point the brain at your projects,
              then relaunch — the sidebar fills in automatically.
            </p>
          </div>
        ) : (
          <ul className="project-list">
            {projects.map((project) => {
              const count = sessionCountByProject.get(project.id) ?? 0;
              const isSelected = project.id === selectedProjectId;
              return (
                <li key={project.id} className={`project-row${isSelected ? " is-selected" : ""}`}>
                  <button
                    className="project-row-main"
                    onClick={() => onSelectProject(project)}
                    title={project.path ?? project.id}
                  >
                    <span className="project-row-label">{project.label}</span>
                    {count > 0 && <span className="project-row-count">{count}</span>}
                  </button>
                  <button
                    className="project-row-add"
                    onClick={() => onNewTabInProject(project)}
                    aria-label={`New terminal in ${project.label}`}
                    title="New terminal (⌘T)"
                  >
                    +
                  </button>
                  {count > 0 && (
                    <ul className="project-row-tabs">
                      {grouped
                        .find((g) => g.project === project.id)!
                        .tabs.map((tab) => (
                          <li key={tab.id}>
                            <button
                              className={`project-row-tab${tab.id === activeTabId ? " is-active" : ""}`}
                              onClick={() => onActivateTab(tab.id)}
                            >
                              {tab.engine}
                            </button>
                          </li>
                        ))}
                    </ul>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </div>

      <div className="sidebar-footer">
        <span className="sidebar-hint">⌘K search &nbsp;·&nbsp; ⌘T new tab</span>
        <span className="sidebar-footer-triggers">
          <button
            className="sidebar-about-trigger"
            onClick={() => setReviewOpen(true)}
            aria-label="Review session summaries"
            title="Review session summaries"
          >
            ✓
          </button>
          <button className="sidebar-about-trigger" onClick={() => setAboutOpen(true)} aria-label="About OmniAgent ADE">
            i
          </button>
        </span>
      </div>

      {aboutOpen && <AboutPanel onClose={() => setAboutOpen(false)} />}
      {reviewOpen && <ReviewPanel onClose={() => setReviewOpen(false)} />}
    </aside>
  );
}

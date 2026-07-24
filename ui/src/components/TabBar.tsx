// Terminal tabs, grouped per project (Task 5.2). Each tab renders as a
// "channel strip": a left edge colored by engine + a small activity dot —
// the signature element tying the tab affordance to Bruno's actual
// hardware-mixer mental model (see the frontend-design pass notes), and a
// genuine legibility win once more than a couple of tabs are open.
import { PRESSURE_THRESHOLD, isUnderPressure, tabsByProject, type ProjectInfo, type TabInfo } from "../state/sessions";
import { ENGINE_COLOR } from "../theme";

interface TabBarProps {
  projects: ProjectInfo[];
  tabs: TabInfo[];
  activeTabId: string | null;
  onActivateTab: (id: string) => void;
  onCloseTab: (id: string) => void;
  onNewTabInProject: (project: ProjectInfo) => void;
}

export default function TabBar({
  projects,
  tabs,
  activeTabId,
  onActivateTab,
  onCloseTab,
  onNewTabInProject,
}: TabBarProps) {
  const grouped = tabsByProject(tabs);
  const projectLabel = (id: string) => projects.find((p) => p.id === id)?.label ?? id;
  const underPressure = isUnderPressure(tabs);

  return (
    <div className="tab-bar-wrap">
      {underPressure && (
        <div className="pressure-warning" role="status">
          {tabs.length} live sessions open — past the {PRESSURE_THRESHOLD}-session comfort line. Consider
          closing a few before opening more.
        </div>
      )}
      <div className="tab-bar">
        {grouped.length === 0 ? (
          <div className="tab-bar-empty">No terminals open — ⌘T to start one.</div>
        ) : (
          grouped.map((group) => (
            <div className="tab-bar-group" key={group.project}>
              <span className="tab-bar-group-label">{projectLabel(group.project)}</span>
              <div className="tab-bar-group-tabs">
                {group.tabs.map((tab) => (
                  <div
                    key={tab.id}
                    className={`tab-pill${tab.id === activeTabId ? " is-active" : ""}`}
                    style={{ borderLeftColor: ENGINE_COLOR[tab.engine] }}
                    onClick={() => onActivateTab(tab.id)}
                  >
                    <span className="tab-pill-dot" style={{ background: ENGINE_COLOR[tab.engine] }} />
                    <span className="tab-pill-label">{tab.engine}</span>
                    <button
                      className="tab-pill-close"
                      onClick={(e) => {
                        e.stopPropagation();
                        onCloseTab(tab.id);
                      }}
                      aria-label={`Close ${tab.engine} tab in ${projectLabel(tab.project)}`}
                    >
                      ×
                    </button>
                  </div>
                ))}
                <button
                  className="tab-bar-add"
                  onClick={() => onNewTabInProject(projects.find((p) => p.id === group.project)!)}
                  aria-label={`New terminal in ${projectLabel(group.project)}`}
                  title="New terminal (⌘T)"
                >
                  +
                </button>
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}

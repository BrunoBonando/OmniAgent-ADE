// The Phase 5 terminal workspace (TabBar + terminal area), lifted out of
// `App.tsx` per that file's own Phase 6 integration note: `<App>` now
// switches between this and `<BrainMap>`. Rendered by `App.tsx` with CSS-only
// visibility (`hidden` -> `display: none`), never unmounted, for the same
// reason each `<Terminal>` inside it already stays mounted across tab
// switches — the Rust side streams `session-output:{id}` events to whoever
// is listening right now, and unmounting would silently drop output printed
// while the workspace view isn't the active one.
import TabBar from "./TabBar";
import Terminal from "./Terminal";
import type { ProjectInfo, TabInfo } from "../state/sessions";

interface WorkspaceProps {
  projects: ProjectInfo[];
  tabs: TabInfo[];
  activeTabId: string | null;
  selectedProjectLabel: string | undefined;
  onActivateTab: (id: string) => void;
  onCloseTab: (id: string) => void;
  onNewTabInProject: (project: ProjectInfo) => void;
  hidden: boolean;
}

export default function Workspace({
  projects,
  tabs,
  activeTabId,
  selectedProjectLabel,
  onActivateTab,
  onCloseTab,
  onNewTabInProject,
  hidden,
}: WorkspaceProps) {
  return (
    <div className="workspace" style={{ display: hidden ? "none" : "flex" }}>
      <TabBar
        projects={projects}
        tabs={tabs}
        activeTabId={activeTabId}
        onActivateTab={onActivateTab}
        onCloseTab={onCloseTab}
        onNewTabInProject={onNewTabInProject}
      />
      <div className="terminal-area">
        {tabs.map((tab) => (
          <Terminal key={tab.id} sessionId={tab.id} visible={tab.id === activeTabId} />
        ))}
        {tabs.length === 0 && (
          <div className="empty-workspace">
            <div className="empty-workspace-prompt">&gt;_</div>
            <p>No terminal open.</p>
            <p className="empty-workspace-hint">
              {projects.length === 0
                ? "Ingest a project, then press ⌘T."
                : `⌘T to start one in ${selectedProjectLabel ?? "the selected project"}.`}
            </p>
          </div>
        )}
      </div>
    </div>
  );
}

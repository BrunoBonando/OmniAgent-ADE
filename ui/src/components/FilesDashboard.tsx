import { useCallback, useEffect, useMemo, useState } from "react";
import * as tauri from "../lib/tauri";
import type { ProjectInfo } from "../state/sessions";

interface FileTab {
  path: string;
  name: string;
  content: string;
  savedContent: string;
  loading: boolean;
  error: string | null;
}

function fileName(path: string): string {
  const i = path.lastIndexOf("/");
  return i >= 0 ? path.slice(i + 1) : path;
}

interface FilesDashboardProps {
  project: ProjectInfo | null;
  hidden: boolean;
  openRequest: { path: string; nonce: number } | null;
}

export default function FilesDashboard({ project, hidden, openRequest }: FilesDashboardProps) {
  const [tabs, setTabs] = useState<FileTab[]>([]);
  const [activePath, setActivePath] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    setTabs([]);
    setActivePath(null);
    setNotice(null);
  }, [project?.id]);

  const openPath = useCallback(
    async (path: string) => {
      if (!project?.path) return;
      const existing = tabs.find((tab) => tab.path === path);
      if (existing) {
        setActivePath(path);
        return;
      }
      setActivePath(path);
      setTabs((prev) => [
        ...prev,
        { path, name: fileName(path), content: "", savedContent: "", loading: true, error: null },
      ]);
      try {
        const text = await tauri.readTextFile(project.path, path);
        setTabs((prev) =>
          prev.map((tab) =>
            tab.path === path ? { ...tab, content: text, savedContent: text, loading: false, error: null } : tab,
          ),
        );
      } catch (err) {
        setTabs((prev) =>
          prev.map((tab) =>
            tab.path === path
              ? { ...tab, loading: false, error: String(err), content: "", savedContent: "" }
              : tab,
          ),
        );
      }
    },
    [project?.path, tabs],
  );

  useEffect(() => {
    if (!openRequest) return;
    void openPath(openRequest.path);
  }, [openRequest, openPath]);

  const active = useMemo(
    () => (activePath ? tabs.find((tab) => tab.path === activePath) ?? null : null),
    [tabs, activePath],
  );
  const dirty = !!active && active.content !== active.savedContent;

  async function saveActive() {
    if (!active || !project?.path) return;
    try {
      await tauri.writeTextFile(project.path, active.path, active.content);
      setTabs((prev) =>
        prev.map((tab) => (tab.path === active.path ? { ...tab, savedContent: active.content } : tab)),
      );
      setNotice(`Saved ${active.name}`);
    } catch (err) {
      setNotice(`Couldn't save ${active.name}: ${String(err)}`);
    }
  }

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!event.metaKey || event.key.toLowerCase() !== "s") return;
      if (hidden || !active || active.loading || active.error) return;
      event.preventDefault();
      void saveActive();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [hidden, active, project?.path]);

  function closeTab(path: string) {
    setTabs((prev) => {
      const remain = prev.filter((tab) => tab.path !== path);
      setActivePath((prevActive) => (prevActive === path ? (remain[remain.length - 1]?.path ?? null) : prevActive));
      return remain;
    });
  }

  const lines = (active?.content ?? "").split("\n");

  return (
    <section className="dashboard-surface files-dashboard" style={{ display: hidden ? "none" : "flex" }}>
      <header className="dashboard-surface-header">
        <div>
          <h2>Files</h2>
          <p>{project ? project.path : "Select a workspace to edit files"}</p>
        </div>
        <div className="files-dashboard-actions">
          <button onClick={() => void saveActive()} disabled={!active || active.loading || !!active.error || !dirty}>
            Save
          </button>
          <span>⌘S</span>
        </div>
      </header>

      <div className="files-dashboard-tabs">
        {tabs.map((tab) => (
          <button
            key={tab.path}
            className={`files-dashboard-tab${tab.path === activePath ? " is-active" : ""}`}
            onClick={() => setActivePath(tab.path)}
          >
            <span>{tab.name}{tab.content !== tab.savedContent ? " •" : ""}</span>
            <span
              className="files-dashboard-tab-close"
              onClick={(e) => {
                e.stopPropagation();
                closeTab(tab.path);
              }}
            >
              ×
            </span>
          </button>
        ))}
      </div>

      {!project ? (
        <div className="dashboard-empty">Select a workspace and open a file from the left FILES tree.</div>
      ) : !active ? (
        <div className="dashboard-empty">Open a file from the left FILES tree to start editing.</div>
      ) : active.loading ? (
        <div className="dashboard-empty">Loading {active.name}…</div>
      ) : active.error ? (
        <div className="dashboard-empty">{active.error}</div>
      ) : (
        <div className="files-dashboard-editor-shell">
          <pre className="files-dashboard-gutter" aria-hidden>
            {lines.map((_, i) => i + 1).join("\n")}
          </pre>
          <textarea
            className="files-dashboard-editor"
            value={active.content}
            onChange={(e) =>
              setTabs((prev) =>
                prev.map((tab) => (tab.path === active.path ? { ...tab, content: e.target.value } : tab)),
              )
            }
            spellCheck={false}
          />
        </div>
      )}

      {notice && <div className="files-dashboard-notice">{notice}</div>}
    </section>
  );
}

// ⌘K command palette (PLAN.md Task 5.2): switch project/session, "New tab
// in <project>", "Search brain…". The brain search is intentionally a
// simple, read-only results list — Phase 6's map pane owns rich brain
// search/navigation; this just proves the retrieval path end-to-end.
import { useEffect, useMemo, useRef, useState } from "react";
import { searchBrain, type BrainSearchHit } from "../lib/tauri";
import type { ProjectInfo, TabInfo } from "../state/sessions";
import { ENGINE_COLOR } from "../theme";

interface CommandPaletteProps {
  open: boolean;
  projects: ProjectInfo[];
  tabs: TabInfo[];
  onClose: () => void;
  onActivateTab: (id: string) => void;
  onNewTabInProject: (project: ProjectInfo) => void;
}

type Action =
  | { kind: "switch-tab"; id: string; label: string; engine: TabInfo["engine"] }
  | { kind: "new-tab"; project: ProjectInfo; label: string };

export default function CommandPalette({
  open,
  projects,
  tabs,
  onClose,
  onActivateTab,
  onNewTabInProject,
}: CommandPaletteProps) {
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [searchResults, setSearchResults] = useState<BrainSearchHit[] | null>(null);
  const [searching, setSearching] = useState(false);
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (!open) return;
    setQuery("");
    setSelectedIndex(0);
    setSearchResults(null);
    const id = requestAnimationFrame(() => inputRef.current?.focus());
    return () => cancelAnimationFrame(id);
  }, [open]);

  const actions = useMemo<Action[]>(() => {
    const q = query.trim().toLowerCase();
    const projectLabel = (id: string) => projects.find((p) => p.id === id)?.label ?? id;
    const switchActions: Action[] = tabs.map((tab) => ({
      kind: "switch-tab",
      id: tab.id,
      engine: tab.engine,
      label: `Switch to ${projectLabel(tab.project)} — ${tab.engine}`,
    }));
    const newTabActions: Action[] = projects.map((project) => ({
      kind: "new-tab",
      project,
      label: `New tab in ${project.label}`,
    }));
    const all = [...switchActions, ...newTabActions];
    if (!q) return all;
    return all.filter((a) => a.label.toLowerCase().includes(q));
  }, [query, tabs, projects]);

  async function runSearch(q: string) {
    if (!q.trim()) return;
    setSearching(true);
    try {
      const results = await searchBrain(q.trim());
      setSearchResults(results);
    } catch (err) {
      console.error("brain search failed", err);
      setSearchResults([]);
    } finally {
      setSearching(false);
    }
  }

  function runAction(action: Action) {
    if (action.kind === "switch-tab") onActivateTab(action.id);
    else onNewTabInProject(action.project);
    onClose();
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      if (searchResults) setSearchResults(null);
      else onClose();
      return;
    }
    if (searchResults) return; // results view is read-only besides Esc
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelectedIndex((i) => Math.min(i + 1, actions.length));
      return;
    }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelectedIndex((i) => Math.max(i - 1, 0));
      return;
    }
    if (e.key === "Enter") {
      e.preventDefault();
      if (selectedIndex >= actions.length) {
        void runSearch(query);
        return;
      }
      const action = actions[selectedIndex];
      if (action) runAction(action);
      else void runSearch(query);
    }
  }

  if (!open) return null;

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        className="command-palette"
        role="dialog"
        aria-label="Command palette"
        onMouseDown={(e) => e.stopPropagation()}
        onKeyDown={handleKeyDown}
      >
        <input
          ref={inputRef}
          className="command-palette-input"
          placeholder="Switch tab, open a project, or search the brain…"
          value={query}
          onChange={(e) => {
            setQuery(e.currentTarget.value);
            setSelectedIndex(0);
            setSearchResults(null);
          }}
        />
        {searchResults ? (
          <div className="command-palette-results">
            {searching ? (
              <div className="command-palette-empty">Searching…</div>
            ) : searchResults.length === 0 ? (
              <div className="command-palette-empty">No matches in the brain for “{query}”.</div>
            ) : (
              <ul className="command-palette-list">
                {searchResults.map((hit) => (
                  <li key={hit.id} className="command-palette-hit">
                    <span className="command-palette-hit-kind">{hit.kind}</span>
                    <span className="command-palette-hit-label">{hit.label}</span>
                    <span className="command-palette-hit-project">{hit.project}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        ) : (
          <ul className="command-palette-list">
            {actions.map((action, i) => (
              <li
                key={action.kind === "switch-tab" ? `tab:${action.id}` : `new:${action.project.id}`}
                className={`command-palette-row${i === selectedIndex ? " is-selected" : ""}`}
                onMouseEnter={() => setSelectedIndex(i)}
                onClick={() => runAction(action)}
              >
                {action.kind === "switch-tab" && (
                  <span
                    className="engine-dot"
                    style={{ background: ENGINE_COLOR[action.engine] }}
                    aria-hidden
                  />
                )}
                {action.kind === "new-tab" && <span className="command-palette-plus">+</span>}
                <span>{action.label}</span>
              </li>
            ))}
            {query.trim() && (
              <li
                className={`command-palette-row${selectedIndex === actions.length ? " is-selected" : ""}`}
                onMouseEnter={() => setSelectedIndex(actions.length)}
                onClick={() => void runSearch(query)}
              >
                <span className="command-palette-plus">?</span>
                <span>Search brain for “{query.trim()}”</span>
              </li>
            )}
            {actions.length === 0 && !query.trim() && (
              <li className="command-palette-empty">No projects yet — ingest one with the `brain` CLI.</li>
            )}
          </ul>
        )}
      </div>
    </div>
  );
}

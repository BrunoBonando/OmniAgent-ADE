// Node detail panel (Task 6.2 — "non-negotiable... the thing that makes the
// map a *working surface*, not eye candy"): summary/path/backlinks plus
// REAL actions. Opens for any non-community node click (community nodes
// expand instead — see `BrainMap.tsx`'s `onNodeClick`).
//
// Action wiring:
// - Open file / Reveal in Finder: `@tauri-apps/plugin-opener`'s
//   `openPath`/`revealItemInDir` directly — the plugin is already
//   registered on the Rust side (`tauri_plugin_opener::init()` in
//   `src-tauri/src/lib.rs`) and granted (`opener:default` in
//   `capabilities/default.json`), so no new Tauri command is needed for
//   these two; wrapping them again would just be reinventing what's
//   already there.
// - Open terminal here: reuses the SAME `session_create` flow Phase 5
//   built, via the `onOpenTerminal` callback lifted from `App.tsx`
//   (mirrors `requestNewTab`'s project -> engine-picker -> session_create
//   shape) — the cross-view integration point the task calls out.
// - Jump to transcript: session-kind nodes only; opens `detail.path` (the
//   transcript file, once Phase 7 starts writing `Session` nodes) via the
//   same opener plugin; no session nodes exist in real data yet (Phase 7
//   isn't built), so this renders a graceful "no transcript found" instead
//   of erroring when `path` is absent — never a crash.
import { useEffect, useState } from "react";
import { openPath, revealItemInDir } from "@tauri-apps/plugin-opener";
import { mapNodeDetail, type MapNodeDetail } from "../lib/tauri";
import type { ProjectInfo } from "../state/sessions";
import { colorForKind, labelForKind } from "./palette";

interface DetailPanelProps {
  nodeId: string;
  projects: ProjectInfo[];
  onClose: () => void;
  onSelectNode: (id: string) => void;
  onOpenTerminal: (project: ProjectInfo) => void;
}

function resolveProjectInfo(projects: ProjectInfo[], projectId: string): ProjectInfo {
  return projects.find((p) => p.id === projectId) ?? { id: projectId, label: projectId, path: null };
}

export default function DetailPanel({
  nodeId,
  projects,
  onClose,
  onSelectNode,
  onOpenTerminal,
}: DetailPanelProps) {
  const [detail, setDetail] = useState<MapNodeDetail | null | undefined>(undefined); // undefined = loading
  const [error, setError] = useState<string | null>(null);
  const [actionMessage, setActionMessage] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setDetail(undefined);
    setError(null);
    setActionMessage(null);
    mapNodeDetail(nodeId)
      .then((d) => {
        if (!cancelled) setDetail(d);
      })
      .catch((err) => {
        console.error(`map_node_detail(${nodeId}) failed`, err);
        if (!cancelled) setError(String(err));
      });
    return () => {
      cancelled = true;
    };
  }, [nodeId]);

  async function handleOpenFile() {
    if (!detail?.path) return;
    try {
      await openPath(detail.path);
    } catch (err) {
      console.error("openPath failed", err);
      setActionMessage(`Couldn't open ${detail.path}: ${err}`);
    }
  }

  async function handleReveal() {
    if (!detail?.path) return;
    try {
      await revealItemInDir(detail.path);
    } catch (err) {
      console.error("revealItemInDir failed", err);
      setActionMessage(`Couldn't reveal ${detail.path}: ${err}`);
    }
  }

  function handleOpenTerminal() {
    if (!detail) return;
    onOpenTerminal(resolveProjectInfo(projects, detail.project));
  }

  async function handleJumpToTranscript() {
    if (!detail) return;
    if (!detail.path) {
      setActionMessage("No transcript found for this session yet.");
      return;
    }
    try {
      await openPath(detail.path);
    } catch (err) {
      console.error("openPath (transcript) failed", err);
      setActionMessage(`Couldn't open the transcript: ${err}`);
    }
  }

  return (
    <div className="detail-panel" role="dialog" aria-label="Node detail">
      <div className="detail-panel-header">
        <button className="detail-panel-close" onClick={onClose} aria-label="Close detail panel">
          ×
        </button>
      </div>

      {detail === undefined && !error && <div className="detail-panel-loading">Loading…</div>}
      {error && <div className="detail-panel-error">Couldn't load this node: {error}</div>}
      {detail === null && <div className="detail-panel-error">Node not found — the brain may have re-ingested.</div>}

      {detail && (
        <>
          <div className="detail-panel-kind" style={{ color: colorForKind(detail.kind) }}>
            {labelForKind(detail.kind)}
          </div>
          <h2 className="detail-panel-title">{detail.label}</h2>
          <div className="detail-panel-project">{detail.project}</div>

          {detail.path && <code className="detail-panel-path">{detail.path}</code>}

          {detail.summary ? (
            <p className="detail-panel-summary">{detail.summary}</p>
          ) : (
            <p className="detail-panel-summary is-muted">No summary yet.</p>
          )}

          <div className="detail-panel-actions">
            <button onClick={handleOpenFile} disabled={!detail.path}>
              Open file
            </button>
            <button onClick={handleReveal} disabled={!detail.path}>
              Reveal in Finder
            </button>
            <button onClick={handleOpenTerminal}>Open terminal here</button>
            {detail.kind === "session" && (
              <button onClick={handleJumpToTranscript}>Jump to transcript</button>
            )}
          </div>

          {actionMessage && <div className="detail-panel-action-message">{actionMessage}</div>}

          {detail.backlinks.length > 0 && (
            <div className="detail-panel-backlinks">
              <div className="detail-panel-backlinks-heading">Related ({detail.backlinks.length})</div>
              <ul>
                {detail.backlinks.map((b) => (
                  <li key={`${b.edge_kind}:${b.id}`}>
                    <button className="detail-panel-backlink" onClick={() => onSelectNode(b.id)}>
                      <span
                        className="detail-panel-backlink-dot"
                        style={{ background: colorForKind(b.kind) }}
                        aria-hidden
                      />
                      <span className="detail-panel-backlink-edge">{b.edge_kind}</span>
                      <span className="detail-panel-backlink-label">{b.label}</span>
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      )}
    </div>
  );
}

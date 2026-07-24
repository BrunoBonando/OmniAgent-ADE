// Task 7.1's review-mode surface: the `review_memory` toggle plus a small
// approve/discard list for session summaries waiting on review. Same
// overlay pattern as AboutPanel.tsx (backdrop + centered panel), triggered
// from the same sidebar footer.
import { useCallback, useEffect, useState } from "react";
import {
  pendingNotesApprove,
  pendingNotesDiscard,
  pendingNotesList,
  REVIEW_MEMORY_SETTING_KEY,
  settingsGet,
  settingsSet,
  type PendingNote,
} from "../lib/tauri";

export default function ReviewPanel({ onClose }: { onClose: () => void }) {
  const [reviewMode, setReviewMode] = useState<boolean | null>(null); // null = still loading
  const [notes, setNotes] = useState<PendingNote[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const reload = useCallback(() => {
    pendingNotesList(null)
      .then(setNotes)
      .catch((err) => {
        console.error("pendingNotesList failed", err);
        setError(String(err));
      });
  }, []);

  useEffect(() => {
    settingsGet(REVIEW_MEMORY_SETTING_KEY)
      .then((v) => setReviewMode(v === "true"))
      .catch((err) => {
        console.error("failed to read review_memory setting, defaulting to off", err);
        setReviewMode(false);
      });
    reload();
  }, [reload]);

  async function toggleReviewMode() {
    if (reviewMode === null) return;
    const next = !reviewMode;
    setReviewMode(next);
    try {
      await settingsSet(REVIEW_MEMORY_SETTING_KEY, next ? "true" : "false");
    } catch (err) {
      console.error("failed to persist review_memory setting", err);
      setReviewMode(!next); // revert the optimistic flip
    }
  }

  async function approve(nodeId: string) {
    setBusyId(nodeId);
    try {
      await pendingNotesApprove(nodeId);
      reload();
    } catch (err) {
      console.error(`pendingNotesApprove(${nodeId}) failed`, err);
      setError(String(err));
    } finally {
      setBusyId(null);
    }
  }

  async function discard(nodeId: string) {
    setBusyId(nodeId);
    try {
      await pendingNotesDiscard(nodeId);
      reload();
    } catch (err) {
      console.error(`pendingNotesDiscard(${nodeId}) failed`, err);
      setError(String(err));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        className="review-panel"
        role="dialog"
        aria-label="Session summary review"
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="review-panel-header">
          <h2>Session summaries</h2>
          <button className="review-panel-close" onClick={onClose} aria-label="Close review panel">
            ×
          </button>
        </div>

        <label className="review-panel-toggle">
          <input
            type="checkbox"
            checked={reviewMode ?? false}
            disabled={reviewMode === null}
            onChange={() => void toggleReviewMode()}
          />
          Review before committing new session summaries
        </label>
        <p className="review-panel-hint">
          {reviewMode
            ? "New session summaries wait here for approval before they show up in search or briefings."
            : "Auto-commit is on (default) — new session summaries land immediately. Turn this on to review them first."}
        </p>

        {error && <div className="review-panel-error">Something went wrong: {error}</div>}

        {notes === null && !error && <div className="review-panel-loading">Loading…</div>}

        {notes && notes.length === 0 && (
          <p className="review-panel-empty">Nothing waiting for review.</p>
        )}

        {notes && notes.length > 0 && (
          <ul className="review-panel-list">
            {notes.map((n) => (
              <li key={n.node_id} className="review-panel-row">
                <div className="review-panel-row-main">
                  <span className="review-panel-row-project">{n.project}</span>
                  <span className="review-panel-row-title">{n.title}</span>
                </div>
                <div className="review-panel-row-actions">
                  <button
                    disabled={busyId === n.node_id}
                    onClick={() => void approve(n.node_id)}
                  >
                    Approve
                  </button>
                  <button
                    className="review-panel-discard"
                    disabled={busyId === n.node_id}
                    onClick={() => void discard(n.node_id)}
                  >
                    Discard
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

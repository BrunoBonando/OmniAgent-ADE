// The per-session code review column. Founder ask, 2026-07-26 (verbatim):
// "For each session, have a top right menu with three things: Code Review
// Panel info (number of changes within files that are uncommited) and if
// clicked, it should show a code review panel for that session like this:
// [screenshot] as a new column, dedicated on the right" — then, to remove
// any doubt: "Make sure that the code panel is for session, okay?".
//
// Reference: docs/reference/warp-code-review-panel.png. Structure taken from
// it directly — a header row (repo path + branch, file count, aggregate
// stat, close), a toolbar row ("Uncommitted changes" + Commit), then a
// scrollable list of rounded file cards, each with an expand chevron, a
// left-truncated filename, a copy button, a stat badge, and row actions;
// one card expands to show the real diff inline with line numbers.
//
// ## Per session, concretely
//
// This component owns no notion of a "current repo". It is handed
// `repoPath` — the cwd of the pane whose 3-dot menu opened it — and every
// backend call passes it through. Opening the panel from a different pane
// re-targets it (App.tsx swaps `target`), and the header names the repo it
// is showing so there is never ambiguity about whose changes these are.
//
// ## Colours
//
// Chrome comes from the app's existing Warp-sampled tokens. The diff
// green/red are new tokens (`--diff-*` in App.css) sampled from the founder's
// reference screenshot with PIL, matching how the base palette was
// established — App.css's own header comment notes diff red/green were
// deliberately left unsampled at the time because they were out of scope.
// This is the task that puts them in scope.
//
// ## Refresh cadence
//
// Polled, not watched: `dirwatch.rs` is deliberately single-level and
// non-recursive (see its module doc), so it answers "did this one directory
// change" — not "did anything anywhere in this repo change", which is the
// question a review panel asks. A 4s poll while the panel is open, paused
// while the window is hidden, plus an immediate refresh on open, on window
// focus, and after any mutation. `git status` on a large repo is tens of
// milliseconds, so this is far from hammering it, and the panel is only
// mounted while the user is actually looking at it.
import { useCallback, useEffect, useMemo, useState } from "react";
import { openPath } from "@tauri-apps/plugin-opener";
import {
  CODE_REVIEW_WIDTH_SETTING_KEY,
  reviewCommit,
  reviewFileDiff,
  reviewRevertFile,
  reviewStatus,
  settingsGet,
  settingsSet,
  type ChangedFile,
  type FileDiff,
  type ReviewStatus,
} from "../lib/tauri";
import {
  CODE_REVIEW_DEFAULT_WIDTH,
  clampCodeReviewWidth,
  codeReviewWidthFromDrag,
  commitDisabledReason,
  deriveHeaderStats,
  fileListPage,
  FILE_PAGE_SIZE,
  formatFileStat,
  nextVisibleCount,
  renderableDiffLines,
  revertPrompt,
  statusGlyph,
  toggleExpandedFile,
} from "../state/codeReviewState";

/** How often the panel re-reads `git status` while it's open and visible. */
export const REVIEW_POLL_MS = 4000;

interface CodeReviewPanelProps {
  /** The cwd of the pane this panel was opened from — the whole per-session
   * contract. Not the project root: a session can sit in a subdirectory, and
   * the backend resolves the enclosing repo itself. */
  repoPath: string;
  /** The pane's display label, so the header can name whose review this is
   * even when two panes share one repo. */
  sessionLabel: string;
  onClose: () => void;
}

/** One file's fetched diff, or its in-flight/failed state. */
type DiffState = FileDiff | "loading" | { error: string };

export default function CodeReviewPanel({ repoPath, sessionLabel, onClose }: CodeReviewPanelProps) {
  const [status, setStatus] = useState<ReviewStatus | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());
  const [diffs, setDiffs] = useState<Record<string, DiffState>>({});
  const [visibleCount, setVisibleCount] = useState(FILE_PAGE_SIZE);
  const [message, setMessage] = useState("");
  const [committing, setCommitting] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [confirmRevert, setConfirmRevert] = useState<string | null>(null);
  const [width, setWidth] = useState(CODE_REVIEW_DEFAULT_WIDTH);

  // ---- status loading ---------------------------------------------------
  const refresh = useCallback(async () => {
    try {
      const next = await reviewStatus(repoPath);
      setStatus(next);
      setLoadError(null);
    } catch (err) {
      // Shown as-is: every error the backend rejects with is already
      // user-facing ("… isn't inside a git repository").
      setLoadError(String(err));
      setStatus(null);
    }
  }, [repoPath]);

  // Re-target cleanly whenever the session changes: a stale file list from
  // the previous pane's repo must never flash in the new one's header.
  useEffect(() => {
    setStatus(null);
    setLoadError(null);
    setExpanded(new Set());
    setDiffs({});
    setVisibleCount(FILE_PAGE_SIZE);
    setConfirmRevert(null);
    void refresh();
  }, [repoPath, refresh]);

  // Poll while open and visible; a hidden window has nobody watching it.
  useEffect(() => {
    const tick = () => {
      if (!document.hidden) void refresh();
    };
    const id = window.setInterval(tick, REVIEW_POLL_MS);
    window.addEventListener("focus", tick);
    return () => {
      window.clearInterval(id);
      window.removeEventListener("focus", tick);
    };
  }, [refresh]);

  // ---- persisted width, same pattern as FileTree ------------------------
  useEffect(() => {
    let cancelled = false;
    settingsGet(CODE_REVIEW_WIDTH_SETTING_KEY)
      .then((raw) => {
        if (cancelled || raw === null) return;
        const parsed = Number(raw);
        if (Number.isFinite(parsed)) setWidth(clampCodeReviewWidth(parsed));
      })
      .catch((err) => console.error("failed to read code_review_width, using the default", err));
    return () => {
      cancelled = true;
    };
  }, []);

  const beginResize = useCallback(
    (e: React.PointerEvent) => {
      e.preventDefault();
      const startX = e.clientX;
      const startWidth = width;
      const onMove = (ev: PointerEvent) => setWidth(codeReviewWidthFromDrag(startWidth, startX, ev.clientX));
      const onUp = (ev: PointerEvent) => {
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", onUp);
        const final = codeReviewWidthFromDrag(startWidth, startX, ev.clientX);
        setWidth(final);
        void settingsSet(CODE_REVIEW_WIDTH_SETTING_KEY, String(Math.round(final))).catch((err) =>
          console.error("failed to persist code_review_width", err),
        );
      };
      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onUp);
    },
    [width],
  );

  // ---- expand a row -> fetch that file's diff once ----------------------
  const toggleFile = useCallback(
    (path: string) => {
      setExpanded((prev) => {
        const next = toggleExpandedFile(prev, path);
        if (next.has(path) && diffs[path] === undefined) {
          setDiffs((d) => ({ ...d, [path]: "loading" }));
          reviewFileDiff(repoPath, path)
            .then((diff) => setDiffs((d) => ({ ...d, [path]: diff })))
            .catch((err) => setDiffs((d) => ({ ...d, [path]: { error: String(err) } })));
        }
        return next;
      });
    },
    [diffs, repoPath],
  );

  // ---- mutations --------------------------------------------------------
  const handleCommit = useCallback(async () => {
    setCommitting(true);
    try {
      const result = await reviewCommit(repoPath, message);
      setMessage("");
      setExpanded(new Set());
      setDiffs({});
      setNotice(`Committed ${result.files_committed} ${result.files_committed === 1 ? "file" : "files"} as ${result.short_sha}`);
      await refresh();
    } catch (err) {
      setNotice(String(err));
    } finally {
      setCommitting(false);
    }
  }, [message, refresh, repoPath]);

  const handleRevert = useCallback(
    async (file: ChangedFile) => {
      setConfirmRevert(null);
      try {
        const outcome = await reviewRevertFile(repoPath, file.path);
        setNotice(
          outcome === "moved_to_trash"
            ? `Moved ${file.path} to the Trash`
            : `Restored ${file.path} from the last commit`,
        );
        setExpanded((prev) => {
          const next = new Set(prev);
          next.delete(file.path);
          return next;
        });
        setDiffs((d) => {
          const next = { ...d };
          delete next[file.path];
          return next;
        });
        await refresh();
      } catch (err) {
        setNotice(String(err));
      }
    },
    [refresh, repoPath],
  );

  const copyPath = useCallback((path: string) => {
    void navigator.clipboard?.writeText(path).then(
      () => setNotice(`Copied ${path}`),
      (err: unknown) => setNotice(`Couldn't copy the path: ${String(err)}`),
    );
  }, []);

  // ---- derived ----------------------------------------------------------
  const header = useMemo(() => (status ? deriveHeaderStats(status) : null), [status]);
  const page = useMemo(
    () => (status ? fileListPage(status.files, visibleCount) : null),
    [status, visibleCount],
  );
  const disabledReason = commitDisabledReason(status, message, committing);

  return (
    <aside className="code-review" aria-label={`Code review for ${sessionLabel}`} style={{ width }}>
      <div
        className="code-review-resize-handle"
        onPointerDown={beginResize}
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize code review panel"
      />

      {/* ---- header: whose repo, which branch, how much changed --------- */}
      <div className="code-review-header">
        <div className="code-review-heading">
          <span className="code-review-path" title={status?.repo_root ?? repoPath}>
            {header?.pathLabel ?? repoPath}
          </span>
          <span className="code-review-branch">
            <span aria-hidden="true">⑂</span> {header?.branchLabel ?? "…"}
          </span>
        </div>
        <div className="code-review-header-right">
          {header && (
            <span className="code-review-totals">
              <span className="code-review-filecount" title={`${header.fileCount} changed files`}>
                <span aria-hidden="true">▤</span> {header.fileCount}
              </span>
              <span className="code-review-stat-add">+{header.added}</span>
              <span className="code-review-stat-del">-{header.removed}</span>
            </span>
          )}
          <button className="code-review-close" onClick={onClose} aria-label="Close code review" title="Close">
            &times;
          </button>
        </div>
      </div>

      <div className="code-review-session-line">
        Session <strong>{sessionLabel}</strong>
        {header?.binaryNote && <span className="code-review-disclosure"> · {header.binaryNote}</span>}
        {header?.truncatedNote && <span className="code-review-disclosure"> · {header.truncatedNote}</span>}
      </div>

      {/* ---- toolbar + commit ------------------------------------------ */}
      <div className="code-review-toolbar">
        <span className="code-review-toolbar-label">
          <span aria-hidden="true">⇄</span> Uncommitted changes
        </span>
      </div>

      <div className="code-review-commit">
        <input
          className="code-review-commit-input"
          value={message}
          placeholder="Commit message"
          aria-label="Commit message"
          onChange={(e) => setMessage(e.target.value)}
          onKeyDown={(e) => {
            e.stopPropagation();
            if (e.key === "Enter" && !disabledReason) void handleCommit();
          }}
        />
        <button
          className="code-review-commit-btn"
          onClick={() => void handleCommit()}
          disabled={disabledReason !== null}
          title={disabledReason ?? `Commit all ${status?.file_count ?? 0} changes`}
        >
          {committing ? "Committing…" : `Commit all ${status?.file_count ?? 0}`}
        </button>
      </div>
      {disabledReason && <p className="code-review-hint">{disabledReason}</p>}

      {notice && (
        <div className="code-review-notice" role="status">
          <span>{notice}</span>
          <button onClick={() => setNotice(null)} aria-label="Dismiss">
            &times;
          </button>
        </div>
      )}

      {/* ---- the file list --------------------------------------------- */}
      <div className="code-review-body">
        {loadError && <p className="code-review-error">{loadError}</p>}
        {!loadError && status === null && <p className="code-review-empty">Reading the working tree…</p>}
        {!loadError && header?.isClean && (
          <p className="code-review-empty">
            Nothing uncommitted. Everything in this session's repo is committed.
          </p>
        )}

        {page?.shown.map((file) => {
          const isOpen = expanded.has(file.path);
          const stat = formatFileStat(file);
          const glyph = statusGlyph(file.status);
          const diff = diffs[file.path];
          const prompt = confirmRevert === file.path ? revertPrompt(file) : null;

          return (
            <div key={file.path} className={`code-review-row${isOpen ? " is-open" : ""}`}>
              <div className="code-review-row-head">
                <button
                  className="code-review-chevron"
                  onClick={() => toggleFile(file.path)}
                  aria-expanded={isOpen}
                  aria-label={`${isOpen ? "Collapse" : "Expand"} ${file.path}`}
                >
                  <span aria-hidden="true">{isOpen ? "⌄" : "›"}</span>
                </button>

                <span
                  className="code-review-status-glyph"
                  data-status={file.status}
                  title={glyph.label}
                  aria-label={glyph.label}
                >
                  {glyph.letter}
                </span>

                {/* Truncated from the LEFT so the filename's tail stays
                    visible, exactly as the reference does. `unicode-bidi:
                    plaintext` keeps the path itself rendering left-to-right
                    (so `/` separators aren't reordered) while the container's
                    rtl direction moves the ellipsis to the start. */}
                <button
                  className="code-review-name"
                  onClick={() => toggleFile(file.path)}
                  title={file.old_path ? `${file.path} (renamed from ${file.old_path})` : file.path}
                >
                  {file.path}
                </button>

                <span className="code-review-row-actions">
                  <button
                    className="code-review-icon"
                    onClick={() => copyPath(file.path)}
                    aria-label={`Copy path of ${file.path}`}
                    title="Copy path"
                  >
                    ⧉
                  </button>

                  {stat.kind === "counts" && (
                    <span className="code-review-badge">
                      <span className="code-review-stat-add">+{stat.added}</span>
                      <span className="code-review-badge-dot" aria-hidden="true">·</span>
                      <span className="code-review-stat-del">-{stat.removed}</span>
                    </span>
                  )}
                  {stat.kind === "empty" && <span className="code-review-badge is-empty">0</span>}
                  {stat.kind === "binary" && (
                    <span className="code-review-badge is-binary" title="Binary file — no line counts">
                      binary
                    </span>
                  )}

                  <button
                    className="code-review-icon code-review-icon-revert"
                    onClick={() => setConfirmRevert(confirmRevert === file.path ? null : file.path)}
                    aria-label={`Revert ${file.path}`}
                    aria-expanded={prompt !== null}
                    title="Revert…"
                  >
                    ↺
                  </button>
                  <button
                    className="code-review-icon"
                    onClick={() =>
                      void openPath(`${status?.repo_root ?? ""}/${file.path}`).catch((err) =>
                        setNotice(`Couldn't open ${file.path}: ${String(err)}`),
                      )
                    }
                    aria-label={`Open ${file.path}`}
                    title="Open in the default app"
                  >
                    ↗
                  </button>
                </span>
              </div>

              {/* Two-step confirmation — the revert icon never acts on its
                  own click, because for a modified file the action is
                  genuinely unrecoverable. */}
              {prompt && (
                <div className={`code-review-confirm${prompt.destructive ? " is-destructive" : ""}`} role="alertdialog">
                  <span className="code-review-confirm-detail">{prompt.detail}</span>
                  <span className="code-review-confirm-actions">
                    {!prompt.blocked && (
                      <button className="code-review-confirm-go" onClick={() => void handleRevert(file)}>
                        {prompt.confirmLabel}
                      </button>
                    )}
                    <button className="code-review-confirm-cancel" onClick={() => setConfirmRevert(null)}>
                      {prompt.blocked ? "OK" : "Cancel"}
                    </button>
                  </span>
                </div>
              )}

              {isOpen && <DiffBody diff={diff} />}
            </div>
          );
        })}

        {page?.hasMore && (
          <button
            className="code-review-more"
            onClick={() => setVisibleCount((c) => nextVisibleCount(c, status?.files.length ?? 0))}
          >
            Show {Math.min(FILE_PAGE_SIZE, page.remaining)} more ({page.remaining} left)
          </button>
        )}
      </div>
    </aside>
  );
}

/** The expanded diff for one file: line numbers in a fixed gutter, added and
 * removed lines carrying their own tint and left accent bar. */
function DiffBody({ diff }: { diff: DiffState | undefined }) {
  if (diff === undefined || diff === "loading") {
    return <div className="code-review-diff is-loading">Loading diff…</div>;
  }
  if ("error" in diff) {
    return <div className="code-review-diff is-error">{diff.error}</div>;
  }
  if (diff.binary) {
    return <div className="code-review-diff is-note">Binary file — no line-by-line diff to show.</div>;
  }
  if (diff.hunks.length === 0) {
    return <div className="code-review-diff is-note">No textual changes.</div>;
  }

  const render = renderableDiffLines(diff.hunks);
  return (
    <div className="code-review-diff">
      {render.hunks.map((hunk, hi) => (
        <div className="code-review-hunk" key={`${hunk.header}-${hi}`}>
          <div className="code-review-hunk-header">{hunk.header}</div>
          {hunk.lines.map((line, li) => (
            <div className={`code-review-line is-${line.kind}`} key={li}>
              <span className="code-review-gutter" aria-hidden="true">
                {line.old_line ?? ""}
              </span>
              <span className="code-review-gutter" aria-hidden="true">
                {line.new_line ?? ""}
              </span>
              <span className="code-review-sign" aria-hidden="true">
                {line.kind === "added" ? "+" : line.kind === "removed" ? "-" : " "}
              </span>
              <span className="code-review-code">{line.text}</span>
            </div>
          ))}
        </div>
      ))}
      {(render.capped || diff.truncated) && (
        <div className="code-review-diff is-note">
          Showing the first {render.shown} of {diff.truncated ? `${diff.line_count}+` : render.total} lines.
        </div>
      )}
    </div>
  );
}

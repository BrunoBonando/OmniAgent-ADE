import { useEffect, useMemo, useRef, useState } from "react";
import { settingsGet, settingsSet } from "../lib/tauri";
import type { ProjectInfo } from "../state/sessions";

type Priority = "low" | "medium" | "high" | "urgent";

interface PlanCard {
  id: string;
  title: string;
  description: string;
  priority: Priority;
  dueDate: string | null;
  labels: string[];
  done: boolean;
  createdAt: string;
}

interface PlanColumn {
  id: string;
  title: string;
  cards: PlanCard[];
}

interface PlanBoardState {
  columns: PlanColumn[];
  backlog: PlanCard[];
}

const BACKLOG = "backlog" as const;
type ContainerId = string; // column id or "backlog"

const PRIORITIES: Priority[] = ["low", "medium", "high", "urgent"];
const PRIORITY_LABEL: Record<Priority, string> = {
  low: "Low",
  medium: "Medium",
  high: "High",
  urgent: "Urgent",
};

const LABEL_PALETTE = [
  { name: "Bug", color: "#ef5f6b" },
  { name: "Feature", color: "#5f6bff" },
  { name: "Chore", color: "#8b95a7" },
  { name: "Design", color: "#c07bff" },
  { name: "Research", color: "#38b6a0" },
  { name: "Urgent", color: "#f0a13a" },
];

function labelColor(name: string): string {
  const found = LABEL_PALETTE.find((l) => l.name.toLowerCase() === name.toLowerCase());
  if (found) return found.color;
  let hash = 0;
  for (let i = 0; i < name.length; i++) hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
  const hue = hash % 360;
  return `hsl(${hue} 55% 55%)`;
}

function newId(prefix: string): string {
  const rnd = globalThis.crypto?.randomUUID?.();
  return rnd ? `${prefix}-${rnd}` : `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function createCard(title: string): PlanCard {
  return {
    id: newId("card"),
    title,
    description: "",
    priority: "medium",
    dueDate: null,
    labels: [],
    done: false,
    createdAt: new Date().toISOString(),
  };
}

function createColumn(title: string): PlanColumn {
  return { id: newId("col"), title, cards: [] };
}

function defaultBoard(): PlanBoardState {
  return {
    columns: [createColumn("To Do"), createColumn("In Progress"), createColumn("Review"), createColumn("Done")],
    backlog: [],
  };
}

function normalizeCard(value: unknown): PlanCard | null {
  if (!value || typeof value !== "object") return null;
  const c = value as Record<string, unknown>;
  if (typeof c.id !== "string" || typeof c.title !== "string") return null;
  const priority =
    typeof c.priority === "string" && (PRIORITIES as string[]).includes(c.priority)
      ? (c.priority as Priority)
      : "medium";
  return {
    id: c.id,
    title: c.title,
    description: typeof c.description === "string" ? c.description : "",
    priority,
    dueDate: typeof c.dueDate === "string" ? c.dueDate : null,
    labels: Array.isArray(c.labels) ? c.labels.filter((l): l is string => typeof l === "string") : [],
    done: c.done === true,
    createdAt: typeof c.createdAt === "string" ? c.createdAt : new Date().toISOString(),
  };
}

function normalizeCards(value: unknown): PlanCard[] {
  if (!Array.isArray(value)) return [];
  return value.map(normalizeCard).filter((c): c is PlanCard => c !== null);
}

function safeParseBoard(raw: string | null): PlanBoardState {
  if (!raw) return defaultBoard();
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;

    // Migration from the legacy { todo, doing, done } shape.
    if (parsed && !Array.isArray(parsed.columns) && (parsed.todo || parsed.doing || parsed.done)) {
      const map: Array<[string, unknown]> = [
        ["To Do", parsed.todo],
        ["In Progress", parsed.doing],
        ["Done", parsed.done],
      ];
      return {
        columns: map.map(([title, cards]) => ({
          id: newId("col"),
          title,
          cards: normalizeCards(cards).map((c) => ({ ...c, done: title === "Done" })),
        })),
        backlog: [],
      };
    }

    if (parsed && Array.isArray(parsed.columns)) {
      const columns = parsed.columns
        .map((col): PlanColumn | null => {
          if (!col || typeof col !== "object") return null;
          const c = col as Record<string, unknown>;
          if (typeof c.id !== "string" || typeof c.title !== "string") return null;
          return { id: c.id, title: c.title, cards: normalizeCards(c.cards) };
        })
        .filter((c): c is PlanColumn => c !== null);
      const backlog = normalizeCards(parsed.backlog);
      if (columns.length === 0) return { ...defaultBoard(), backlog };
      return { columns, backlog };
    }
  } catch {
    /* fall through to default */
  }
  return defaultBoard();
}

function boardKey(projectId: string): string {
  return `plan_board:${projectId}`;
}

function dueMeta(due: string | null): { label: string; tone: "overdue" | "soon" | "normal" } | null {
  if (!due) return null;
  const date = new Date(`${due}T00:00:00`);
  if (Number.isNaN(date.getTime())) return null;
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const diffDays = Math.round((date.getTime() - today.getTime()) / 86400000);
  const label = date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  if (diffDays < 0) return { label, tone: "overdue" };
  if (diffDays <= 2) return { label, tone: "soon" };
  return { label, tone: "normal" };
}

interface PlanBoardProps {
  project: ProjectInfo | null;
  hidden: boolean;
}

export default function PlanBoard({ project, hidden }: PlanBoardProps) {
  const [board, setBoard] = useState<PlanBoardState>(defaultBoard);
  const [ready, setReady] = useState(false);
  const [newColumnTitle, setNewColumnTitle] = useState("");
  const [addingColumn, setAddingColumn] = useState(false);
  const [composerFor, setComposerFor] = useState<ContainerId | null>(null);
  const [composerText, setComposerText] = useState("");
  const [editingColumn, setEditingColumn] = useState<{ id: string; draft: string } | null>(null);
  const [openCard, setOpenCard] = useState<{ container: ContainerId; id: string } | null>(null);
  const [labelDraft, setLabelDraft] = useState("");
  const [drag, setDrag] = useState<{ cardId: string; from: ContainerId } | null>(null);
  const [dropTarget, setDropTarget] = useState<ContainerId | null>(null);
  const dragRef = useRef<{ cardId: string; from: ContainerId } | null>(null);

  useEffect(() => {
    if (!project) {
      setBoard(defaultBoard());
      setReady(true);
      return;
    }
    let cancelled = false;
    setReady(false);
    settingsGet(boardKey(project.id))
      .then((raw) => {
        if (cancelled) return;
        setBoard(safeParseBoard(raw));
        setReady(true);
      })
      .catch(() => {
        if (cancelled) return;
        setBoard(defaultBoard());
        setReady(true);
      });
    return () => {
      cancelled = true;
    };
  }, [project?.id]);

  useEffect(() => {
    if (!project || !ready) return;
    void settingsSet(boardKey(project.id), JSON.stringify(board));
  }, [project?.id, board, ready]);

  const stats = useMemo(() => {
    const cards = board.columns.flatMap((c) => c.cards);
    const total = cards.length;
    const done = cards.filter((c) => c.done).length;
    return { total, done, backlog: board.backlog.length, pct: total === 0 ? 0 : Math.round((done / total) * 100) };
  }, [board]);

  function findCard(container: ContainerId, id: string): PlanCard | undefined {
    if (container === BACKLOG) return board.backlog.find((c) => c.id === id);
    return board.columns.find((c) => c.id === container)?.cards.find((c) => c.id === id);
  }

  function addColumn() {
    const title = newColumnTitle.trim();
    if (!title) return;
    setBoard((prev) => ({ ...prev, columns: [...prev.columns, createColumn(title)] }));
    setNewColumnTitle("");
    setAddingColumn(false);
  }

  function renameColumn(id: string, title: string) {
    const trimmed = title.trim();
    setEditingColumn(null);
    if (!trimmed) return;
    setBoard((prev) => ({
      ...prev,
      columns: prev.columns.map((c) => (c.id === id ? { ...c, title: trimmed } : c)),
    }));
  }

  function deleteColumn(id: string) {
    setBoard((prev) => {
      const column = prev.columns.find((c) => c.id === id);
      if (!column) return prev;
      return {
        columns: prev.columns.filter((c) => c.id !== id),
        backlog: [...prev.backlog, ...column.cards],
      };
    });
  }

  function moveColumn(id: string, dir: -1 | 1) {
    setBoard((prev) => {
      const index = prev.columns.findIndex((c) => c.id === id);
      const target = index + dir;
      if (index < 0 || target < 0 || target >= prev.columns.length) return prev;
      const columns = [...prev.columns];
      [columns[index], columns[target]] = [columns[target], columns[index]];
      return { ...prev, columns };
    });
  }

  function addCardTo(container: ContainerId, title: string) {
    const trimmed = title.trim();
    if (!trimmed) return;
    const card = createCard(trimmed);
    setBoard((prev) => {
      if (container === BACKLOG) return { ...prev, backlog: [...prev.backlog, card] };
      return {
        ...prev,
        columns: prev.columns.map((c) => (c.id === container ? { ...c, cards: [...c.cards, card] } : c)),
      };
    });
  }

  function updateCard(container: ContainerId, id: string, patch: Partial<PlanCard>) {
    setBoard((prev) => {
      const apply = (cards: PlanCard[]) => cards.map((c) => (c.id === id ? { ...c, ...patch } : c));
      if (container === BACKLOG) return { ...prev, backlog: apply(prev.backlog) };
      return {
        ...prev,
        columns: prev.columns.map((c) => (c.id === container ? { ...c, cards: apply(c.cards) } : c)),
      };
    });
  }

  function removeCard(container: ContainerId, id: string) {
    setBoard((prev) => {
      if (container === BACKLOG) return { ...prev, backlog: prev.backlog.filter((c) => c.id !== id) };
      return {
        ...prev,
        columns: prev.columns.map((c) =>
          c.id === container ? { ...c, cards: c.cards.filter((x) => x.id !== id) } : c,
        ),
      };
    });
  }

  function moveWithin(container: ContainerId, id: string, dir: -1 | 1) {
    setBoard((prev) => {
      const swap = (cards: PlanCard[]) => {
        const index = cards.findIndex((c) => c.id === id);
        const target = index + dir;
        if (index < 0 || target < 0 || target >= cards.length) return cards;
        const next = [...cards];
        [next[index], next[target]] = [next[target], next[index]];
        return next;
      };
      if (container === BACKLOG) return { ...prev, backlog: swap(prev.backlog) };
      return {
        ...prev,
        columns: prev.columns.map((c) => (c.id === container ? { ...c, cards: swap(c.cards) } : c)),
      };
    });
  }

  // Move a card between containers. `done` is synced to true only when the card
  // lands on the last (rightmost / Done) column, false otherwise.
  function moveCard(from: ContainerId, to: ContainerId, id: string) {
    if (from === to) return;
    setBoard((prev) => {
      let moving: PlanCard | undefined;
      const detach = (cards: PlanCard[]) =>
        cards.filter((c) => {
          if (c.id === id) {
            moving = c;
            return false;
          }
          return true;
        });

      const backlog = from === BACKLOG ? detach(prev.backlog) : [...prev.backlog];
      let columns = prev.columns.map((c) => (c.id === from ? { ...c, cards: detach(c.cards) } : c));
      if (!moving) return prev;

      const lastColumnId = prev.columns[prev.columns.length - 1]?.id;
      const landed: PlanCard = to === BACKLOG ? { ...moving, done: false } : { ...moving, done: to === lastColumnId };

      if (to === BACKLOG) return { columns, backlog: [...backlog, landed] };
      columns = columns.map((c) => (c.id === to ? { ...c, cards: [...c.cards, landed] } : c));
      return { columns, backlog };
    });
  }

  function toggleDone(container: ContainerId, id: string) {
    const card = findCard(container, id);
    if (!card) return;
    updateCard(container, id, { done: !card.done });
  }

  function clearDone() {
    setBoard((prev) => ({
      ...prev,
      columns: prev.columns.map((c) => ({ ...c, cards: c.cards.filter((card) => !card.done) })),
    }));
  }

  function beginDrag(cardId: string, from: ContainerId) {
    const info = { cardId, from };
    dragRef.current = info;
    setDrag(info);
  }
  function endDrag() {
    dragRef.current = null;
    setDrag(null);
    setDropTarget(null);
  }
  function dropInto(to: ContainerId) {
    const info = dragRef.current;
    if (info) moveCard(info.from, to, info.cardId);
    endDrag();
  }

  const detail = openCard ? findCard(openCard.container, openCard.id) : undefined;
  const lastColumnId = board.columns[board.columns.length - 1]?.id;
  const firstColumnId = board.columns[0]?.id;

  function renderCard(container: ContainerId, card: PlanCard, index: number, count: number) {
    const due = dueMeta(card.dueDate);
    return (
      <article
        key={card.id}
        className={`plan-card${card.done ? " is-done" : ""}${drag?.cardId === card.id ? " is-dragging" : ""}`}
        draggable
        onDragStart={(e) => {
          e.dataTransfer.effectAllowed = "move";
          beginDrag(card.id, container);
        }}
        onDragEnd={endDrag}
        onClick={() => setOpenCard({ container, id: card.id })}
      >
        <div className="plan-card-top">
          <button
            className={`plan-card-check${card.done ? " is-on" : ""}`}
            title={card.done ? "Mark as not done" : "Mark as done"}
            onClick={(e) => {
              e.stopPropagation();
              toggleDone(container, card.id);
            }}
          >
            {card.done ? "✓" : ""}
          </button>
          <p className="plan-card-title">{card.title}</p>
        </div>

        {card.labels.length > 0 && (
          <div className="plan-card-labels">
            {card.labels.map((l) => (
              <span key={l} className="plan-label" style={{ background: labelColor(l) }}>
                {l}
              </span>
            ))}
          </div>
        )}

        <div className="plan-card-meta">
          <span className={`plan-pri plan-pri-${card.priority}`}>{PRIORITY_LABEL[card.priority]}</span>
          {due && (
            <span className={`plan-due plan-due-${due.tone}`}>
              📅 {due.label}
            </span>
          )}
          {card.description.trim() && (
            <span className="plan-card-note" title="Has description">
              ≡
            </span>
          )}
        </div>

        <div className="plan-card-actions" onClick={(e) => e.stopPropagation()}>
          <button disabled={index === 0} onClick={() => moveWithin(container, card.id, -1)} title="Move up">
            ↑
          </button>
          <button disabled={index === count - 1} onClick={() => moveWithin(container, card.id, 1)} title="Move down">
            ↓
          </button>
          {container === BACKLOG && firstColumnId && (
            <button
              className="plan-card-promote"
              onClick={() => moveCard(BACKLOG, firstColumnId, card.id)}
              title="Move to first column"
            >
              → Ready
            </button>
          )}
          <button onClick={() => removeCard(container, card.id)} title="Delete card">
            ✕
          </button>
        </div>
      </article>
    );
  }

  return (
    <section className="dashboard-surface plan-board" style={{ display: hidden ? "none" : "flex" }}>
      <header className="dashboard-surface-header">
        <div>
          <h2>Plan board</h2>
          <p>
            {project
              ? `${project.label} · ${stats.total} tasks · ${stats.done} done (${stats.pct}%) · ${stats.backlog} in backlog`
              : "Select a workspace to plan tasks"}
          </p>
        </div>
        <div className="plan-board-header-actions">
          {addingColumn ? (
            <div className="plan-board-create">
              <input
                autoFocus
                value={newColumnTitle}
                onChange={(e) => setNewColumnTitle(e.target.value)}
                placeholder="Column name"
                onKeyDown={(e) => {
                  if (e.key === "Enter") addColumn();
                  if (e.key === "Escape") {
                    setAddingColumn(false);
                    setNewColumnTitle("");
                  }
                }}
              />
              <button onClick={addColumn}>Add column</button>
            </div>
          ) : (
            <button className="plan-board-secondary" disabled={!project} onClick={() => setAddingColumn(true)}>
              + Column
            </button>
          )}
          <button className="plan-board-secondary" disabled={stats.done === 0} onClick={clearDone}>
            Clear done
          </button>
        </div>
      </header>

      {!project ? (
        <div className="dashboard-empty">Select a workspace to use the plan board.</div>
      ) : !ready ? (
        <div className="dashboard-empty">Loading board…</div>
      ) : (
        <div className="plan-board-body">
          <div className="plan-board-grid">
            {board.columns.map((column, colIndex) => (
              <section
                key={column.id}
                className={`plan-lane${dropTarget === column.id ? " is-drop-target" : ""}${
                  column.id === lastColumnId ? " is-done-lane" : ""
                }`}
                onDragOver={(e) => {
                  if (!dragRef.current) return;
                  e.preventDefault();
                  setDropTarget(column.id);
                }}
                onDragLeave={() => setDropTarget((t) => (t === column.id ? null : t))}
                onDrop={(e) => {
                  e.preventDefault();
                  dropInto(column.id);
                }}
              >
                <header className="plan-lane-header">
                  {editingColumn?.id === column.id ? (
                    <input
                      className="plan-lane-rename"
                      autoFocus
                      value={editingColumn.draft}
                      onChange={(e) => setEditingColumn({ id: column.id, draft: e.target.value })}
                      onBlur={() => renameColumn(column.id, editingColumn.draft)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") renameColumn(column.id, editingColumn.draft);
                        if (e.key === "Escape") setEditingColumn(null);
                      }}
                    />
                  ) : (
                    <span
                      className="plan-lane-title"
                      onDoubleClick={() => setEditingColumn({ id: column.id, draft: column.title })}
                      title="Double-click to rename"
                    >
                      {column.title}
                      <span className="plan-lane-count">{column.cards.length}</span>
                    </span>
                  )}
                  <div className="plan-lane-tools">
                    <button disabled={colIndex === 0} onClick={() => moveColumn(column.id, -1)} title="Move left">
                      ‹
                    </button>
                    <button
                      disabled={colIndex === board.columns.length - 1}
                      onClick={() => moveColumn(column.id, 1)}
                      title="Move right"
                    >
                      ›
                    </button>
                    <button onClick={() => deleteColumn(column.id)} title="Delete column">
                      ✕
                    </button>
                  </div>
                </header>

                <div className="plan-lane-cards">
                  {column.cards.map((card, i) => renderCard(column.id, card, i, column.cards.length))}
                  {column.cards.length === 0 && <div className="plan-lane-empty">Drop cards here</div>}
                </div>

                <div className="plan-lane-footer">
                  {composerFor === column.id ? (
                    <div className="plan-composer">
                      <textarea
                        autoFocus
                        rows={2}
                        value={composerText}
                        placeholder="Card title…"
                        onChange={(e) => setComposerText(e.target.value)}
                        onKeyDown={(e) => {
                          if (e.key === "Enter" && !e.shiftKey) {
                            e.preventDefault();
                            addCardTo(column.id, composerText);
                            setComposerText("");
                          }
                          if (e.key === "Escape") {
                            setComposerFor(null);
                            setComposerText("");
                          }
                        }}
                      />
                      <div className="plan-composer-actions">
                        <button
                          onClick={() => {
                            addCardTo(column.id, composerText);
                            setComposerText("");
                          }}
                        >
                          Add
                        </button>
                        <button
                          className="plan-board-secondary"
                          onClick={() => {
                            setComposerFor(null);
                            setComposerText("");
                          }}
                        >
                          Cancel
                        </button>
                      </div>
                    </div>
                  ) : (
                    <button
                      className="plan-lane-add"
                      onClick={() => {
                        setComposerFor(column.id);
                        setComposerText("");
                      }}
                    >
                      + Add card
                    </button>
                  )}
                </div>
              </section>
            ))}
          </div>

          <section
            className={`plan-backlog${dropTarget === BACKLOG ? " is-drop-target" : ""}`}
            onDragOver={(e) => {
              if (!dragRef.current) return;
              e.preventDefault();
              setDropTarget(BACKLOG);
            }}
            onDragLeave={() => setDropTarget((t) => (t === BACKLOG ? null : t))}
            onDrop={(e) => {
              e.preventDefault();
              dropInto(BACKLOG);
            }}
          >
            <header className="plan-backlog-header">
              <span className="plan-lane-title">
                Backlog
                <span className="plan-lane-count">{board.backlog.length}</span>
              </span>
              {composerFor === BACKLOG ? (
                <div className="plan-composer plan-composer-inline">
                  <input
                    autoFocus
                    value={composerText}
                    placeholder="Backlog item…"
                    onChange={(e) => setComposerText(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") {
                        addCardTo(BACKLOG, composerText);
                        setComposerText("");
                      }
                      if (e.key === "Escape") {
                        setComposerFor(null);
                        setComposerText("");
                      }
                    }}
                  />
                  <button
                    onClick={() => {
                      addCardTo(BACKLOG, composerText);
                      setComposerText("");
                    }}
                  >
                    Add
                  </button>
                </div>
              ) : (
                <button
                  className="plan-board-secondary"
                  onClick={() => {
                    setComposerFor(BACKLOG);
                    setComposerText("");
                  }}
                >
                  + Backlog item
                </button>
              )}
            </header>
            <div className="plan-backlog-cards">
              {board.backlog.map((card, i) => renderCard(BACKLOG, card, i, board.backlog.length))}
              {board.backlog.length === 0 && (
                <div className="plan-lane-empty">Backlog is empty — capture ideas here, then promote to Ready.</div>
              )}
            </div>
          </section>
        </div>
      )}

      {detail && openCard && (
        <div className="plan-modal-backdrop" onClick={() => setOpenCard(null)}>
          <div className="plan-modal" onClick={(e) => e.stopPropagation()}>
            <header className="plan-modal-header">
              <input
                className="plan-modal-title"
                value={detail.title}
                onChange={(e) => updateCard(openCard.container, openCard.id, { title: e.target.value })}
              />
              <button className="plan-modal-close" onClick={() => setOpenCard(null)} title="Close">
                ✕
              </button>
            </header>

            <div className="plan-modal-body">
              <label className="plan-field">
                <span>Description</span>
                <textarea
                  rows={5}
                  value={detail.description}
                  placeholder="Add more detail, acceptance criteria, links…"
                  onChange={(e) => updateCard(openCard.container, openCard.id, { description: e.target.value })}
                />
              </label>

              <div className="plan-field-row">
                <label className="plan-field">
                  <span>Priority</span>
                  <select
                    value={detail.priority}
                    onChange={(e) =>
                      updateCard(openCard.container, openCard.id, { priority: e.target.value as Priority })
                    }
                  >
                    {PRIORITIES.map((p) => (
                      <option key={p} value={p}>
                        {PRIORITY_LABEL[p]}
                      </option>
                    ))}
                  </select>
                </label>

                <label className="plan-field">
                  <span>Due date</span>
                  <input
                    type="date"
                    value={detail.dueDate ?? ""}
                    onChange={(e) => updateCard(openCard.container, openCard.id, { dueDate: e.target.value || null })}
                  />
                </label>

                <label className="plan-field plan-field-check">
                  <span>Status</span>
                  <button
                    className={`plan-modal-done${detail.done ? " is-on" : ""}`}
                    onClick={() => toggleDone(openCard.container, openCard.id)}
                  >
                    {detail.done ? "✓ Done" : "Mark done"}
                  </button>
                </label>
              </div>

              <div className="plan-field">
                <span>Labels</span>
                <div className="plan-modal-labels">
                  {detail.labels.map((l) => (
                    <span key={l} className="plan-label" style={{ background: labelColor(l) }}>
                      {l}
                      <button
                        onClick={() =>
                          updateCard(openCard.container, openCard.id, {
                            labels: detail.labels.filter((x) => x !== l),
                          })
                        }
                      >
                        ✕
                      </button>
                    </span>
                  ))}
                </div>
                <div className="plan-label-suggest">
                  {LABEL_PALETTE.filter((p) => !detail.labels.includes(p.name)).map((p) => (
                    <button
                      key={p.name}
                      style={{ borderColor: p.color, color: p.color }}
                      onClick={() =>
                        updateCard(openCard.container, openCard.id, { labels: [...detail.labels, p.name] })
                      }
                    >
                      + {p.name}
                    </button>
                  ))}
                </div>
                <div className="plan-composer-inline">
                  <input
                    value={labelDraft}
                    placeholder="Custom label…"
                    onChange={(e) => setLabelDraft(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") {
                        const l = labelDraft.trim();
                        if (l && !detail.labels.includes(l)) {
                          updateCard(openCard.container, openCard.id, { labels: [...detail.labels, l] });
                        }
                        setLabelDraft("");
                      }
                    }}
                  />
                </div>
              </div>

              <div className="plan-field">
                <span>Move to</span>
                <div className="plan-modal-move">
                  {board.columns.map((c) => (
                    <button
                      key={c.id}
                      disabled={openCard.container === c.id}
                      onClick={() => {
                        moveCard(openCard.container, c.id, openCard.id);
                        setOpenCard({ container: c.id, id: openCard.id });
                      }}
                    >
                      {c.title}
                    </button>
                  ))}
                  <button
                    disabled={openCard.container === BACKLOG}
                    onClick={() => {
                      moveCard(openCard.container, BACKLOG, openCard.id);
                      setOpenCard({ container: BACKLOG, id: openCard.id });
                    }}
                  >
                    Backlog
                  </button>
                </div>
              </div>

              <p className="plan-modal-created">
                Created{" "}
                {new Date(detail.createdAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}
              </p>
            </div>

            <footer className="plan-modal-footer">
              <button
                className="plan-modal-delete"
                onClick={() => {
                  removeCard(openCard.container, openCard.id);
                  setOpenCard(null);
                }}
              >
                Delete card
              </button>
              <button className="plan-board-secondary" onClick={() => setOpenCard(null)}>
                Done
              </button>
            </footer>
          </div>
        </div>
      )}
    </section>
  );
}

import { useEffect, useMemo, useState } from "react";
import { settingsGet, settingsSet } from "../lib/tauri";
import type { ProjectInfo } from "../state/sessions";

type LaneId = "todo" | "doing" | "done";

interface PlanCard {
  id: string;
  title: string;
}

interface PlanBoardState {
  todo: PlanCard[];
  doing: PlanCard[];
  done: PlanCard[];
}

const EMPTY_BOARD: PlanBoardState = { todo: [], doing: [], done: [] };
const LANES: LaneId[] = ["todo", "doing", "done"];

function boardKey(projectId: string): string {
  return `plan_board:${projectId}`;
}

function laneTitle(lane: LaneId): string {
  if (lane === "todo") return "Planned";
  if (lane === "doing") return "In progress";
  return "Done";
}

function safeParseBoard(raw: string | null): PlanBoardState {
  if (!raw) return EMPTY_BOARD;
  try {
    const parsed = JSON.parse(raw) as Partial<PlanBoardState>;
    const normalize = (value: unknown): PlanCard[] =>
      Array.isArray(value)
        ? value
            .filter((item): item is PlanCard => {
              if (!item || typeof item !== "object") return false;
              const card = item as Partial<PlanCard>;
              return typeof card.id === "string" && typeof card.title === "string";
            })
            .map((item) => ({ id: item.id, title: item.title }))
        : [];
    return {
      todo: normalize(parsed.todo),
      doing: normalize(parsed.doing),
      done: normalize(parsed.done),
    };
  } catch {
    return EMPTY_BOARD;
  }
}

function moveCardWithin(cards: PlanCard[], id: string, direction: "up" | "down"): PlanCard[] {
  const index = cards.findIndex((card) => card.id === id);
  if (index < 0) return cards;
  const target = direction === "up" ? index - 1 : index + 1;
  if (target < 0 || target >= cards.length) return cards;
  const next = [...cards];
  [next[index], next[target]] = [next[target], next[index]];
  return next;
}

interface PlanBoardProps {
  project: ProjectInfo | null;
  hidden: boolean;
}

export default function PlanBoard({ project, hidden }: PlanBoardProps) {
  const [board, setBoard] = useState<PlanBoardState>(EMPTY_BOARD);
  const [newTitle, setNewTitle] = useState("");
  const [ready, setReady] = useState(false);
  const [editing, setEditing] = useState<{ id: string; draft: string } | null>(null);
  const [dragged, setDragged] = useState<{ id: string; from: LaneId } | null>(null);
  const [dropHint, setDropHint] = useState<LaneId | null>(null);

  useEffect(() => {
    if (!project) {
      setBoard(EMPTY_BOARD);
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
        setBoard(EMPTY_BOARD);
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

  const total = useMemo(
    () => board.todo.length + board.doing.length + board.done.length,
    [board.todo.length, board.doing.length, board.done.length],
  );
  const donePct = total === 0 ? 0 : Math.round((board.done.length / total) * 100);

  function addCard() {
    const title = newTitle.trim();
    if (!title) return;
    const id = globalThis.crypto?.randomUUID?.() ?? `card-${Date.now()}-${Math.random()}`;
    setBoard((prev) => ({ ...prev, todo: [{ id, title }, ...prev.todo] }));
    setNewTitle("");
  }

  function moveAcrossLanes(from: LaneId, to: LaneId, id: string) {
    if (from === to) return;
    setBoard((prev) => {
      const card = prev[from].find((c) => c.id === id);
      if (!card) return prev;
      return {
        ...prev,
        [from]: prev[from].filter((c) => c.id !== id),
        [to]: [card, ...prev[to]],
      };
    });
  }

  function moveWithinLane(lane: LaneId, id: string, direction: "up" | "down") {
    setBoard((prev) => ({ ...prev, [lane]: moveCardWithin(prev[lane], id, direction) }));
  }

  function removeCard(lane: LaneId, id: string) {
    setBoard((prev) => ({ ...prev, [lane]: prev[lane].filter((c) => c.id !== id) }));
  }

  function commitEdit(lane: LaneId, id: string) {
    if (!editing || editing.id !== id) return;
    const title = editing.draft.trim();
    setEditing(null);
    if (!title) return;
    setBoard((prev) => ({
      ...prev,
      [lane]: prev[lane].map((card) => (card.id === id ? { ...card, title } : card)),
    }));
  }

  function clearDone() {
    setBoard((prev) => ({ ...prev, done: [] }));
  }

  return (
    <section className="dashboard-surface plan-board" style={{ display: hidden ? "none" : "flex" }}>
      <header className="dashboard-surface-header">
        <div>
          <h2>Plan board</h2>
          <p>
            {project ? `${project.label} · ${total} tasks · ${donePct}% done` : "Select a workspace to plan tasks"}
          </p>
        </div>
        <div className="plan-board-header-actions">
          <div className="plan-board-create">
            <input
              value={newTitle}
              onChange={(e) => setNewTitle(e.target.value)}
              placeholder="New task"
              onKeyDown={(e) => {
                if (e.key === "Enter") addCard();
              }}
            />
            <button onClick={addCard}>Add</button>
          </div>
          <button className="plan-board-secondary" disabled={board.done.length === 0} onClick={clearDone}>
            Clear done
          </button>
        </div>
      </header>

      {!project ? (
        <div className="dashboard-empty">Select a workspace to use the plan board.</div>
      ) : !ready ? (
        <div className="dashboard-empty">Loading board…</div>
      ) : (
        <div className="plan-board-grid">
          {LANES.map((lane) => (
            <section
              key={lane}
              className={`plan-lane${dropHint === lane ? " is-drop-target" : ""}`}
              onDragOver={(e) => {
                if (!dragged) return;
                e.preventDefault();
                setDropHint(lane);
              }}
              onDrop={(e) => {
                if (!dragged) return;
                e.preventDefault();
                moveAcrossLanes(dragged.from, lane, dragged.id);
                setDragged(null);
                setDropHint(null);
              }}
              onDragLeave={() => {
                if (dropHint === lane) setDropHint(null);
              }}
            >
              <header>
                <span>{laneTitle(lane)}</span>
                <span>{board[lane].length}</span>
              </header>
              <div className="plan-lane-cards">
                {board[lane].map((card, index) => (
                  <article
                    key={card.id}
                    className="plan-card"
                    draggable
                    onDragStart={() => setDragged({ id: card.id, from: lane })}
                    onDragEnd={() => {
                      setDragged(null);
                      setDropHint(null);
                    }}
                  >
                    {editing?.id === card.id ? (
                      <input
                        className="plan-card-edit"
                        autoFocus
                        value={editing.draft}
                        onChange={(e) => setEditing({ id: card.id, draft: e.target.value })}
                        onBlur={() => commitEdit(lane, card.id)}
                        onKeyDown={(e) => {
                          if (e.key === "Enter") commitEdit(lane, card.id);
                          if (e.key === "Escape") setEditing(null);
                        }}
                      />
                    ) : (
                      <p onDoubleClick={() => setEditing({ id: card.id, draft: card.title })}>{card.title}</p>
                    )}
                    <div className="plan-card-actions">
                      <button disabled={index === 0} onClick={() => moveWithinLane(lane, card.id, "up")} title="Move up">
                        ↑
                      </button>
                      <button
                        disabled={index === board[lane].length - 1}
                        onClick={() => moveWithinLane(lane, card.id, "down")}
                        title="Move down"
                      >
                        ↓
                      </button>
                      <button onClick={() => removeCard(lane, card.id)} title="Remove">
                        ✕
                      </button>
                    </div>
                  </article>
                ))}
              </div>
            </section>
          ))}
        </div>
      )}
    </section>
  );
}


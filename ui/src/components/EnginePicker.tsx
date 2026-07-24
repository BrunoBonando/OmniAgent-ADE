// New-tab engine picker (PLAN.md Task 5.2 / DESIGN 3.1 / Bruno, 2026-07-24:
// "whenever a new terminal is open, it asks what's supposed to run? If the
// default is Claude, it basically runs Claude"). Opens with the resolved
// default already highlighted so Enter alone reproduces that behavior in
// one keystroke; arrows or digits pick something else.
import { useEffect, useRef, useState } from "react";
import { ENGINES, cycleEngine, type Engine, type ProjectInfo } from "../state/sessions";
import { ENGINE_COLOR, ENGINE_HINT, ENGINE_LABEL } from "../theme";

interface EnginePickerProps {
  project: ProjectInfo;
  defaultEngine: Engine;
  onConfirm: (engine: Engine) => void;
  onCancel: () => void;
}

export default function EnginePicker({ project, defaultEngine, onConfirm, onCancel }: EnginePickerProps) {
  const [selected, setSelected] = useState<Engine>(defaultEngine);
  const panelRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      onCancel();
      return;
    }
    if (e.key === "Enter") {
      e.preventDefault();
      onConfirm(selected);
      return;
    }
    if (e.key === "ArrowDown" || e.key === "j") {
      e.preventDefault();
      setSelected((cur) => cycleEngine(cur, 1));
      return;
    }
    if (e.key === "ArrowUp" || e.key === "k") {
      e.preventDefault();
      setSelected((cur) => cycleEngine(cur, -1));
      return;
    }
    const digit = Number(e.key);
    if (Number.isInteger(digit) && digit >= 1 && digit <= ENGINES.length) {
      e.preventDefault();
      const engine = ENGINES[digit - 1];
      setSelected(engine);
      onConfirm(engine);
    }
  }

  return (
    <div className="overlay-backdrop" onMouseDown={onCancel}>
      <div
        ref={panelRef}
        className="engine-picker"
        role="dialog"
        aria-label={`New terminal in ${project.label}`}
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="engine-picker-eyebrow">NEW TERMINAL — {project.label.toUpperCase()}</div>
        <ul className="engine-picker-list">
          {ENGINES.map((engine, i) => (
            <li
              key={engine}
              className={`engine-picker-row${engine === selected ? " is-selected" : ""}`}
              onMouseEnter={() => setSelected(engine)}
              onClick={() => onConfirm(engine)}
            >
              <span className="engine-dot" style={{ background: ENGINE_COLOR[engine] }} aria-hidden />
              <span className="engine-picker-label">{ENGINE_LABEL[engine]}</span>
              <span className="engine-picker-hint">{ENGINE_HINT[engine]}</span>
              <span className="engine-picker-key">{i + 1}</span>
              {engine === defaultEngine && <span className="engine-picker-default">default</span>}
            </li>
          ))}
        </ul>
        <div className="engine-picker-footer">
          <span>&#8629; confirm</span>
          <span>&uarr;&darr; choose</span>
          <span>esc cancel</span>
        </div>
      </div>
    </div>
  );
}

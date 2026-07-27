// ⌘T (design §3): name + engine, joins the on-screen session's next free
// slot. Copy is verbatim from the mock; slot math from session.tabs.length.
import { useEffect, useRef, useState } from "react";
import type { Agent, AgentsState } from "../state/agents";
import { AVAILABLE_AGENTS } from "../state/agents";
import type { Engine } from "../state/sessions";
import type { SessionGroup } from "../state/sessionGroups";
import { MAX_PANES } from "../state/paneGrid";
import { initialNewTerminalState, terminalKeyAction } from "../state/newTerminalState";
import { AGENT_ICON, ENGINE_HINT, ENGINE_LABEL } from "../theme";
import Icon from "./Icon";

const KEY_HINT: Partial<Record<Engine, string>> = { claude: "⌘1", codex: "⌘2", antigravity: "⌘3", shell: "⌘0" };

interface NewTerminalModalProps {
  session: SessionGroup;
  agentState: AgentsState;
  onCreate: (name: string, engine: Engine) => void;
  onInstallAgent: (agent: Agent) => void;
  onClose: () => void;
}

export function NewTerminalModal({ session, agentState, onCreate, onInstallAgent, onClose }: NewTerminalModalProps) {
  const [state, setState] = useState(() => initialNewTerminalState(session.tabs.length, agentState));
  const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => { inputRef.current?.select(); }, []);

  const confirm = () => onCreate(state.name.trim() || state.name, state.engine);

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        className="modal-panel new-terminal-panel"
        role="dialog"
        aria-label="New terminal"
        onMouseDown={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          const action = terminalKeyAction(e);
          if (!action) return;
          e.preventDefault();
          if (action.type === "cancel") onClose();
          else if (action.type === "confirm") confirm();
          else if (agentState.installed.has(action.engine) || action.engine === "shell") {
            setState((s) => ({ ...s, engine: action.engine }));
          }
        }}
      >
        <div className="modal-header">
          <span>New terminal</span>
          <span className="modal-header-context">
            in {session.label} · {session.tabs.length} of {MAX_PANES} used
          </span>
          <span className="modal-header-key">⌘T</span>
        </div>
        <div className="modal-section">
          <div className="modal-field-label">Name</div>
          <input
            ref={inputRef}
            className="modal-text-input"
            value={state.name}
            onChange={(e) => setState((s) => ({ ...s, name: e.target.value }))}
          />
          <div className="modal-field-help">Pre-filled — rename any time by double-clicking the terminal header.</div>
        </div>
        <div className="modal-section">
          <div className="modal-field-label">Engine</div>
          <div className="engine-row-list">
            {AVAILABLE_AGENTS.map((engine) => {
              const available = agentState.installed.has(engine) || engine === "shell";
              const selected = state.engine === engine;
              return (
                <div
                  key={engine}
                  className={`engine-row${selected ? " is-selected" : ""}${available ? "" : " is-unavailable"}`}
                  role="option"
                  aria-selected={selected}
                  onClick={() =>
                    available ? setState((s) => ({ ...s, engine })) : onInstallAgent(engine)
                  }
                >
                  <span className="engine-row-icon"><Icon name={AGENT_ICON[engine]} /></span>
                  <span className="engine-row-text">
                    <span className="engine-row-name">{ENGINE_LABEL[engine]}</span>
                    <span className="engine-row-hint">
                      {available ? ENGINE_HINT[engine] : "Not installed — install CLI"}
                    </span>
                  </span>
                  {available && KEY_HINT[engine] && (
                    <span className="engine-row-key">{KEY_HINT[engine]}</span>
                  )}
                </div>
              );
            })}
          </div>
        </div>
        <div className="modal-footer">
          <span className="modal-footer-hint">Opens in the session's next free slot.</span>
          <button type="button" className="btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn-primary" onClick={confirm}>Open terminal ⏎</button>
        </div>
      </div>
    </div>
  );
}

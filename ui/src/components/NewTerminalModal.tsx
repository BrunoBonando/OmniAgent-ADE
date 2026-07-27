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
  // `.focus()` explicitly, then `.select()`: focusing is a *convention* of
  // `select()` on most engines, not a guarantee, and this dialog's whole
  // keyboard surface (Enter/Escape/⌘1-⌘3/⌘0) hangs off a keydown handler that
  // only sees events raised inside the panel — see the panel's own
  // `tabIndex` note. The other two modals (`NewSessionModal`,
  // `NewWorkspaceModal`) both focus explicitly on mount; this one used to be
  // the odd one out.
  useEffect(() => {
    inputRef.current?.focus();
    inputRef.current?.select();
  }, []);

  const confirmWith = (chosen: Engine) => onCreate(state.name.trim() || state.name, chosen);
  const confirm = () => confirmWith(state.engine);

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      {/* `tabIndex={-1}` is a keyboard backstop, not a focus target — the
          name input takes focus on mount. Verbatim the reason
          `NewSessionModal`/`NewWorkspaceModal` carry it: a keydown only
          reaches `onKeyDown` below if the focused element is INSIDE this
          div, and clicking something non-focusable (the header, a hint line)
          otherwise drops focus on <body>, which would silently kill
          Enter/Escape/⌘1/⌘2/⌘3/⌘0 for the rest of the dialog's life. */}
      <div
        className="modal-panel new-terminal-panel"
        role="dialog"
        aria-label="New terminal"
        tabIndex={-1}
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
          {/* `role="listbox"` wrapping the `role="option"` rows: an option
              outside a listbox is an ARIA orphan, and the same structure
              `NewSessionModal`'s `SlotPicker` already ships. */}
          <div className="engine-row-list" role="listbox" aria-label="Engine">
            {AVAILABLE_AGENTS.map((engine) => {
              const available = agentState.installed.has(engine) || engine === "shell";
              const selected = state.engine === engine;
              const activate = () => {
                setState((s) => ({ ...s, engine }));
                if (!available) onInstallAgent(engine);
              };
              return (
                <div
                  key={engine}
                  className={`engine-row${selected ? " is-selected" : ""}${available ? "" : " is-unavailable"}`}
                  role="option"
                  aria-selected={selected}
                  tabIndex={0}
                  onClick={activate}
                  onKeyDown={(e) => {
                    if (e.key !== "Enter" && e.key !== " ") return;
                    e.preventDefault();
                    // Deliberately does NOT bubble to the panel handler
                    // above. A focusable row is where a click leaves focus,
                    // so Enter here is the modal's ordinary "Open terminal
                    // ⏎" — but the panel's `confirm()` would read
                    // `state.engine` from a closure that predates this
                    // keystroke's own selection and open the PREVIOUS
                    // engine. So Enter does the whole gesture itself, with
                    // the engine it is actually sitting on; Space only
                    // picks, which is what a listbox option's Space means.
                    e.stopPropagation();
                    activate();
                    if (e.key === "Enter" && available) confirmWith(engine);
                  }}
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

import { describe, expect, it } from "vitest";
import { defaultTerminalName, initialNewTerminalState, terminalKeyAction } from "./newTerminalState";
import { initialAgentsState } from "./agents";

describe("newTerminalState", () => {
  it("names the next slot", () => {
    expect(defaultTerminalName(4)).toBe("Terminal #5");
  });

  it("initial engine prefers installed claude, falls back to shell", () => {
    const none = initialNewTerminalState(0, initialAgentsState);
    expect(none.engine).toBe("shell");
    const withClaude = initialNewTerminalState(0, { ...initialAgentsState, installed: new Set(["claude"]) });
    expect(withClaude.engine).toBe("claude");
  });

  it("maps ⌘-digits, Enter, Escape", () => {
    expect(terminalKeyAction({ key: "1", metaKey: true })).toEqual({ type: "engine", engine: "claude" });
    expect(terminalKeyAction({ key: "2", metaKey: true })).toEqual({ type: "engine", engine: "codex" });
    expect(terminalKeyAction({ key: "3", metaKey: true })).toEqual({ type: "engine", engine: "antigravity" });
    expect(terminalKeyAction({ key: "0", metaKey: true })).toEqual({ type: "engine", engine: "shell" });
    expect(terminalKeyAction({ key: "Enter", metaKey: false })).toEqual({ type: "confirm" });
    expect(terminalKeyAction({ key: "Escape", metaKey: false })).toEqual({ type: "cancel" });
    expect(terminalKeyAction({ key: "1", metaKey: false })).toBeNull();
  });
});

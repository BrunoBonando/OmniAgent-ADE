import { describe, expect, it } from "vitest";
import {
  SESSION_STATUSES,
  STATUS_PRESENTATION,
  isSessionStatus,
  mostSignificantStatus,
  statusPresentation,
  type SessionStatus,
} from "./sessionStatus";

describe("isSessionStatus — the wire contract's five strings, nothing else", () => {
  it("accepts exactly the five backend values", () => {
    for (const s of ["ready", "thinking", "tool_execution", "awaiting_approval", "error"]) {
      expect(isSessionStatus(s)).toBe(true);
    }
  });

  it("rejects anything else, including a colour name or a sixth state added later", () => {
    for (const s of ["amber", "green", "READY", "busy", "", null, undefined, 3, {}]) {
      expect(isSessionStatus(s)).toBe(false);
    }
  });
});

describe("statusPresentation — status -> colour / motion / label", () => {
  it("labels the thinking state as Working...", () => {
    expect(statusPresentation("thinking").label).toBe("Working...");
  });

  it("maps every one of the five states to a distinct colour token", () => {
    const colors = SESSION_STATUSES.map((s) => statusPresentation(s).colorVar);
    expect(new Set(colors).size).toBe(SESSION_STATUSES.length);
  });

  it("maps every one of the five states to a distinct motion", () => {
    const motions = SESSION_STATUSES.map((s) => statusPresentation(s).motion);
    expect(new Set(motions).size).toBe(SESSION_STATUSES.length);
  });

  it("gives every state a short label and a plain-language explanation", () => {
    for (const s of SESSION_STATUSES) {
      const p = statusPresentation(s);
      expect(p.label.length).toBeGreaterThan(0);
      expect(p.label.length).toBeLessThanOrEqual(16); // stays a badge, never a sentence
      expect(p.explanation.length).toBeGreaterThan(20);
      expect(p.explanation.endsWith(".")).toBe(true);
    }
  });

  it("renders Bruno's five colours: green steady, white/blue sweeping, amber breathing, red flashing, cyan chasing", () => {
    expect(statusPresentation("ready")).toMatchObject({ colorVar: "--status-ready", motion: "steady" });
    expect(statusPresentation("thinking")).toMatchObject({ colorVar: "--status-thinking", motion: "sweep" });
    expect(statusPresentation("awaiting_approval")).toMatchObject({
      colorVar: "--status-approval",
      motion: "breathe",
    });
    expect(statusPresentation("error")).toMatchObject({ colorVar: "--status-error", motion: "flash" });
    expect(statusPresentation("tool_execution")).toMatchObject({ colorVar: "--status-tool", motion: "chase" });
  });

  it("falls back to a neutral, honest 'no signal yet' state rather than pretending a session is ready", () => {
    const pending = statusPresentation(undefined);
    expect(pending.key).toBe("unknown");
    expect(pending.motion).toBe("steady");
    expect(pending.colorVar).toBe("--status-unknown");
    // The single most important property: never green, which would claim a
    // task finished successfully when nothing has reported in at all.
    expect(pending.colorVar).not.toBe(statusPresentation("ready").colorVar);
  });

  it("treats an unrecognized status string the same as no status at all", () => {
    expect(statusPresentation("nonsense" as unknown as SessionStatus).key).toBe("unknown");
  });

  it("keeps STATUS_PRESENTATION keyed by the wire strings so a lookup never needs a mapping table", () => {
    for (const s of SESSION_STATUSES) {
      expect(STATUS_PRESENTATION[s].status).toBe(s);
      expect(STATUS_PRESENTATION[s].key).toBe(s);
    }
  });

  it("gives each state an accessible one-liner combining label and explanation", () => {
    const p = statusPresentation("awaiting_approval");
    expect(p.ariaLabel).toContain(p.label);
    expect(p.ariaLabel).toContain(p.explanation);
  });
});

describe("mostSignificantStatus — one light for a whole session", () => {
  it("is the status of the terminal in the most significant state", () => {
    expect(mostSignificantStatus(["ready", "thinking"])).toBe("thinking");
    expect(mostSignificantStatus(["thinking", "awaiting_approval"])).toBe("awaiting_approval");
    expect(mostSignificantStatus(["awaiting_approval", "error"])).toBe("error");
    expect(mostSignificantStatus(["tool_execution", "thinking"])).toBe("tool_execution");
  });

  it("puts what blocks the person above what is merely busy", () => {
    expect(mostSignificantStatus(["tool_execution", "awaiting_approval"])).toBe("awaiting_approval");
    expect(mostSignificantStatus(["ready", "error", "thinking"])).toBe("error");
  });

  it("never guesses: a session where nothing has reported in yet stays unknown", () => {
    expect(mostSignificantStatus([])).toBeUndefined();
    expect(mostSignificantStatus([undefined, undefined])).toBeUndefined();
  });

  it("ignores terminals with no signal yet when others have one", () => {
    expect(mostSignificantStatus([undefined, "ready"])).toBe("ready");
  });
});

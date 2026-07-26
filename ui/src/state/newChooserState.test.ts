import { describe, expect, it } from "vitest";
import {
  CREATE_CHOICES,
  CREATE_CHOICE_OPTIONS,
  DEFAULT_CREATE_CHOICE,
  chooserKeyAction,
  moveChoice,
} from "./newChooserState";

describe("the ⌘N choices", () => {
  it("puts Session first and makes it the default", () => {
    // Bruno, verbatim: "Session is the first and default."
    expect(CREATE_CHOICES[0]).toBe("session");
    expect(DEFAULT_CREATE_CHOICE).toBe("session");
    expect(CREATE_CHOICE_OPTIONS.map((o) => o.id)).toEqual([...CREATE_CHOICES]);
  });

  it("describes both choices for the reader, not the implementation", () => {
    for (const option of CREATE_CHOICE_OPTIONS) {
      expect(option.label.length).toBeGreaterThan(0);
      expect(option.caption.length).toBeGreaterThan(0);
    }
  });
});

describe("moveChoice", () => {
  it("moves and wraps in both directions", () => {
    expect(moveChoice("session", 1)).toBe("workspace");
    expect(moveChoice("workspace", 1)).toBe("session");
    expect(moveChoice("session", -1)).toBe("workspace");
    expect(moveChoice("workspace", -1)).toBe("session");
  });
});

describe("chooserKeyAction — the whole keyboard contract", () => {
  it("Enter confirms whatever is selected", () => {
    expect(chooserKeyAction("Enter", "session")).toEqual({ type: "confirm", choice: "session" });
    expect(chooserKeyAction("Enter", "workspace")).toEqual({ type: "confirm", choice: "workspace" });
  });

  it("Space confirms too", () => {
    expect(chooserKeyAction(" ", "workspace")).toEqual({ type: "confirm", choice: "workspace" });
  });

  it("Escape cancels from either card", () => {
    expect(chooserKeyAction("Escape", "session")).toEqual({ type: "cancel" });
    expect(chooserKeyAction("Escape", "workspace")).toEqual({ type: "cancel" });
  });

  it("both arrow axes move the selection", () => {
    expect(chooserKeyAction("ArrowRight", "session")).toEqual({ type: "move", choice: "workspace" });
    expect(chooserKeyAction("ArrowDown", "session")).toEqual({ type: "move", choice: "workspace" });
    expect(chooserKeyAction("ArrowLeft", "workspace")).toEqual({ type: "move", choice: "session" });
    expect(chooserKeyAction("ArrowUp", "workspace")).toEqual({ type: "move", choice: "session" });
  });

  it("vim keys move too", () => {
    expect(chooserKeyAction("l", "session")).toEqual({ type: "move", choice: "workspace" });
    expect(chooserKeyAction("j", "session")).toEqual({ type: "move", choice: "workspace" });
    expect(chooserKeyAction("h", "workspace")).toEqual({ type: "move", choice: "session" });
    expect(chooserKeyAction("k", "workspace")).toEqual({ type: "move", choice: "session" });
  });

  it("Tab cycles forward and Shift+Tab back, instead of escaping the dialog", () => {
    expect(chooserKeyAction("Tab", "session")).toEqual({ type: "move", choice: "workspace" });
    expect(chooserKeyAction("Tab", "workspace", false)).toEqual({ type: "move", choice: "session" });
    expect(chooserKeyAction("Tab", "session", true)).toEqual({ type: "move", choice: "workspace" });
    expect(chooserKeyAction("Tab", "workspace", true)).toEqual({ type: "move", choice: "session" });
  });

  it("digits pick and confirm in one keystroke", () => {
    expect(chooserKeyAction("1", "workspace")).toEqual({ type: "confirm", choice: "session" });
    expect(chooserKeyAction("2", "session")).toEqual({ type: "confirm", choice: "workspace" });
  });

  it("ignores digits with no card behind them", () => {
    expect(chooserKeyAction("0", "session")).toBeNull();
    expect(chooserKeyAction("3", "session")).toBeNull();
  });

  it("leaves keys that aren't ours alone", () => {
    expect(chooserKeyAction("a", "session")).toBeNull();
    expect(chooserKeyAction("F5", "session")).toBeNull();
    expect(chooserKeyAction("Backspace", "session")).toBeNull();
  });

  it("never leaves the selection outside the two real choices", () => {
    let choice = DEFAULT_CREATE_CHOICE;
    for (const key of ["ArrowRight", "Tab", "j", "ArrowUp", "h", "k", "ArrowLeft"]) {
      const action = chooserKeyAction(key, choice);
      if (action?.type === "move") choice = action.choice;
      expect(CREATE_CHOICES).toContain(choice);
    }
  });
});

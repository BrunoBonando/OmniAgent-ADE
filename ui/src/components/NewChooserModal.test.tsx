// ⌘N's chooser, driven the way Bruno said it has to work: keyboard first,
// no mouse. Every assertion here goes through real key events on the real
// dialog rather than calling the pure state machine (which
// `state/newChooserState.test.ts` covers exhaustively on its own).
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import NewChooserModal from "./NewChooserModal";

function setup() {
  const onChoose = vi.fn();
  const onClose = vi.fn();
  render(<NewChooserModal onChoose={onChoose} onClose={onClose} />);
  return { onChoose, onClose, dialog: screen.getByRole("dialog", { name: "Create new" }) };
}

describe("NewChooserModal", () => {
  it("opens with Session first and already selected", () => {
    setup();
    const cards = screen.getAllByRole("radio");
    expect(cards.map((c) => c.textContent)).toEqual(["Session1", "Workspace2"]);
    expect(cards[0]).toBeChecked();
    expect(cards[1]).not.toBeChecked();
  });

  it("takes focus on mount, so the first keystroke lands in the dialog", () => {
    const { dialog } = setup();
    expect(dialog).toHaveFocus();
  });

  it("Enter alone creates a session — the common thing in one keystroke", () => {
    const { onChoose, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "Enter" });
    expect(onChoose).toHaveBeenCalledWith("session");
  });

  it("arrow then Enter picks the workspace flow, no mouse involved", () => {
    const { onChoose, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "ArrowRight" });
    expect(screen.getAllByRole("radio")[1]).toBeChecked();
    fireEvent.keyDown(dialog, { key: "Enter" });
    expect(onChoose).toHaveBeenCalledWith("workspace");
  });

  it("moves on both axes and wraps around", () => {
    const { dialog } = setup();
    fireEvent.keyDown(dialog, { key: "ArrowDown" });
    expect(screen.getAllByRole("radio")[1]).toBeChecked();
    fireEvent.keyDown(dialog, { key: "ArrowDown" });
    expect(screen.getAllByRole("radio")[0]).toBeChecked();
    fireEvent.keyDown(dialog, { key: "ArrowLeft" });
    expect(screen.getAllByRole("radio")[1]).toBeChecked();
  });

  it("Tab cycles within the dialog instead of escaping it", () => {
    const { dialog } = setup();
    fireEvent.keyDown(dialog, { key: "Tab" });
    expect(screen.getAllByRole("radio")[1]).toBeChecked();
    fireEvent.keyDown(dialog, { key: "Tab", shiftKey: true });
    expect(screen.getAllByRole("radio")[0]).toBeChecked();
  });

  it("digits pick and confirm in one keystroke", () => {
    const { onChoose, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "2" });
    expect(onChoose).toHaveBeenCalledWith("workspace");
  });

  it("Escape cancels without creating anything", () => {
    const { onChoose, onClose, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onChoose).not.toHaveBeenCalled();
  });

  it("explains the selected choice, and updates as the selection moves", () => {
    const { dialog } = setup();
    expect(screen.getByText(/New panes in the project you're in/)).toBeInTheDocument();
    fireEvent.keyDown(dialog, { key: "ArrowRight" });
    expect(screen.getByText(/A new project from another folder/)).toBeInTheDocument();
  });

  it("still works with a mouse: hover selects, click confirms", () => {
    const { onChoose } = setup();
    const workspace = screen.getAllByRole("radio")[1];
    fireEvent.mouseEnter(workspace);
    expect(workspace).toBeChecked();
    fireEvent.click(workspace);
    expect(onChoose).toHaveBeenCalledWith("workspace");
  });

  it("clicking the backdrop cancels", () => {
    const { onClose } = setup();
    fireEvent.mouseDown(document.querySelector(".overlay-backdrop")!);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("leaves keys it doesn't own alone", () => {
    const { onChoose, onClose, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "q" });
    fireEvent.keyDown(dialog, { key: "9" });
    expect(onChoose).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });
});

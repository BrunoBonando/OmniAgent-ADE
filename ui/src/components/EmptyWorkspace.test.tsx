// The front door an empty workspace shows (founder brief, 2026-07-26).
// What actually has to hold: the question is asked, a layout is picked, and
// "start" hands the caller BOTH the layout and the typed goal — App.tsx
// turns the layout into that many panes and the goal into the session's
// name, so a dropped argument here is a silently wrong session.
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import EmptyWorkspace from "./EmptyWorkspace";
import type { ProjectInfo } from "../state/sessions";

const PROJECT: ProjectInfo = { id: "p1", label: "My-Brain", path: "/tmp/p1" };

function setup() {
  const onStart = vi.fn();
  render(<EmptyWorkspace project={PROJECT} onStart={onStart} />);
  return { onStart };
}

describe("EmptyWorkspace", () => {
  it("asks the question, in the selected workspace", () => {
    setup();
    expect(screen.getByRole("heading", { name: /achieve today/i })).toBeInTheDocument();
    expect(screen.getByText("My-Brain")).toBeInTheDocument();
  });

  it("starts with the side-by-side layout selected", () => {
    setup();
    const cards = screen.getAllByRole("button", { pressed: true });
    expect(cards).toHaveLength(1);
    expect(cards[0]).toHaveTextContent("2");
  });

  it("hands over the goal and the chosen layout", () => {
    const { onStart } = setup();
    fireEvent.change(screen.getByLabelText(/achieve today/i), {
      target: { value: "  ship the checkout fix  " },
    });
    fireEvent.click(screen.getByRole("button", { name: "4" }));
    fireEvent.click(screen.getByRole("button", { name: "Start session" }));
    expect(onStart).toHaveBeenCalledWith(PROJECT, 4, "ship the checkout fix");
  });

  it("starts with no goal typed — the goal is an offer, not a gate", () => {
    const { onStart } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Start session" }));
    expect(onStart).toHaveBeenCalledWith(PROJECT, 2, "");
  });

  it("with no project at all there is nothing to start, so it only hints", () => {
    render(<EmptyWorkspace project={null} onStart={vi.fn()} />);
    expect(screen.queryByRole("button", { name: "Start session" })).toBeNull();
    expect(screen.getByText(/Add a project/)).toBeInTheDocument();
  });
});

import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo } from "../state/sessions";

const { settingsGetMock, settingsSetMock } = vi.hoisted(() => ({
  settingsGetMock: vi.fn(),
  settingsSetMock: vi.fn(),
}));

vi.mock("../lib/tauri", () => ({
  settingsGet: settingsGetMock,
  settingsSet: settingsSetMock,
}));

const { default: PlanBoard } = await import("./PlanBoard");

const PROJECT: ProjectInfo = { id: "p1", label: "OmniAgent", path: "/repo/omniagent" };

async function addCardToColumn(columnTitle: string, cardTitle: string) {
  const column = screen.getByText(columnTitle).closest("section") as HTMLElement;
  fireEvent.click(within(column).getByText("+ Add card"));
  const textarea = within(column).getByPlaceholderText("Card title…");
  fireEvent.change(textarea, { target: { value: cardTitle } });
  fireEvent.click(within(column).getByRole("button", { name: "Add" }));
  expect(await within(column).findByText(cardTitle)).toBeInTheDocument();
  return column;
}

describe("PlanBoard", () => {
  beforeEach(() => {
    settingsGetMock.mockReset();
    settingsSetMock.mockReset();
    settingsGetMock.mockResolvedValue(null);
    settingsSetMock.mockResolvedValue(undefined);
  });

  it("renders default columns and a backlog", async () => {
    render(<PlanBoard project={PROJECT} hidden={false} />);
    await screen.findByText("To Do");
    expect(screen.getByText("In Progress")).toBeInTheDocument();
    expect(screen.getByText("Review")).toBeInTheDocument();
    expect(screen.getByText("Done")).toBeInTheDocument();
    expect(screen.getByText("Backlog")).toBeInTheDocument();
  });

  it("adds a card to a column", async () => {
    render(<PlanBoard project={PROJECT} hidden={false} />);
    await screen.findByText("To Do");
    await addCardToColumn("To Do", "Wire dashboard tabs");
  });

  it("creates a new column", async () => {
    render(<PlanBoard project={PROJECT} hidden={false} />);
    await screen.findByText("To Do");
    fireEvent.click(screen.getByRole("button", { name: "+ Column" }));
    fireEvent.change(screen.getByPlaceholderText("Column name"), { target: { value: "Blocked" } });
    fireEvent.click(screen.getByRole("button", { name: "Add column" }));
    expect(await screen.findByText("Blocked")).toBeInTheDocument();
  });

  it("adds a backlog item and promotes it to the first column", async () => {
    render(<PlanBoard project={PROJECT} hidden={false} />);
    await screen.findByText("Backlog");
    const backlog = screen.getByText("Backlog").closest("section") as HTMLElement;
    fireEvent.click(within(backlog).getByRole("button", { name: "+ Backlog item" }));
    fireEvent.change(within(backlog).getByPlaceholderText("Backlog item…"), {
      target: { value: "Investigate flaky test" },
    });
    fireEvent.click(within(backlog).getByRole("button", { name: "Add" }));
    expect(await within(backlog).findByText("Investigate flaky test")).toBeInTheDocument();

    fireEvent.click(within(backlog).getByRole("button", { name: "→ Ready" }));

    const todo = screen.getByText("To Do").closest("section") as HTMLElement;
    expect(await within(todo).findByText("Investigate flaky test")).toBeInTheDocument();
  });

  it("marks a card as done via its checkbox", async () => {
    render(<PlanBoard project={PROJECT} hidden={false} />);
    await screen.findByText("To Do");
    const column = await addCardToColumn("To Do", "Ship it");
    const card = within(column).getByText("Ship it").closest("article") as HTMLElement;
    fireEvent.click(within(card).getByTitle("Mark as done"));
    await waitFor(() => expect(card.className).toContain("is-done"));
  });

  it("opens the card detail modal and edits the description", async () => {
    render(<PlanBoard project={PROJECT} hidden={false} />);
    await screen.findByText("To Do");
    const column = await addCardToColumn("To Do", "Detailed task");
    fireEvent.click(within(column).getByText("Detailed task"));
    const description = await screen.findByPlaceholderText(/Add more detail/);
    fireEvent.change(description, { target: { value: "Acceptance: it works" } });
    await waitFor(() => {
      const persisted = settingsSetMock.mock.calls.some(
        ([key, value]) =>
          key === "plan_board:p1" && typeof value === "string" && value.includes("Acceptance: it works"),
      );
      expect(persisted).toBe(true);
    });
  });

  it("persists board changes by workspace key", async () => {
    render(<PlanBoard project={PROJECT} hidden={false} />);
    await screen.findByText("To Do");
    await addCardToColumn("To Do", "Implement plan board");
    await waitFor(() => {
      const persisted = settingsSetMock.mock.calls.some(
        ([key, value]) =>
          key === "plan_board:p1" && typeof value === "string" && value.includes("Implement plan board"),
      );
      expect(persisted).toBe(true);
    });
  });

  it("migrates the legacy todo/doing/done shape", async () => {
    settingsGetMock.mockResolvedValue(
      JSON.stringify({ todo: [{ id: "a", title: "Legacy card" }], doing: [], done: [] }),
    );
    render(<PlanBoard project={PROJECT} hidden={false} />);
    expect(await screen.findByText("Legacy card")).toBeInTheDocument();
    const todo = screen.getByText("To Do").closest("section") as HTMLElement;
    expect(within(todo).getByText("Legacy card")).toBeInTheDocument();
  });
});

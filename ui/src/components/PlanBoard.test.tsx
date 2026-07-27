import { fireEvent, render, screen, waitFor } from "@testing-library/react";
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

describe("PlanBoard", () => {
  beforeEach(() => {
    settingsGetMock.mockReset();
    settingsSetMock.mockReset();
    settingsGetMock.mockResolvedValue(null);
    settingsSetMock.mockResolvedValue(undefined);
  });

  it("adds and renders a new card", async () => {
    render(<PlanBoard project={PROJECT} hidden={false} />);
    await screen.findByText("Planned");
    fireEvent.change(screen.getByPlaceholderText("New task"), { target: { value: "Wire dashboard tabs" } });
    fireEvent.click(screen.getByRole("button", { name: "Add" }));
    expect(await screen.findByText("Wire dashboard tabs")).toBeInTheDocument();
  });

  it("persists board changes by workspace key", async () => {
    render(<PlanBoard project={PROJECT} hidden={false} />);
    await screen.findByText("Planned");
    fireEvent.change(screen.getByPlaceholderText("New task"), { target: { value: "Implement plan board" } });
    fireEvent.click(screen.getByRole("button", { name: "Add" }));
    await waitFor(() => {
      const persisted = settingsSetMock.mock.calls.some(
        ([key, value]) =>
          key === "plan_board:p1" &&
          typeof value === "string" &&
          value.includes("Implement plan board"),
      );
      expect(persisted).toBe(true);
    });
  });
});

import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { ProjectInfo, TabInfo } from "../state/sessions";
import { createUsageAnalyticsStore } from "../state/usageAnalytics";
import { initialNotificationsState } from "../state/notifications";
import DashboardOverview from "./DashboardOverview";

const PROJECT: ProjectInfo = { id: "p1", label: "OmniAgent", path: "/repo/omniagent" };

function tab(overrides: Partial<TabInfo> = {}): TabInfo {
  return {
    id: "t1",
    project: "p1",
    engine: "claude",
    cwd: "/repo/omniagent",
    createdAt: 0,
    group: "g1",
    ...overrides,
  };
}

describe("DashboardOverview", () => {
  it("renders per-project counts and quick action callbacks", () => {
    const onOpenTerminals = vi.fn();
    const onOpenBoard = vi.fn();
    const onOpenFiles = vi.fn();
    const onOpenSession = vi.fn();
    render(
      <DashboardOverview
        hidden={false}
        project={PROJECT}
        tabs={[
          tab({ id: "t1", group: "g1", engine: "claude", status: "thinking", label: "My task" }),
          tab({ id: "t2", group: "g1", engine: "shell" }),
          tab({ id: "t3", group: "g2", engine: "codex" }),
        ]}
        activeTabId="t1"
        analytics={createUsageAnalyticsStore()}
        notifications={initialNotificationsState}
        onOpenTerminals={onOpenTerminals}
        onOpenBoard={onOpenBoard}
        onOpenFiles={onOpenFiles}
        onOpenSession={onOpenSession}
      />,
    );

    // Check new stat card labels
    expect(screen.getAllByText("SESSIONS").length).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText("TOKENS TODAY").length).toBeGreaterThanOrEqual(1);

    fireEvent.click(screen.getByRole("button", { name: /working sessions/i }));
    fireEvent.click(screen.getByRole("button", { name: /open board/i }));
    fireEvent.click(screen.getByRole("button", { name: /open files/i }));
    expect(onOpenTerminals).toHaveBeenCalledTimes(1);
    expect(onOpenBoard).toHaveBeenCalledTimes(1);
    expect(onOpenFiles).toHaveBeenCalledTimes(1);

    // Click active agent row in WorkingNow panel
    fireEvent.click(screen.getByRole("button", { name: /my task/i }));
    expect(onOpenSession).toHaveBeenCalledWith("t1");
  });
});

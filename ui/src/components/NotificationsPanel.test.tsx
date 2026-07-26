// The notifications badge + panel. `useGitBranch` reaches for `git_branch`
// through `../lib/tauri`, so that one wrapper is mocked the same way the
// other component tests mock the surfaces they touch.
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { NotificationEntry } from "../state/notifications";

const mocks = vi.hoisted(() => ({ gitBranchMock: vi.fn() }));

vi.mock("../lib/tauri", () => ({ gitBranch: mocks.gitBranchMock }));

const { default: NotificationsPanel } = await import("./NotificationsPanel");

const NOW = 1_700_000_000_000;

function entry(over: Partial<NotificationEntry> = {}): NotificationEntry {
  return {
    id: "n1",
    sessionId: "sess-1",
    project: "p1",
    projectLabel: "OmniAgent ADE",
    cwd: "/repo/p1",
    engine: "claude",
    status: "ready",
    title: "wire session restore",
    createdAt: NOW,
    read: false,
    ...over,
  };
}

function setup(over: Partial<Parameters<typeof NotificationsPanel>[0]> = {}) {
  const props = {
    entries: [entry()],
    liveSessionIds: ["sess-1"],
    knownProjectIds: ["p1"],
    selectedProjectId: "p1",
    selectedProjectLabel: "OmniAgent ADE",
    onOpened: vi.fn(),
    onSelect: vi.fn(),
    onDismiss: vi.fn(),
    onClearAll: vi.fn(),
    now: NOW,
    ...over,
  };
  render(<NotificationsPanel {...props} />);
  return props;
}

function openPanel() {
  fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
}

beforeEach(() => {
  mocks.gitBranchMock.mockReset().mockResolvedValue("main");
});

describe("the badge", () => {
  it("counts only unread notifications", () => {
    setup({ entries: [entry(), entry({ id: "n2", sessionId: "s2" }), entry({ id: "n3", sessionId: "s3", read: true })] });
    expect(screen.getByRole("button", { name: "Notifications — 2 new" })).toBeInTheDocument();
    expect(screen.getByText("2")).toBeInTheDocument();
  });

  it("shows no count when everything has been seen", () => {
    setup({ entries: [entry({ read: true })] });
    expect(screen.getByRole("button", { name: "Notifications" })).toBeInTheDocument();
    expect(document.querySelector(".notifications-badge")).toBeNull();
  });

  it("caps a big count rather than stretching the badge", () => {
    const many = Array.from({ length: 12 }, (_, i) => entry({ id: `n${i}`, sessionId: `s${i}` }));
    setup({ entries: many });
    expect(screen.getByText("9+")).toBeInTheDocument();
  });

  it("says there is nothing new when the list is empty", () => {
    setup({ entries: [] });
    expect(screen.getByRole("button", { name: "Notifications — nothing new" })).toBeInTheDocument();
  });
});

describe("the panel", () => {
  it("stays closed until the badge is clicked", () => {
    setup();
    expect(screen.queryByRole("dialog", { name: "Notifications" })).not.toBeInTheDocument();
    openPanel();
    expect(screen.getByRole("dialog", { name: "Notifications" })).toBeInTheDocument();
  });

  it("marks everything read the moment it opens", () => {
    const props = setup();
    openPanel();
    expect(props.onOpened).toHaveBeenCalledTimes(1);
  });

  it("renders each entry with its title, what happened and when", () => {
    setup({ entries: [entry({ createdAt: NOW - 2 * 86_400_000 })] });
    openPanel();
    expect(screen.getByText("wire session restore")).toBeInTheDocument();
    expect(screen.getByText("Task completed.")).toBeInTheDocument();
    expect(screen.getByText("2 days ago")).toBeInTheDocument();
  });

  it("writes the right sentence for each notifying state", () => {
    setup({
      entries: [
        entry({ id: "a", sessionId: "s1", status: "ready" }),
        entry({ id: "b", sessionId: "s2", status: "awaiting_approval" }),
        entry({ id: "c", sessionId: "s3", status: "error" }),
      ],
    });
    openPanel();
    expect(screen.getByText("Task completed.")).toBeInTheDocument();
    expect(screen.getByText("Needs your approval.")).toBeInTheDocument();
    expect(screen.getByText("Error occurred.")).toBeInTheDocument();
  });

  it("shows the session's git branch once it resolves, and its project until then", async () => {
    setup();
    openPanel();
    expect(screen.getByText("OmniAgent ADE")).toBeInTheDocument(); // before the branch lands
    await waitFor(() => expect(screen.getByText(/main/)).toBeInTheDocument());
    expect(mocks.gitBranchMock).toHaveBeenCalledWith("/repo/p1");
  });

  it("falls back to the project label for a session that isn't in a repo", async () => {
    mocks.gitBranchMock.mockResolvedValue(null);
    setup();
    openPanel();
    await waitFor(() => expect(mocks.gitBranchMock).toHaveBeenCalled());
    expect(screen.getByText("OmniAgent ADE")).toBeInTheDocument();
  });

  it("closes on Escape and on the backdrop", () => {
    setup();
    openPanel();
    fireEvent.keyDown(screen.getByRole("dialog", { name: "Notifications" }), { key: "Escape" });
    expect(screen.queryByRole("dialog", { name: "Notifications" })).not.toBeInTheDocument();
    openPanel();
    fireEvent.mouseDown(document.querySelector(".notifications-backdrop")!);
    expect(screen.queryByRole("dialog", { name: "Notifications" })).not.toBeInTheDocument();
  });

  it("invites the user to do nothing at all when there is nothing", () => {
    setup({ entries: [] });
    openPanel();
    expect(screen.getByText(/Sessions tell you here/)).toBeInTheDocument();
  });
});

describe("navigating from a notification — the whole point of the feature", () => {
  it("clicking a row hands the entry back and closes the panel", () => {
    const props = setup();
    openPanel();
    fireEvent.click(screen.getByRole("button", { name: /Go to wire session restore/ }));
    expect(props.onSelect).toHaveBeenCalledWith(expect.objectContaining({ sessionId: "sess-1" }));
    expect(screen.queryByRole("dialog", { name: "Notifications" })).not.toBeInTheDocument();
  });

  it("still offers a row whose session has closed, as long as its project is around", () => {
    setup({ liveSessionIds: [], knownProjectIds: ["p1"] });
    openPanel();
    expect(screen.getByRole("button", { name: /Go to wire session restore/ })).toBeInTheDocument();
  });

  it("marks a row whose project is gone as stale instead of promising a jump", () => {
    setup({ liveSessionIds: [], knownProjectIds: [] });
    openPanel();
    expect(screen.getByRole("button", { name: /session closed/ })).toBeInTheDocument();
    expect(document.querySelector(".notification-row.is-stale")).not.toBeNull();
  });
});

describe("dismissing and filtering", () => {
  it("dismisses one row without closing the panel", () => {
    const props = setup();
    openPanel();
    fireEvent.click(screen.getByRole("button", { name: /Dismiss notification from wire session restore/ }));
    expect(props.onDismiss).toHaveBeenCalledWith("n1");
    expect(screen.getByRole("dialog", { name: "Notifications" })).toBeInTheDocument();
  });

  it("clears everything at once", () => {
    const props = setup();
    openPanel();
    fireEvent.click(screen.getByRole("button", { name: "Clear all" }));
    expect(props.onClearAll).toHaveBeenCalledTimes(1);
  });

  it("filters down to the selected project, and back", () => {
    setup({
      entries: [entry(), entry({ id: "n2", sessionId: "s2", project: "p2", projectLabel: "Other", title: "other work" })],
      knownProjectIds: ["p1", "p2"],
      liveSessionIds: ["sess-1", "s2"],
    });
    openPanel();
    expect(screen.getByRole("button", { name: "All sessions (2)" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "OmniAgent ADE (1)" }));
    const list = document.querySelector(".notifications-list")!;
    expect(within(list as HTMLElement).getByText("wire session restore")).toBeInTheDocument();
    expect(within(list as HTMLElement).queryByText("other work")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "All sessions (2)" }));
    expect(within(document.querySelector(".notifications-list") as HTMLElement).getByText("other work")).toBeInTheDocument();
  });

  it("cannot filter by project when no project is selected", () => {
    setup({ selectedProjectId: null, selectedProjectLabel: null });
    openPanel();
    expect(screen.getByRole("button", { name: "This project (0)" })).toBeDisabled();
  });
});

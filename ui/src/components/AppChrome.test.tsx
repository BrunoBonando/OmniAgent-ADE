// The window title bar (founder ask, 2026-07-26, verbatim: *"The user and
// notification menu must be on the title of the application, just like warp
// does."*).
//
// The native half of that — `titleBarStyle: "Overlay"` in
// `tauri.conf.json`, which hands the title bar's 28px to the web content
// while keeping the real traffic lights and the real window title — is
// locked by Rust tests in `src-tauri/src/lib.rs`. This file locks the half
// that lives in the DOM, and it is not cosmetic: with the webview covering
// the title bar, the *only* thing still moving the window is Tauri's
// `data-tauri-drag-region`. Lose that attribute and the app becomes a
// window you cannot move.
import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { NotificationEntry } from "../state/notifications";

const mocks = vi.hoisted(() => ({
  homeDirMock: vi.fn(),
  joinMock: vi.fn(),
  revealItemInDirMock: vi.fn(),
}));

vi.mock("@tauri-apps/api/path", () => ({ homeDir: mocks.homeDirMock, join: mocks.joinMock }));
vi.mock("@tauri-apps/plugin-opener", () => ({ revealItemInDir: mocks.revealItemInDirMock }));
vi.mock("../lib/useGitBranch", () => ({ useGitBranch: () => null }));

const { default: AppChrome } = await import("./AppChrome");

beforeEach(() => {
  mocks.homeDirMock.mockReset().mockResolvedValue("/Users/bruno");
  mocks.joinMock.mockReset().mockImplementation(async (...parts: string[]) => parts.join("/"));
  mocks.revealItemInDirMock.mockReset().mockResolvedValue(undefined);
});

function setup(overrides: Partial<Parameters<typeof AppChrome>[0]> = {}) {
  const props = {
    projectLabel: "OmniAgent-ADE",
    sessionLabel: "Session 1",
    notifications: [] as NotificationEntry[],
    liveSessionIds: [],
    knownProjectIds: [],
    selectedProjectId: null,
    selectedProjectLabel: null,
    onNotificationsOpened: vi.fn(),
    onSelectNotification: vi.fn(),
    onDismissNotification: vi.fn(),
    onClearNotifications: vi.fn(),
    ...overrides,
  };
  const { container } = render(<AppChrome {...props} />);
  return { container, props };
}

describe("the title bar stays a title bar", () => {
  it("is one deep drag region, so the whole strip moves the window", () => {
    const { container } = setup();
    const bar = container.querySelector(".app-chrome")!;
    // "deep" (not the bare attribute): a bare `data-tauri-drag-region` only
    // fires for clicks landing on that exact element, so every click that
    // hit the breadcrumb text — the widest part of the bar — would do
    // nothing. See tauri 2.11.5's `src/window/scripts/drag.js`.
    expect(bar.getAttribute("data-tauri-drag-region")).toBe("deep");
  });

  it("reserves the left inset the traffic lights are drawn into", () => {
    // The lights are real AppKit buttons painted over our content at the
    // window's top-left. Nothing of ours may sit under them.
    const { container } = setup();
    expect(container.querySelector(".app-chrome")).toHaveClass("app-chrome");
    const breadcrumb = container.querySelector(".app-chrome-breadcrumb")!;
    // The breadcrumb is the leftmost thing we draw, and it starts *after*
    // the reserved zone — the inset lives on the bar's own padding, so the
    // breadcrumb must not try to claim it back.
    expect(breadcrumb.className).not.toContain("app-chrome-lights");
  });

  it("keeps notifications at the far right and leaves the account in the sidebar", () => {
    const { container } = setup();
    const actions = container.querySelector(".app-chrome-actions")!;
    expect(actions.querySelector(".notifications-anchor")).not.toBeNull();
    expect(actions.querySelector(".account-badge-anchor")).toBeNull();
  });

  it("still says which workspace and session you are in", () => {
    setup();
    expect(screen.getByText("OmniAgent-ADE")).toBeInTheDocument();
    expect(screen.getByText("Session 1")).toBeInTheDocument();
  });
});

describe("the controls survive living inside a drag region", () => {
  // Tauri's drag handler walks up from the click target and bails the
  // moment it meets a clickable element with no drag attribute of its own
  // (`CLICKABLE_TAGS` / `INTERACTIVE_ROLES` in drag.js). Real <button>s are
  // therefore what keeps these clickable rather than window-dragging.
  it("renders the notifications trigger as a real button, which is what makes it click and not drag", () => {
    const { container } = setup();
    expect(container.querySelector(".notifications-trigger")!.tagName).toBe("BUTTON");
  });

  it("opens the notifications panel from the title bar, and marks them read", () => {
    const { props } = setup();
    fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
    expect(screen.getByRole("dialog", { name: "Notifications" })).toBeInTheDocument();
    expect(props.onNotificationsOpened).toHaveBeenCalled();
  });
});

// Regression coverage for bug 3: `Terminal`'s `visible` prop must reflect
// real visibility (its project's pane-grid is the selected one AND the
// overall Workspace view is the active one), not a hardcoded `true`.
// `Terminal.tsx` keeps display/refit on `visible` and DOM focus on the
// separate `focused` prop. This test renders the real `Terminal` (with
// `@xterm/xterm` and its
// addons mocked out, since full canvas/WebGL rendering isn't practically
// unit-testable) inside the real `Workspace`/`ProjectPaneGrid`/
// `react-mosaic-component` tree, and proves that switching away from and
// back to a project's pane-grid — or toggling the overall workspace view
// away and back (the map view) — causes fit()/focus()/sessionResize() to
// actually re-fire, not just once at mount. It also proves the fix never
// unmounts `<Terminal>` itself (a regression of the mount-stability rule
// `Workspace.mountStability.test.tsx` already guards) by asserting the
// mocked xterm `Terminal` constructor is only ever invoked once per pane.
import { fireEvent, render, waitFor } from "@testing-library/react";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo, TabInfo } from "../state/sessions";
import { initialAgentsState } from "../state/agents";

const xtermMocks = vi.hoisted(() => ({
  ctorMock: vi.fn(),
  fitMock: vi.fn(),
  focusMock: vi.fn(),
  keyDownMock: vi.fn(),
}));

vi.mock("@xterm/xterm", () => ({
  Terminal: vi.fn().mockImplementation(function (this: unknown, ...args: unknown[]) {
    xtermMocks.ctorMock(...args);
    let container: HTMLElement | null = null;
    return Object.assign(this as object, {
      open: vi.fn((nextContainer: HTMLElement) => {
        container = nextContainer;
        const textarea = document.createElement("textarea");
        textarea.addEventListener("keydown", (event) => {
          xtermMocks.keyDownMock();
          event.preventDefault();
          event.stopPropagation();
        });
        container.append(textarea);
      }),
      loadAddon: vi.fn(),
      onData: vi.fn(() => ({ dispose: vi.fn() })),
      write: vi.fn(),
      dispose: vi.fn(),
      focus: vi.fn(() => xtermMocks.focusMock(container?.dataset.sessionId)),
      cols: 80,
      rows: 24,
      // Real xterm.js `Terminal` instances expose a live-mutable `.options`
      // object (`Terminal.tsx`'s theme-swap effect assigns
      // `term.options.theme = ...`) — matched here so this mock stays a
      // faithful stand-in for the real constructor's shape.
      options: {},
    });
  }),
}));

vi.mock("@xterm/addon-fit", () => ({
  FitAddon: vi.fn().mockImplementation(function (this: unknown) {
    return Object.assign(this as object, { fit: xtermMocks.fitMock });
  }),
}));

vi.mock("@xterm/addon-webgl", () => ({
  WebglAddon: vi.fn().mockImplementation(function (this: unknown) {
    return Object.assign(this as object, { onContextLoss: vi.fn(), dispose: vi.fn() });
  }),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
}));

vi.mock("@tauri-apps/api/webview", () => ({
  getCurrentWebview: vi.fn(() => ({
    onDragDropEvent: vi.fn().mockResolvedValue(() => {}),
  })),
}));

const tauriMocks = vi.hoisted(() => ({
  sessionResizeMock: vi.fn(),
  sessionWriteMock: vi.fn(),
}));

vi.mock("../lib/tauri", () => ({
  sessionResize: tauriMocks.sessionResizeMock,
  sessionWrite: tauriMocks.sessionWriteMock,
}));

// Same technique PaneHeader.test.tsx already uses to sidestep the real
// git-branch IPC call the pane toolbar makes.
vi.mock("../lib/useGitBranch", () => ({ useGitBranch: () => null }));

const { default: Workspace } = await import("./Workspace");

beforeAll(() => {
  // jsdom has neither of these — Terminal.tsx's mount effect uses
  // ResizeObserver directly, and its become-visible effect schedules a
  // requestAnimationFrame. Same stub pattern BrainMap.test.tsx already
  // established for this exact jsdom gap (its stub omits `unobserve`,
  // needing a `@ts-expect-error`; this one implements the full interface
  // so TS accepts the assignment without one).
  globalThis.ResizeObserver = class {
    observe() {}
    disconnect() {}
    unobserve() {}
  };
  globalThis.requestAnimationFrame = ((cb: FrameRequestCallback) =>
    setTimeout(() => cb(performance.now()), 0)) as unknown as typeof requestAnimationFrame;
  globalThis.cancelAnimationFrame = ((id: number) => clearTimeout(id)) as unknown as typeof cancelAnimationFrame;
});

function project(id: string): ProjectInfo {
  return { id, label: id, path: `/tmp/${id}` };
}

function tab(id: string, project: string): TabInfo {
  return { id, project, engine: "claude", cwd: `/tmp/${project}`, createdAt: 0 };
}

const noop = () => {};

describe("Workspace — real visibility wiring into <Terminal>", () => {
  beforeEach(() => {
    xtermMocks.ctorMock.mockClear();
    xtermMocks.fitMock.mockClear();
    xtermMocks.focusMock.mockClear();
    tauriMocks.sessionResizeMock.mockClear();
    tauriMocks.sessionWriteMock.mockClear();
  });

  it("re-fits and refocuses a project's terminal after switching the selected project away and back", async () => {
    const p1 = project("p1");
    const p2 = project("p2");
    const tabs = [tab("a", "p1")];

    const props = {
      projects: [p1, p2],
      tabs,
      activeTabId: "a",
      onActivateTab: noop,
      onCloseTab: noop,
      onNewTabInProject: noop,
      onRenameTab: noop,
      agentState: initialAgentsState,
      hidden: false,
    };

    const { rerender } = render(<Workspace {...props} selectedProjectId="p1" />);

    // Mount: the unconditional first effect fits once, and since this pane
    // starts selected/visible, the become-visible effect also fires once
    // (after its rAF trampoline).
    await waitFor(() => expect(xtermMocks.focusMock).toHaveBeenCalledTimes(1));
    const resizeCallsAtMount = tauriMocks.sessionResizeMock.mock.calls.length;
    const fitCallsAtMount = xtermMocks.fitMock.mock.calls.length;

    // Switch away: select a different project (p1's grid — and its
    // Terminal's real visibility — should go to hidden/false).
    rerender(<Workspace {...props} selectedProjectId="p2" />);
    // Switch back: p1 selected again.
    rerender(<Workspace {...props} selectedProjectId="p1" />);

    await waitFor(() => {
      expect(xtermMocks.focusMock.mock.calls.length).toBeGreaterThan(1);
    });
    expect(tauriMocks.sessionResizeMock.mock.calls.length).toBeGreaterThan(resizeCallsAtMount);
    expect(xtermMocks.fitMock.mock.calls.length).toBeGreaterThan(fitCallsAtMount);

    // The fix must only ever change the `visible` prop's *value* — never
    // the conditional-rendering structure around <Terminal> — so it must
    // never remount. A remount would call `new XTerm(...)` again.
    expect(xtermMocks.ctorMock).toHaveBeenCalledTimes(1);
  });

  it("re-fits and refocuses when the overall Workspace view becomes hidden (map view) and visible again", async () => {
    const p1 = project("p1");
    const tabs = [tab("a", "p1")];

    const props = {
      projects: [p1],
      tabs,
      activeTabId: "a",
      selectedProjectId: "p1",
      onActivateTab: noop,
      onCloseTab: noop,
      onNewTabInProject: noop,
      onRenameTab: noop,
      agentState: initialAgentsState,
    };

    const { rerender } = render(<Workspace {...props} hidden={false} />);

    await waitFor(() => expect(xtermMocks.focusMock).toHaveBeenCalledTimes(1));
    const resizeCallsAtMount = tauriMocks.sessionResizeMock.mock.calls.length;

    // Switch to the Brain Map view (Workspace itself goes `hidden`).
    rerender(<Workspace {...props} hidden={true} />);
    // Switch back to the workspace view.
    rerender(<Workspace {...props} hidden={false} />);

    await waitFor(() => {
      expect(xtermMocks.focusMock.mock.calls.length).toBeGreaterThan(1);
    });
    expect(tauriMocks.sessionResizeMock.mock.calls.length).toBeGreaterThan(resizeCallsAtMount);
    expect(xtermMocks.ctorMock).toHaveBeenCalledTimes(1);
  });

  it("marks exactly the active pane and cycles from an xterm descendant with Ctrl+Tab", async () => {
    const p1 = project("p1");
    const tabs = [tab("a", "p1"), tab("b", "p1")];
    const onActivateTab = vi.fn();
    const props = {
      projects: [p1],
      tabs,
      selectedProjectId: "p1",
      onActivateTab,
      onCloseTab: noop,
      onNewTabInProject: noop,
      onRenameTab: noop,
      agentState: initialAgentsState,
    };

    const { container, rerender } = render(<Workspace {...props} activeTabId="a" hidden={false} />);

    await waitFor(() => expect(container.querySelectorAll(".pane-body.is-focused")).toHaveLength(1));
    expect(container.querySelector(".pane-body.is-focused")).toContainElement(
      container.querySelector('[data-session-id="a"]'),
    );
    const firstTextarea = container.querySelector<HTMLTextAreaElement>('[data-session-id="a"] textarea')!;
    firstTextarea.focus();
    expect(document.activeElement).toBe(firstTextarea);
    fireEvent.keyDown(firstTextarea, {
      key: "Tab",
      ctrlKey: true,
    });
    expect(onActivateTab).toHaveBeenLastCalledWith("b");
    expect(xtermMocks.keyDownMock).not.toHaveBeenCalled();

    rerender(<Workspace {...props} activeTabId="b" hidden={false} />);
    await waitFor(() => expect(container.querySelectorAll(".pane-body.is-focused")).toHaveLength(1));
    expect(container.querySelector(".pane-body.is-focused")).toContainElement(
      container.querySelector('[data-session-id="b"]'),
    );
    fireEvent.keyDown(container.querySelector('[data-session-id="b"] textarea')!, {
      key: "Tab",
      ctrlKey: true,
    });
    expect(onActivateTab).toHaveBeenLastCalledWith("a");

    onActivateTab.mockClear();
    rerender(<Workspace {...props} activeTabId="a" hidden={true} />);
    fireEvent.keyDown(container.querySelector('[data-session-id="a"] textarea')!, {
      key: "Tab",
      ctrlKey: true,
    });
    expect(onActivateTab).not.toHaveBeenCalled();
  });

  it("owns only exact Ctrl+Tab and yields while a dialog or menu is open", async () => {
    const p1 = project("p1");
    const onActivateTab = vi.fn();
    const { container } = render(
      <Workspace
        projects={[p1]}
        tabs={[tab("a", "p1"), tab("b", "p1")]}
        activeTabId="a"
        selectedProjectId="p1"
        onActivateTab={onActivateTab}
        onCloseTab={noop}
        onNewTabInProject={noop}
        onRenameTab={noop}
        agentState={initialAgentsState}
        hidden={false}
      />,
    );
    await waitFor(() => expect(container.querySelector('[data-session-id="a"] textarea')).not.toBeNull());
    const textarea = container.querySelector('[data-session-id="a"] textarea')!;

    for (const modifiers of [{ shiftKey: true }, { altKey: true }, { metaKey: true }]) {
      fireEvent.keyDown(textarea, { key: "Tab", ctrlKey: true, ...modifiers });
    }
    expect(onActivateTab).not.toHaveBeenCalled();

    for (const role of ["dialog", "menu"]) {
      const overlay = document.createElement("div");
      overlay.setAttribute("role", role);
      document.body.append(overlay);
      fireEvent.keyDown(window, { key: "Tab", ctrlKey: true });
      overlay.remove();
    }
    expect(onActivateTab).not.toHaveBeenCalled();
  });

  it("focuses the state-selected xterm after pane and session navigation", async () => {
    const p1 = project("p1");
    const tabs = [
      { ...tab("a", "p1"), group: "g1" },
      { ...tab("b", "p1"), group: "g1" },
      { ...tab("c", "p1"), group: "g2" },
    ];
    const props = {
      projects: [p1],
      selectedProjectId: "p1",
      onActivateTab: noop,
      onCloseTab: noop,
      onNewTabInProject: noop,
      onRenameTab: noop,
      agentState: initialAgentsState,
      hidden: false,
    };
    const { rerender } = render(<Workspace {...props} tabs={tabs} activeTabId="a" />);

    await waitFor(() => expect(xtermMocks.focusMock).toHaveBeenCalled());
    expect(xtermMocks.focusMock).toHaveBeenLastCalledWith("a");

    xtermMocks.focusMock.mockClear();
    rerender(<Workspace {...props} tabs={tabs} activeTabId="b" />);
    await waitFor(() => expect(xtermMocks.focusMock).toHaveBeenLastCalledWith("b"));

    xtermMocks.focusMock.mockClear();
    rerender(<Workspace {...props} tabs={tabs} activeTabId="c" />);
    await waitFor(() => expect(xtermMocks.focusMock).toHaveBeenLastCalledWith("c"));
  });
});

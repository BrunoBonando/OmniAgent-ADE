// ⌘W closes the focused *pane*, with a confirmation (founder bug, Bruno,
// 2026-07-26, verbatim: *"cmd+w is closing the full app instead of confirming
// closing the current terminal"*).
//
// Two halves, and this file only covers one of them. The native half — macOS
// handling ⌘W as a menu accelerator before the webview ever sees the key — is
// fixed in `src-tauri/src/lib.rs` (`build_menu` / `MENU_BAR`) and pinned by
// its own Rust test; no JS test can observe it, because in jsdom there is no
// native menu to race. What is testable here is everything after that: that
// ⌘W reaches the app, asks first, kills the right session on confirm, kills
// nothing on cancel, and does something sane when there is no pane at all.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { NOTIFICATIONS_SETTING_KEY } from "./state/notifications";
import { LAYOUT_SETTING_KEY, type ProjectInfo, type TabInfo } from "./state/sessions";
import {
  AUTH_GATE_RESOLVED_SETTING_KEY,
  AUTH_PERSONA_SETTING_KEY,
  AUTH_SIGNED_IN_SETTING_KEY,
} from "./onboarding/authGateState";

const tauriMocks = vi.hoisted(() => ({
  getBriefingMock: vi.fn(),
  ingestionStatusMock: vi.fn(),
  listProjectsMock: vi.fn(),
  rootsListMock: vi.fn(),
  sessionCreateMock: vi.fn(),
  sessionKillMock: vi.fn(),
  sessionStatusMock: vi.fn(),
  settingsGetMock: vi.fn(),
  settingsSetMock: vi.fn(),
}));

vi.mock("./lib/tauri", () => ({
  FILE_TREE_VISIBLE_SETTING_KEY: "file_tree_visible",
  getBriefing: tauriMocks.getBriefingMock,
  ingestionStatus: tauriMocks.ingestionStatusMock,
  listProjects: tauriMocks.listProjectsMock,
  rootsList: tauriMocks.rootsListMock,
  sessionCreate: tauriMocks.sessionCreateMock,
  sessionKill: tauriMocks.sessionKillMock,
  sessionStatus: tauriMocks.sessionStatusMock,
  settingsGet: tauriMocks.settingsGetMock,
  settingsSet: tauriMocks.settingsSetMock,
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
}));

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    projects: ProjectInfo[];
    onNewTabInProject: (p: ProjectInfo) => void;
  }) {
    return (
      <div>
        {props.projects.map((p) => (
          <button key={p.id} onClick={() => props.onNewTabInProject(p)}>
            {`new-tab-${p.id}`}
          </button>
        ))}
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: { tabs: TabInfo[]; activeTabId: string | null }) {
    return (
      <ul>
        {props.tabs.map((t) => (
          <li key={t.id} data-testid="tab-info">
            {`${t.id}${t.id === props.activeTabId ? "*" : ""}`}
          </li>
        ))}
      </ul>
    );
  },
}));
vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({ default: () => null }));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));

const { default: App } = await import("./App");

const PROJECT: ProjectInfo = { id: "A", label: "Project A", path: "/tmp/a" };

function pressCmdW() {
  fireEvent.keyDown(window, { key: "w", metaKey: true });
}

/** Renders the app with one open pane and returns its session id. */
async function renderWithOnePane(): Promise<string> {
  render(<App />);
  fireEvent.click(await screen.findByRole("button", { name: "new-tab-A" }));
  await waitFor(() => expect(screen.getByText("A-sess*")).toBeInTheDocument());
  return "A-sess";
}

describe("⌘W closes the focused terminal, not the app", () => {
  beforeEach(() => {
    for (const mock of Object.values(tauriMocks)) mock.mockReset();
    tauriMocks.sessionStatusMock.mockResolvedValue(null);
    tauriMocks.ingestionStatusMock.mockResolvedValue({
      running: false,
      projects_total: 0,
      projects_done: 0,
      total_nodes: 0,
    });
    tauriMocks.rootsListMock.mockResolvedValue(["/tmp/root"]);
    tauriMocks.settingsSetMock.mockResolvedValue(undefined);
    tauriMocks.getBriefingMock.mockResolvedValue(undefined);
    tauriMocks.listProjectsMock.mockResolvedValue([PROJECT]);
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (
        key === LAYOUT_SETTING_KEY ||
        key === "file_tree_visible" ||
        key === AUTH_GATE_RESOLVED_SETTING_KEY ||
        key === AUTH_SIGNED_IN_SETTING_KEY ||
        key === AUTH_PERSONA_SETTING_KEY ||
        key === NOTIFICATIONS_SETTING_KEY
      ) {
        return Promise.resolve(null);
      }
      return Promise.resolve(null);
    });
    tauriMocks.sessionCreateMock.mockResolvedValue({
      id: "A-sess",
      project: "A",
      engine: "claude",
      cwd: "/tmp/a",
      created: 0,
    });
    tauriMocks.sessionKillMock.mockResolvedValue(undefined);
  });

  it("asks before closing — a bare ⌘W kills nothing", async () => {
    await renderWithOnePane();

    pressCmdW();

    expect(await screen.findByRole("dialog", { name: /close/i })).toBeInTheDocument();
    expect(tauriMocks.sessionKillMock).not.toHaveBeenCalled();
    expect(screen.getByTestId("tab-info")).toBeInTheDocument();
  });

  it("confirming closes that session's pane", async () => {
    const id = await renderWithOnePane();

    pressCmdW();
    fireEvent.click(await screen.findByRole("button", { name: /close terminal/i }));

    await waitFor(() => expect(tauriMocks.sessionKillMock).toHaveBeenCalledWith(id));
    await waitFor(() => expect(screen.queryByTestId("tab-info")).not.toBeInTheDocument());
  });

  it("Enter confirms — the whole flow is two keystrokes and no mouse", async () => {
    const id = await renderWithOnePane();

    pressCmdW();
    const dialog = await screen.findByRole("dialog", { name: /close/i });
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(tauriMocks.sessionKillMock).toHaveBeenCalledWith(id));
  });

  it("cancelling leaves the pane exactly where it was", async () => {
    await renderWithOnePane();

    pressCmdW();
    fireEvent.click(await screen.findByRole("button", { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: /close/i })).not.toBeInTheDocument(),
    );
    expect(tauriMocks.sessionKillMock).not.toHaveBeenCalled();
    expect(screen.getByTestId("tab-info")).toBeInTheDocument();
  });

  it("Esc cancels", async () => {
    await renderWithOnePane();

    pressCmdW();
    const dialog = await screen.findByRole("dialog", { name: /close/i });
    fireEvent.keyDown(dialog, { key: "Escape" });

    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: /close/i })).not.toBeInTheDocument(),
    );
    expect(tauriMocks.sessionKillMock).not.toHaveBeenCalled();
  });

  it("with no pane open it says so instead of doing nothing silently", async () => {
    render(<App />);
    await screen.findByRole("button", { name: "new-tab-A" });

    pressCmdW();

    // Not a confirmation for a pane that doesn't exist, not a kill, and not
    // the silent no-op that would leave the user wondering whether ⌘W works.
    expect(screen.queryByRole("dialog", { name: /close/i })).not.toBeInTheDocument();
    expect(tauriMocks.sessionKillMock).not.toHaveBeenCalled();
    expect(await screen.findByText(/no terminal/i)).toBeInTheDocument();
  });

  it("closes the FOCUSED pane when several are open", async () => {
    render(<App />);
    tauriMocks.sessionCreateMock.mockResolvedValueOnce({
      id: "first",
      project: "A",
      engine: "claude",
      cwd: "/tmp/a",
      created: 0,
    });
    fireEvent.click(await screen.findByRole("button", { name: "new-tab-A" }));
    await waitFor(() => expect(screen.getByText("first*")).toBeInTheDocument());

    tauriMocks.sessionCreateMock.mockResolvedValueOnce({
      id: "second",
      project: "A",
      engine: "claude",
      cwd: "/tmp/a",
      created: 0,
    });
    fireEvent.click(screen.getByRole("button", { name: "new-tab-A" }));
    await waitFor(() => expect(screen.getByText("second*")).toBeInTheDocument());

    pressCmdW();
    fireEvent.click(await screen.findByRole("button", { name: /close terminal/i }));

    // The newest tab is the focused one, so that is the one that goes.
    await waitFor(() => expect(tauriMocks.sessionKillMock).toHaveBeenCalledWith("second"));
    expect(tauriMocks.sessionKillMock).not.toHaveBeenCalledWith("first");
  });
});

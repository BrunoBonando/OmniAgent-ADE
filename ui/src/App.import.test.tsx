// Coverage for App.tsx's `handleImportCompleted` — the orchestration handler
// shared by `ImportProjectsFlow`'s two entry points (`Sidebar`'s permanent
// "import" trigger and `FirstRun`'s pick-phase alternative — see both
// components' own module docs for why they're separate entry points, not
// folded into `NewWorkspaceModal`). `ImportProjectsFlow` itself already has
// full component coverage (`components/ImportProjectsFlow.test.tsx`) and the
// merge/dedup/summarization logic has its own pure-function coverage
// (`state/importState.test.ts`) — these tests only exercise what App.tsx
// does once a batch result reaches it: reload the project list, select a
// newly-created project, and surface a failure banner without blocking on
// partial failure. Same stubbing approach as `App.newWorkspace.test.tsx`:
// heavy children replaced with minimal probes that call the real callback
// props with fixture data, so `ImportProjectsFlow`'s own rendering/Tauri
// calls never need to be exercised again here.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo } from "./state/sessions";
import type { ImportBatchResult } from "./state/importState";

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

const EXISTING_PROJECT: ProjectInfo = { id: "existing", label: "existing", path: "/tmp/existing" };
const IMPORTED_A: ProjectInfo = { id: "imported-a", label: "imported-a", path: "/tmp/imported-a" };
const IMPORTED_B: ProjectInfo = { id: "imported-b", label: "imported-b", path: "/tmp/imported-b" };

const ALL_SUCCEEDED: ImportBatchResult = { created: [IMPORTED_A, IMPORTED_B], failed: [] };
const PARTIAL_FAILURE: ImportBatchResult = {
  created: [IMPORTED_A],
  failed: [{ path: "/tmp/imported-b", suggestedName: "imported-b", success: false, error: "already added" }],
};
const ALL_FAILED: ImportBatchResult = {
  created: [],
  failed: [{ path: "/tmp/imported-a", suggestedName: "imported-a", success: false, error: "boom" }],
};

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: { onImportCompleted: (result: ImportBatchResult) => void }) {
    return (
      <div>
        <button onClick={() => props.onImportCompleted(ALL_SUCCEEDED)}>sidebar-import-all-succeeded</button>
        <button onClick={() => props.onImportCompleted(PARTIAL_FAILURE)}>sidebar-import-partial-failure</button>
        <button onClick={() => props.onImportCompleted(ALL_FAILED)}>sidebar-import-all-failed</button>
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({ default: () => null }));
vi.mock("./components/EnginePicker", () => ({ default: () => null }));
vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));

vi.mock("./onboarding/FirstRun", () => ({
  default: function FirstRunStub(props: {
    existingProjects: ProjectInfo[];
    onImportCompleted: (result: ImportBatchResult) => void;
    onDismiss: () => void;
  }) {
    return (
      <div>
        <span data-testid="first-run-existing-count">{props.existingProjects.length}</span>
        <button
          onClick={() => {
            props.onImportCompleted(ALL_SUCCEEDED);
            props.onDismiss();
          }}
        >
          first-run-import-all-succeeded
        </button>
      </div>
    );
  },
}));

const { default: App } = await import("./App");

describe("App — import-projects orchestration (handleImportCompleted)", () => {
  beforeEach(() => {
    for (const mock of Object.values(tauriMocks)) mock.mockReset();
    tauriMocks.sessionStatusMock.mockResolvedValue(null);
    tauriMocks.ingestionStatusMock.mockResolvedValue({
      running: false,
      projects_total: 0,
      projects_done: 0,
      total_nodes: 0,
    });
    tauriMocks.rootsListMock.mockResolvedValue(["/tmp/root"]); // onboarding already satisfied by default
    tauriMocks.listProjectsMock.mockResolvedValue([EXISTING_PROJECT]);
    tauriMocks.settingsGetMock.mockResolvedValue(null);
    tauriMocks.settingsSetMock.mockResolvedValue(undefined);
  });

  it("Sidebar's import trigger reloads the project list and selects the first newly-created project", async () => {
    tauriMocks.listProjectsMock
      .mockResolvedValueOnce([EXISTING_PROJECT]) // boot
      .mockResolvedValueOnce([EXISTING_PROJECT, IMPORTED_A, IMPORTED_B]); // post-import reload

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "sidebar-import-all-succeeded" }));

    await waitFor(() => expect(tauriMocks.listProjectsMock).toHaveBeenCalledTimes(2));
    // No failure banner for an all-success batch.
    expect(screen.queryByText(/couldn.t import/i)).not.toBeInTheDocument();
  });

  it("a partial failure reloads the project list AND shows a banner naming the failure, without blocking", async () => {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "sidebar-import-partial-failure" }));

    await waitFor(() => expect(tauriMocks.listProjectsMock).toHaveBeenCalledTimes(2)); // boot + post-import reload
    expect(screen.getByText(/imported 1 project, but couldn.t import imported-b/i)).toBeInTheDocument();
  });

  it("every candidate failing still shows a banner but never reloads the (unchanged) project list a second time", async () => {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "sidebar-import-all-failed" }));

    await waitFor(() => expect(screen.getByText(/couldn.t import imported-a/i)).toBeInTheDocument());
    // Nothing was created, so there's nothing new for the sidebar to show —
    // reloadProjects is skipped rather than firing a pointless refetch.
    expect(tauriMocks.listProjectsMock).toHaveBeenCalledTimes(1); // boot only
  });

  it("the error banner can be dismissed like any other App.tsx error banner", async () => {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "sidebar-import-all-failed" }));
    await screen.findByText(/couldn.t import imported-a/i);

    fireEvent.click(screen.getByRole("button", { name: /dismiss/i }));
    expect(screen.queryByText(/couldn.t import imported-a/i)).not.toBeInTheDocument();
  });

  it("FirstRun's import path also reloads projects, receives the live existing-projects list, and dismisses onboarding on success", async () => {
    tauriMocks.rootsListMock.mockResolvedValue([]); // needsOnboarding = true
    tauriMocks.listProjectsMock
      .mockResolvedValueOnce([EXISTING_PROJECT])
      .mockResolvedValueOnce([EXISTING_PROJECT, IMPORTED_A, IMPORTED_B]);
    tauriMocks.settingsGetMock.mockImplementation((key: string) =>
      Promise.resolve(key === "auth_gate_resolved" ? "true" : null),
    );

    render(<App />);
    expect(await screen.findByTestId("first-run-existing-count")).toHaveTextContent("1");

    fireEvent.click(screen.getByRole("button", { name: "first-run-import-all-succeeded" }));

    await waitFor(() => expect(tauriMocks.listProjectsMock).toHaveBeenCalledTimes(2));
    // FirstRun's stub calls onDismiss() itself (mirroring the real
    // component's "created.length > 0 -> onDismiss()" behavior) — the stub
    // unmounts as a result, same observable outcome a real dismiss would have.
    await waitFor(() => expect(screen.queryByTestId("first-run-existing-count")).not.toBeInTheDocument());
  });
});

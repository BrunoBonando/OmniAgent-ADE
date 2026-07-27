import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo } from "../state/sessions";

const { readTextFileMock, writeTextFileMock } = vi.hoisted(() => ({
  readTextFileMock: vi.fn(),
  writeTextFileMock: vi.fn(),
}));

vi.mock("../lib/tauri", () => ({
  readTextFile: readTextFileMock,
  writeTextFile: writeTextFileMock,
}));

const { default: FilesDashboard } = await import("./FilesDashboard");

const PROJECT: ProjectInfo = { id: "p1", label: "OmniAgent", path: "/repo/omniagent" };

describe("FilesDashboard", () => {
  beforeEach(() => {
    readTextFileMock.mockReset();
    writeTextFileMock.mockReset();
    readTextFileMock.mockResolvedValue("line 1\nline 2");
    writeTextFileMock.mockResolvedValue(undefined);
  });

  it("opens file tabs from open requests", async () => {
    render(
      <FilesDashboard
        project={PROJECT}
        hidden={false}
        openRequest={{ path: "/repo/omniagent/src/main.ts", nonce: 1 }}
      />,
    );
    expect(await screen.findByText("main.ts")).toBeInTheDocument();
    expect(readTextFileMock).toHaveBeenCalledWith("/repo/omniagent", "/repo/omniagent/src/main.ts");
  });

  it("saves edited content", async () => {
    render(
      <FilesDashboard
        project={PROJECT}
        hidden={false}
        openRequest={{ path: "/repo/omniagent/src/main.ts", nonce: 1 }}
      />,
    );
    const editor = await screen.findByRole("textbox");
    fireEvent.change(editor, { target: { value: "edited" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() =>
      expect(writeTextFileMock).toHaveBeenCalledWith("/repo/omniagent", "/repo/omniagent/src/main.ts", "edited"),
    );
  });
});


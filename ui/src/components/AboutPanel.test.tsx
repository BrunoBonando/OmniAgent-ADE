// The About panel's version line, which used to be the literal string
// `v0.1.0 — dogfood build` typed into the JSX.
//
// That literal was a second copy of a number that already has an owner:
// `tauri.conf.json`'s `version` field, which `tauri::generate_context!`
// compiles into `PackageInfo::version` (the window title reads it there —
// see `src-tauri/src/lib.rs`'s `window_title`) and which the bundler stamps
// into the `.app`. Two copies of a version drift on exactly one occasion —
// the next release — and the copy that drifts is always the one nobody
// remembers, so this asserts the panel reads the *runtime* value and can
// never print a number of its own.
import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getVersionMock: vi.fn(),
  settingsGetMock: vi.fn(),
  rootsRebuildMock: vi.fn(),
}));

vi.mock("@tauri-apps/api/app", () => ({
  getVersion: mocks.getVersionMock,
}));

vi.mock("../lib/tauri", () => ({
  settingsGet: mocks.settingsGetMock,
  rootsRebuild: mocks.rootsRebuildMock,
}));

const { default: AboutPanel, aboutVersionLine } = await import("./AboutPanel");

beforeEach(() => {
  mocks.getVersionMock.mockReset().mockResolvedValue("0.1.0");
  mocks.settingsGetMock.mockReset().mockResolvedValue(null);
  mocks.rootsRebuildMock.mockReset().mockResolvedValue(undefined);
});

describe("aboutVersionLine — the one place the string is shaped", () => {
  it("prefixes the runtime version and keeps the build's own name", () => {
    expect(aboutVersionLine("0.1.0")).toBe("v0.1.0 — dogfood build");
    expect(aboutVersionLine("2.3")).toBe("v2.3 — dogfood build");
  });

  it("has nothing to say before the version arrives (or if the call fails)", () => {
    expect(aboutVersionLine(null)).toBeNull();
  });
});

describe("AboutPanel — the version comes from the running app", () => {
  it("prints whatever version the app reports, not a number of its own", async () => {
    mocks.getVersionMock.mockResolvedValue("9.9.9");
    render(<AboutPanel onClose={() => {}} />);

    // The whole point: a hardcoded `v0.1.0` would fail here.
    await waitFor(() => expect(screen.getByText("v9.9.9 — dogfood build")).toBeInTheDocument());
  });

  it("asks the app exactly once, through Tauri's own app-version API", async () => {
    render(<AboutPanel onClose={() => {}} />);
    await waitFor(() => expect(screen.getByText("v0.1.0 — dogfood build")).toBeInTheDocument());
    expect(mocks.getVersionMock).toHaveBeenCalledTimes(1);
  });

  it("stays open and readable when the version can't be read at all", async () => {
    mocks.getVersionMock.mockRejectedValue(new Error("no ipc"));
    render(<AboutPanel onClose={() => {}} />);

    // The panel is still the branding surface it was — it just doesn't
    // claim a version it doesn't know.
    await waitFor(() => expect(screen.getByText("OmniAgent ADE")).toBeInTheDocument());
    expect(screen.queryByText(/dogfood build/)).not.toBeInTheDocument();
  });
});

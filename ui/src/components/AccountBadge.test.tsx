// The account badge + its user menu (founder ask, 2026-07-26). Mocks the
// same two Tauri surfaces the one genuinely-wired filesystem row touches —
// `@tauri-apps/api/path` and `@tauri-apps/plugin-opener` — the same way
// `FileTree.test.tsx` already does for its reveal-in-Finder action.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  homeDirMock: vi.fn(),
  joinMock: vi.fn(),
  revealItemInDirMock: vi.fn(),
}));

vi.mock("@tauri-apps/api/path", () => ({
  homeDir: mocks.homeDirMock,
  join: mocks.joinMock,
}));

vi.mock("@tauri-apps/plugin-opener", () => ({
  revealItemInDir: mocks.revealItemInDirMock,
}));

const { default: AccountBadge } = await import("./AccountBadge");

/** Default props = the app's own default state: signed in as the fake dev
 * identity (nothing written to the settings table yet). */
function setup(overrides: Partial<Parameters<typeof AccountBadge>[0]> = {}) {
  const onResetAuthGate = vi.fn();
  const onOpenReview = vi.fn();
  const onOpenAbout = vi.fn();
  render(
    <AccountBadge
      signedInRaw={null}
      personaRaw={null}
      onResetAuthGate={onResetAuthGate}
      onOpenReview={onOpenReview}
      onOpenAbout={onOpenAbout}
      {...overrides}
    />,
  );
  return { onResetAuthGate, onOpenReview, onOpenAbout };
}

function openMenu(name = "Bruno Bonando — account menu") {
  fireEvent.click(screen.getByRole("button", { name }));
}

beforeEach(() => {
  mocks.homeDirMock.mockReset().mockResolvedValue("/Users/bruno");
  mocks.joinMock.mockReset().mockImplementation(async (...parts: string[]) => parts.join("/"));
  mocks.revealItemInDirMock.mockReset().mockResolvedValue(undefined);
});

describe("AccountBadge — the fake signed-in default", () => {
  it("reads as Bruno Bonando with no settings written at all", () => {
    setup();
    expect(screen.getByRole("button", { name: "Bruno Bonando — account menu" })).toBeInTheDocument();
    expect(screen.getByText("B")).toBeInTheDocument();
    expect(screen.getByText("Bruno Bonando")).toBeInTheDocument();
  });

  it("names the user in the menu header, over an honest dev-mode subtitle", () => {
    setup();
    openMenu();
    expect(screen.getByRole("menu")).toHaveTextContent("Bruno Bonando");
    expect(screen.getByRole("menu")).toHaveTextContent(/dev mode/);
  });

  it("shows the captured persona as the subtitle once there is one", () => {
    setup({ signedInRaw: "true", personaRaw: "data-ml" });
    openMenu();
    expect(screen.getByText("Data & ML")).toBeInTheDocument();
  });

  it("the menu is closed until the trigger is clicked, and closes again on a second click", () => {
    setup();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    openMenu();
    expect(screen.getByRole("menu")).toBeInTheDocument();
    openMenu();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("clicking the backdrop closes the menu without doing anything", () => {
    const { onResetAuthGate } = setup();
    openMenu();
    fireEvent.mouseDown(document.querySelector(".account-menu-backdrop")!);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(onResetAuthGate).not.toHaveBeenCalled();
  });
});

describe("AccountBadge — sidebar destinations", () => {
  it("opens session review from the submenu and closes it", () => {
    const { onOpenReview } = setup();
    openMenu();
    fireEvent.click(screen.getByRole("menuitem", { name: "Review session summaries" }));
    expect(onOpenReview).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("opens About from the submenu and closes it", () => {
    const { onOpenAbout } = setup();
    openMenu();
    fireEvent.click(screen.getByRole("menuitem", { name: "About OmniAgent ADE" }));
    expect(onOpenAbout).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });
});

describe("AccountBadge — brain status sub-line (Task 8)", () => {
  it("renders the brain line under the account name, toned by its status", () => {
    setup({ brainLine: { text: "Brain indexed · 8m ago", tone: "good" } });
    const line = screen.getByText("Brain indexed · 8m ago");
    expect(line).toHaveClass("account-badge-brain", "is-good");
  });

  it("shows the busy tone while ingestion is running", () => {
    setup({ brainLine: { text: "Ingesting · 1 of 4 projects", tone: "busy" } });
    expect(screen.getByText("Ingesting · 1 of 4 projects")).toHaveClass("is-busy");
  });

  it("renders nothing extra under the name when no brain line is passed", () => {
    setup();
    expect(document.querySelector(".account-badge-brain")).not.toBeInTheDocument();
  });
});

describe("AccountBadge — signed out", () => {
  it("falls back to the neutral placeholder trigger and swaps Log out for Sign in", () => {
    setup({ signedInRaw: "false" });
    expect(screen.getByRole("button", { name: "Not signed in — account menu" })).toBeInTheDocument();
    expect(screen.queryByText("B")).not.toBeInTheDocument();
    openMenu("Not signed in — account menu");
    expect(screen.getByRole("menuitem", { name: "Sign in" })).toBeEnabled();
    expect(screen.queryByRole("menuitem", { name: "Log out" })).not.toBeInTheDocument();
  });

  it("gates the account rows but leaves the local ones usable", () => {
    setup({ signedInRaw: "false" });
    openMenu("Not signed in — account menu");
    expect(screen.getByRole("menuitem", { name: /Preferences/ })).toBeDisabled();
    expect(screen.getByRole("menuitem", { name: /Billing/ })).toBeDisabled();
    expect(screen.getByRole("menuitem", { name: "Keyboard shortcuts" })).toBeEnabled();
    expect(screen.getByRole("menuitem", { name: "View session logs" })).toBeEnabled();
  });

  it("clicking Sign in re-runs the fake auth flow and closes the menu", () => {
    const { onResetAuthGate } = setup({ signedInRaw: "false" });
    openMenu("Not signed in — account menu");
    fireEvent.click(screen.getByRole("menuitem", { name: "Sign in" }));
    expect(onResetAuthGate).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });
});

describe("AccountBadge — the rows that really do something", () => {
  it("Keyboard shortcuts opens a sheet of the app's real bindings", async () => {
    setup();
    openMenu();
    fireEvent.click(screen.getByRole("menuitem", { name: "Keyboard shortcuts" }));
    const sheet = await screen.findByRole("dialog", { name: "Keyboard shortcuts" });
    expect(sheet).toBeInTheDocument();
    expect(screen.getByText("⌘T")).toBeInTheDocument();
    expect(screen.getByText("⌘K")).toBeInTheDocument();
    expect(screen.getByText("⌘N")).toBeInTheDocument();
    // The menu itself steps out of the way once the sheet is up.
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("the shortcuts sheet closes on Escape", async () => {
    setup();
    openMenu();
    fireEvent.click(screen.getByRole("menuitem", { name: "Keyboard shortcuts" }));
    const sheet = await screen.findByRole("dialog", { name: "Keyboard shortcuts" });
    fireEvent.keyDown(sheet, { key: "Escape" });
    expect(screen.queryByRole("dialog", { name: "Keyboard shortcuts" })).not.toBeInTheDocument();
  });

  it("View session logs reveals the transcripts folder in Finder", async () => {
    setup();
    openMenu();
    fireEvent.click(screen.getByRole("menuitem", { name: "View session logs" }));
    await waitFor(() =>
      expect(mocks.revealItemInDirMock).toHaveBeenCalledWith(
        "/Users/bruno/Library/Application Support/OmniAgent-ADE/transcripts",
      ),
    );
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
  });

  it("says so plainly when there's nothing to reveal, instead of failing silently", async () => {
    mocks.revealItemInDirMock.mockRejectedValue(new Error("no such file"));
    setup();
    openMenu();
    fireEvent.click(screen.getByRole("menuitem", { name: "View session logs" }));
    expect(await screen.findByText("No session logs on this machine yet.")).toBeInTheDocument();
    expect(screen.getByRole("menu")).toBeInTheDocument(); // stays open to show it
  });
});

describe("AccountBadge — the rows that honestly do not", () => {
  it("Preferences says Coming soon rather than opening a fake screen", () => {
    setup();
    openMenu();
    fireEvent.click(screen.getByRole("menuitem", { name: "Preferences" }));
    expect(screen.getByText("Coming soon.")).toBeInTheDocument();
    expect(screen.getByRole("menu")).toBeInTheDocument();
  });

  it("Billing says Coming soon too", () => {
    setup();
    openMenu();
    fireEvent.click(screen.getByRole("menuitem", { name: "Billing" }));
    expect(screen.getByText("Coming soon.")).toBeInTheDocument();
  });

  it("has no row for anything this product doesn't have", () => {
    // The reference menu's update/what's-new/docs/feedback/community/
    // upgrade/invite rows are omitted, not faked — see accountBadgeState's
    // module doc.
    setup();
    openMenu();
    for (const absent of ["Update", "What's new", "Documentation", "Feedback", "Upgrade", "Invite"]) {
      expect(screen.queryByRole("menuitem", { name: new RegExp(absent, "i") })).not.toBeInTheDocument();
    }
  });

  it("clicking Log out clears the fake sign-in and closes the menu", () => {
    const { onResetAuthGate } = setup();
    openMenu();
    fireEvent.click(screen.getByRole("menuitem", { name: "Log out" }));
    expect(onResetAuthGate).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });
});

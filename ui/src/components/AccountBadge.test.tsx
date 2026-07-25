import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import AccountBadge from "./AccountBadge";

function setup(overrides: Partial<Parameters<typeof AccountBadge>[0]> = {}) {
  const onResetAuthGate = vi.fn();
  render(<AccountBadge signedInRaw={null} personaRaw={null} onResetAuthGate={onResetAuthGate} {...overrides} />);
  return { onResetAuthGate };
}

describe("AccountBadge — not signed in (the common case: fresh/dev-mode install)", () => {
  it("is always present as a neutral placeholder trigger, never just absent", () => {
    setup();
    expect(screen.getByRole("button", { name: "Not signed in (dev mode)." })).toBeInTheDocument();
  });

  it("the menu is closed until the trigger is clicked", () => {
    setup();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("clicking the trigger opens the menu with the not-signed-in item set", () => {
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Not signed in (dev mode)." }));
    expect(screen.getByRole("menu")).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: /Preferences/ })).toBeDisabled();
    expect(screen.getByRole("menuitem", { name: /Billing/ })).toBeDisabled();
    expect(screen.getAllByText("Sign in to access")).toHaveLength(2);
    expect(screen.getByRole("menuitem", { name: "Sign in" })).toBeEnabled();
    expect(screen.queryByRole("menuitem", { name: "Log out" })).not.toBeInTheDocument();
  });

  it("clicking the trigger again closes the menu", () => {
    setup();
    const trigger = screen.getByRole("button", { name: "Not signed in (dev mode)." });
    fireEvent.click(trigger);
    expect(screen.getByRole("menu")).toBeInTheDocument();
    fireEvent.click(trigger);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("clicking Sign in re-triggers the AuthGate flow via onResetAuthGate, and closes the menu", () => {
    const { onResetAuthGate } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Not signed in (dev mode)." }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Sign in" }));
    expect(onResetAuthGate).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("clicking a disabled Preferences/Billing row does nothing", () => {
    const { onResetAuthGate } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Not signed in (dev mode)." }));
    fireEvent.click(screen.getByRole("menuitem", { name: /Preferences/ }));
    expect(onResetAuthGate).not.toHaveBeenCalled();
    expect(screen.queryByText("Coming soon.")).not.toBeInTheDocument();
    expect(screen.getByRole("menu")).toBeInTheDocument(); // still open, no-op
  });

  it("clicking the backdrop closes the menu without doing anything", () => {
    const { onResetAuthGate } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Not signed in (dev mode)." }));
    fireEvent.mouseDown(document.querySelector(".account-menu-backdrop")!);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(onResetAuthGate).not.toHaveBeenCalled();
  });
});

describe("AccountBadge — signed in", () => {
  it("shows the persona-aware tooltip and an initial avatar derived from the persona", () => {
    setup({ signedInRaw: "true", personaRaw: "data-ml" });
    expect(screen.getByRole("button", { name: "Signed in — Data & ML." })).toBeInTheDocument();
    expect(screen.getByText("D")).toBeInTheDocument();
  });

  it("falls back to the generic glyph (no initial letter) when signed in but no persona was captured", () => {
    setup({ signedInRaw: "true", personaRaw: null });
    expect(screen.getByRole("button", { name: "Signed in." })).toBeInTheDocument();
    expect(screen.queryByText(/^[A-Z]$/)).not.toBeInTheDocument();
  });

  it("opening the menu shows Preferences/Billing enabled and a Log out row, no Sign in row", () => {
    setup({ signedInRaw: "true", personaRaw: "student" });
    fireEvent.click(screen.getByRole("button", { name: "Signed in — Student." }));
    expect(screen.getByRole("menuitem", { name: "Preferences" })).toBeEnabled();
    expect(screen.getByRole("menuitem", { name: "Billing" })).toBeEnabled();
    expect(screen.queryByText("Sign in to access")).not.toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Log out" })).toBeInTheDocument();
    expect(screen.queryByRole("menuitem", { name: "Sign in" })).not.toBeInTheDocument();
  });

  it("clicking Preferences shows an honest Coming soon placeholder, menu stays open", () => {
    setup({ signedInRaw: "true", personaRaw: "student" });
    fireEvent.click(screen.getByRole("button", { name: "Signed in — Student." }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Preferences" }));
    expect(screen.getByText("Coming soon.")).toBeInTheDocument();
    expect(screen.getByRole("menu")).toBeInTheDocument();
  });

  it("clicking Billing shows an honest Coming soon placeholder, menu stays open", () => {
    setup({ signedInRaw: "true", personaRaw: "student" });
    fireEvent.click(screen.getByRole("button", { name: "Signed in — Student." }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Billing" }));
    expect(screen.getByText("Coming soon.")).toBeInTheDocument();
  });

  it("clicking Log out clears the fake sign-in via onResetAuthGate, and closes the menu", () => {
    const { onResetAuthGate } = setup({ signedInRaw: "true", personaRaw: "student" });
    fireEvent.click(screen.getByRole("button", { name: "Signed in — Student." }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Log out" }));
    expect(onResetAuthGate).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });
});

import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import PaneInstallOverlay from "./PaneInstallOverlay";
import type { Agent } from "../state/agents";

const TEST_AGENT: Agent = "claude";

describe("PaneInstallOverlay", () => {
  it("renders 'Installing…' text when status is 'in_progress'", () => {
    render(<PaneInstallOverlay agent={TEST_AGENT} status="in_progress" />);
    expect(screen.getByText("Installing claude…")).toBeInTheDocument();
  });

  it("renders 'Installation failed' text when status is 'failed'", () => {
    render(<PaneInstallOverlay agent={TEST_AGENT} status="failed" />);
    expect(screen.getByText("Installation of claude failed")).toBeInTheDocument();
  });

  it("renders hint text only when status is 'failed'", () => {
    const { rerender } = render(
      <PaneInstallOverlay agent={TEST_AGENT} status="in_progress" />
    );
    expect(
      screen.queryByText("Check your network and try again")
    ).not.toBeInTheDocument();

    rerender(<PaneInstallOverlay agent={TEST_AGENT} status="failed" />);
    expect(
      screen.getByText("Check your network and try again")
    ).toBeInTheDocument();
  });

  it("renders correct CSS classes for styling", () => {
    const { container } = render(
      <PaneInstallOverlay agent={TEST_AGENT} status="in_progress" />
    );

    expect(
      container.querySelector(".pane-install-overlay")
    ).toBeInTheDocument();
    expect(
      container.querySelector(".pane-install-backdrop")
    ).toBeInTheDocument();
    expect(
      container.querySelector(".pane-install-content")
    ).toBeInTheDocument();
  });
});

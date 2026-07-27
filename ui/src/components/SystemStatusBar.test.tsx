import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import SystemStatusBar from "./SystemStatusBar";

describe("SystemStatusBar", () => {
  it("shows live sessions and local computer health", () => {
    render(
      <SystemStatusBar
        liveSessionCount={4}
        brainNodeCount={41208}
        brainQueueCount={0}
        cpuPercent={34}
        ramUsedBytes={6.1 * 1024 ** 3}
        ramTotalBytes={16 * 1024 ** 3}
        mcpWired
      />,
    );

    expect(screen.getByText("4 sessions live")).toBeInTheDocument();
    expect(screen.getByText("brain 41,208 nodes · queue 0")).toBeInTheDocument();
    expect(screen.getByText("CPU 34% · RAM 6.1G / 16G")).toBeInTheDocument();
    expect(screen.getByText("MCP wired")).toBeInTheDocument();
  });
});

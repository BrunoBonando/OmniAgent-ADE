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
    // CPU 34% is in the green range (25–50 %)
    expect(screen.getByText("CPU 34%")).toBeInTheDocument();
    expect(screen.getByText("CPU 34%").className).toContain("is-usage-ok");
    // 6.1 / 16 ≈ 38 % — green range
    expect(screen.getByText("RAM 38%")).toBeInTheDocument();
    expect(screen.getByText("RAM 38%").className).toContain("is-usage-ok");
    expect(screen.getByText("MCP wired")).toBeInTheDocument();
  });

  it("shows critical color when CPU or RAM exceeds 75 %", () => {
    render(
      <SystemStatusBar
        liveSessionCount={1}
        brainNodeCount={null}
        brainQueueCount={null}
        cpuPercent={80}
        ramUsedBytes={52 * 1024 ** 3}
        ramTotalBytes={64 * 1024 ** 3}
        mcpWired={false}
      />,
    );

    expect(screen.getByText("CPU 80%").className).toContain("is-usage-critical");
    // 52 / 64 = 81 % — critical
    expect(screen.getByText("RAM 81%").className).toContain("is-usage-critical");
  });
});

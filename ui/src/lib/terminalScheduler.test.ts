import { beforeEach, describe, expect, it, vi } from "vitest";
import { scheduleTerminalJob } from "./terminalScheduler";

describe("terminal startup scheduler", () => {
  let frames: Array<FrameRequestCallback>;

  beforeEach(() => {
    frames = [];
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
      frames.push(callback);
      return frames.length;
    });
  });

  it("runs at most one queued job per animation frame and skips cancelled jobs", () => {
    const ran: string[] = [];
    const cancel = scheduleTerminalJob(() => ran.push("cancelled"));
    scheduleTerminalJob(() => ran.push("second"));
    cancel();

    expect(ran).toEqual([]);
    frames.shift()?.(0);
    expect(ran).toEqual(["second"]);
    expect(frames).toHaveLength(0);
  });
});

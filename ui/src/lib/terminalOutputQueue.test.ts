import { beforeEach, describe, expect, it, vi } from "vitest";
import { createTerminalOutputQueue } from "./terminalOutputQueue";

describe("terminal output queue", () => {
  let frames: Array<FrameRequestCallback>;

  beforeEach(() => {
    frames = [];
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
      frames.push(callback);
      return frames.length;
    });
  });

  it("coalesces multiple PTY chunks into one write per frame", () => {
    const writes: Uint8Array[] = [];
    const queue = createTerminalOutputQueue((bytes) => writes.push(bytes));

    queue.enqueue(new Uint8Array([1, 2]));
    queue.enqueue(new Uint8Array([3]));

    expect(writes).toHaveLength(0);
    frames.shift()?.(0);
    expect([...writes[0]]).toEqual([1, 2, 3]);
  });
});

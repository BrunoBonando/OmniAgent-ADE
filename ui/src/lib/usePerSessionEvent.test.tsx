// The subscribe/diff/unsubscribe dance `App.tsx` runs for BOTH per-session
// Tauri event streams (`session-attention:{id}` and `session-status:{id}`).
// Extracted from App.tsx when the second stream arrived, so the tricky part
// — a tab closing while its `listen()` promise is still in flight — is
// covered once, here, instead of twice by inspection.
import { render } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const { listenMock } = vi.hoisted(() => ({ listenMock: vi.fn() }));
vi.mock("@tauri-apps/api/event", () => ({ listen: listenMock }));

const { usePerSessionEvent } = await import("./usePerSessionEvent");

function Probe({ ids, onEvent }: { ids: string[]; onEvent: (id: string, payload: unknown) => void }) {
  usePerSessionEvent(ids, "session-status:", onEvent);
  return null;
}

describe("usePerSessionEvent", () => {
  beforeEach(() => {
    listenMock.mockReset();
    listenMock.mockResolvedValue(() => {});
  });

  it("subscribes once per id, under the prefixed event name", async () => {
    render(<Probe ids={["a", "b"]} onEvent={() => {}} />);
    await vi.waitFor(() => expect(listenMock).toHaveBeenCalledTimes(2));
    expect(listenMock.mock.calls.map(([name]) => name)).toEqual(["session-status:a", "session-status:b"]);
  });

  it("delivers the event payload alongside the id it belongs to", async () => {
    const onEvent = vi.fn();
    render(<Probe ids={["a"]} onEvent={onEvent} />);
    await vi.waitFor(() => expect(listenMock).toHaveBeenCalledTimes(1));
    const handler = listenMock.mock.calls[0][1] as (e: { payload: unknown }) => void;
    handler({ payload: { status: "ready" } });
    expect(onEvent).toHaveBeenCalledWith("a", { status: "ready" });
  });

  it("does not resubscribe an id that is already listening when the list grows", async () => {
    const { rerender } = render(<Probe ids={["a"]} onEvent={() => {}} />);
    await vi.waitFor(() => expect(listenMock).toHaveBeenCalledTimes(1));
    rerender(<Probe ids={["a", "b"]} onEvent={() => {}} />);
    await vi.waitFor(() => expect(listenMock).toHaveBeenCalledTimes(2));
    expect(listenMock.mock.calls.map(([name]) => name)).toEqual(["session-status:a", "session-status:b"]);
  });

  it("does not resubscribe when the ids are the same but a new array instance arrives", async () => {
    const { rerender } = render(<Probe ids={["a"]} onEvent={() => {}} />);
    await vi.waitFor(() => expect(listenMock).toHaveBeenCalledTimes(1));
    rerender(<Probe ids={["a"]} onEvent={() => {}} />);
    rerender(<Probe ids={["a"]} onEvent={() => {}} />);
    expect(listenMock).toHaveBeenCalledTimes(1);
  });

  it("unlistens an id that disappears from the list", async () => {
    const unlisten = vi.fn();
    listenMock.mockResolvedValue(unlisten);
    const { rerender } = render(<Probe ids={["a", "b"]} onEvent={() => {}} />);
    await vi.waitFor(() => expect(listenMock).toHaveBeenCalledTimes(2));
    rerender(<Probe ids={["a"]} onEvent={() => {}} />);
    expect(unlisten).toHaveBeenCalledTimes(1);
  });

  it("unlistens a subscription that only resolves AFTER its tab closed (no leaked listener)", async () => {
    const unlisten = vi.fn();
    let resolveListen!: (fn: () => void) => void;
    listenMock.mockReturnValue(new Promise((resolve) => (resolveListen = resolve)));

    const { rerender } = render(<Probe ids={["a"]} onEvent={() => {}} />);
    expect(listenMock).toHaveBeenCalledTimes(1);
    // The tab closes while `listen()` is still in flight.
    rerender(<Probe ids={[]} onEvent={() => {}} />);
    resolveListen(unlisten);
    await vi.waitFor(() => expect(unlisten).toHaveBeenCalledTimes(1));
  });

  it("uses the latest handler without resubscribing when it changes identity", async () => {
    const first = vi.fn();
    const second = vi.fn();
    const { rerender } = render(<Probe ids={["a"]} onEvent={first} />);
    await vi.waitFor(() => expect(listenMock).toHaveBeenCalledTimes(1));
    rerender(<Probe ids={["a"]} onEvent={second} />);
    expect(listenMock).toHaveBeenCalledTimes(1);
    const handler = listenMock.mock.calls[0][1] as (e: { payload: unknown }) => void;
    handler({ payload: 1 });
    expect(first).not.toHaveBeenCalled();
    expect(second).toHaveBeenCalledWith("a", 1);
  });

  it("unlistens everything on unmount", async () => {
    const unlisten = vi.fn();
    listenMock.mockResolvedValue(unlisten);
    const { unmount } = render(<Probe ids={["a", "b"]} onEvent={() => {}} />);
    await vi.waitFor(() => expect(listenMock).toHaveBeenCalledTimes(2));
    unmount();
    expect(unlisten).toHaveBeenCalledTimes(2);
  });
});

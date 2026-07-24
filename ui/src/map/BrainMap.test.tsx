// Regression coverage for the "does the map keep simulating/redrawing while
// the user is just looking at a terminal" question raised in Bruno's
// post-ship feedback round (2026-07-24): `BrainMap.tsx` was already wiring
// `hidden` -> `pauseAnimation()`/`resumeAnimation()` on the
// react-force-graph-2d ref (shipped with the map itself, commit 3cbf567 —
// confirmed by reading node_modules/react-force-graph-2d's source:
// `pauseAnimation` cancels the library's `requestAnimationFrame` loop
// outright, not just the heavy paint work). No fix was needed there, but
// there was zero test coverage locking that behavior in, and this file now
// edits the same component (zoom/hover-gated labels) — so this guards
// against a future accidental removal/regression of the pause/resume
// wiring.
//
// Full canvas/WebGL rendering isn't practically unit-testable (per this
// task's own instructions), so `react-force-graph-2d` is replaced with a
// minimal mock that exposes the same imperative-handle surface
// (`pauseAnimation`/`resumeAnimation`/etc.) via a ref, the way a real
// consumer would call it, without ever touching a canvas.
import { forwardRef, useImperativeHandle, type Ref } from "react";
import { render } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

const fgMock = vi.hoisted(() => ({
  pauseAnimation: vi.fn(),
  resumeAnimation: vi.fn(),
}));

vi.mock("react-force-graph-2d", () => ({
  default: forwardRef(function MockForceGraph2D(_props: unknown, ref: Ref<unknown>) {
    useImperativeHandle(ref, () => ({
      pauseAnimation: fgMock.pauseAnimation,
      resumeAnimation: fgMock.resumeAnimation,
      d3ReheatSimulation: vi.fn(),
      centerAt: vi.fn(),
      zoom: vi.fn(() => 1),
    }));
    return null;
  }),
}));

vi.mock("../lib/tauri", () => ({
  mapGraph: vi.fn().mockResolvedValue({ nodes: [], links: [] }),
  enrichQueuePendingCount: vi.fn().mockResolvedValue(0),
}));

// Imported after the mocks above so BrainMap picks up the mocked modules.
const { default: BrainMap } = await import("./BrainMap");

beforeAll(() => {
  // jsdom has no real layout engine — `clientWidth`/`clientHeight` are
  // always 0, which would leave BrainMap's own `size.width > 0 &&
  // size.height > 0` mount-gate permanently false and `fgRef` permanently
  // `undefined`, masking whether the `hidden`-driven effect actually fires
  // against a real ref. Stub non-zero dimensions so the mocked canvas
  // mounts the way it would behind a real, visible container.
  Object.defineProperty(HTMLElement.prototype, "clientWidth", { configurable: true, value: 800 });
  Object.defineProperty(HTMLElement.prototype, "clientHeight", { configurable: true, value: 600 });
  // jsdom has no ResizeObserver either; BrainMap's sizing effect calls
  // `measure()` synchronously on mount regardless (before ever touching the
  // observer), so a no-op observer is enough here.
  // @ts-expect-error -- test-only stub, jsdom ships none
  globalThis.ResizeObserver = class {
    observe() {}
    disconnect() {}
  };
  // The `hidden -> false` branch schedules a `requestAnimationFrame` resize
  // re-measure; jsdom has no rAF either.
  globalThis.requestAnimationFrame = ((cb: FrameRequestCallback) =>
    setTimeout(() => cb(performance.now()), 0)) as unknown as typeof requestAnimationFrame;
  globalThis.cancelAnimationFrame = ((id: number) => clearTimeout(id)) as unknown as typeof cancelAnimationFrame;
});

afterEach(() => {
  fgMock.pauseAnimation.mockClear();
  fgMock.resumeAnimation.mockClear();
});

describe("BrainMap — pauseAnimation/resumeAnimation on `hidden` transitions", () => {
  it("does not touch the animation on initial mount", () => {
    render(<BrainMap projects={[]} onOpenTerminal={() => {}} hidden={false} />);
    expect(fgMock.pauseAnimation).not.toHaveBeenCalled();
    expect(fgMock.resumeAnimation).not.toHaveBeenCalled();
  });

  it("pauses when `hidden` flips to true (switching away to a terminal tab)", () => {
    const { rerender } = render(<BrainMap projects={[]} onOpenTerminal={() => {}} hidden={false} />);

    rerender(<BrainMap projects={[]} onOpenTerminal={() => {}} hidden={true} />);

    expect(fgMock.pauseAnimation).toHaveBeenCalledTimes(1);
    expect(fgMock.resumeAnimation).not.toHaveBeenCalled();
  });

  it("resumes when `hidden` flips back to false (switching back to the map)", () => {
    const { rerender } = render(<BrainMap projects={[]} onOpenTerminal={() => {}} hidden={false} />);
    rerender(<BrainMap projects={[]} onOpenTerminal={() => {}} hidden={true} />);
    fgMock.pauseAnimation.mockClear();

    rerender(<BrainMap projects={[]} onOpenTerminal={() => {}} hidden={false} />);

    expect(fgMock.resumeAnimation).toHaveBeenCalledTimes(1);
    expect(fgMock.pauseAnimation).not.toHaveBeenCalled();
  });

  it("does not re-fire on an unrelated re-render (same `hidden` value)", () => {
    const { rerender } = render(
      <BrainMap projects={[]} onOpenTerminal={() => {}} hidden={false} livePollMs={undefined} />,
    );
    rerender(<BrainMap projects={[]} onOpenTerminal={() => {}} hidden={true} />);
    fgMock.pauseAnimation.mockClear();

    // Same `hidden` value, different (irrelevant) prop identity.
    rerender(<BrainMap projects={[]} onOpenTerminal={() => {}} hidden={true} />);

    expect(fgMock.pauseAnimation).not.toHaveBeenCalled();
  });
});

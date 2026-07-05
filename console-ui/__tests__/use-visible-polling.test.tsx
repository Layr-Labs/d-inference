import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { renderHook } from "@testing-library/react";
import { act } from "react";
import { useVisiblePolling } from "@/hooks/useVisiblePolling";

function setVisibility(state: "visible" | "hidden") {
  Object.defineProperty(document, "visibilityState", {
    value: state,
    configurable: true,
  });
  document.dispatchEvent(new Event("visibilitychange"));
}

describe("useVisiblePolling", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    setVisibility("visible");
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("runs once on mount and then on the interval while visible", () => {
    const cb = vi.fn();
    renderHook(() => useVisiblePolling(cb, 1000));
    expect(cb).toHaveBeenCalledTimes(1); // initial
    act(() => {
      vi.advanceTimersByTime(3000);
    });
    expect(cb).toHaveBeenCalledTimes(4); // initial + 3 ticks
  });

  it("pauses the interval while hidden and refetches on regain", () => {
    const cb = vi.fn();
    renderHook(() => useVisiblePolling(cb, 1000));
    expect(cb).toHaveBeenCalledTimes(1);

    act(() => setVisibility("hidden"));
    act(() => {
      vi.advanceTimersByTime(5000);
    });
    // No ticks while hidden.
    expect(cb).toHaveBeenCalledTimes(1);

    act(() => setVisibility("visible"));
    // One immediate refetch on regain.
    expect(cb).toHaveBeenCalledTimes(2);
    act(() => {
      vi.advanceTimersByTime(1000);
    });
    expect(cb).toHaveBeenCalledTimes(3);
  });

  it("does nothing when disabled", () => {
    const cb = vi.fn();
    renderHook(() => useVisiblePolling(cb, 1000, false));
    act(() => {
      vi.advanceTimersByTime(3000);
    });
    expect(cb).not.toHaveBeenCalled();
  });
});

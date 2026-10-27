// @vitest-environment jsdom
import { useRef } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, render } from '@testing-library/react';
import { useFrameLoop } from '../src/renderer/features/home/chip/hooks/useFrameLoop';

let frames: FrameRequestCallback[] = [],
  clock = 0,
  visibility: ((entries: { isIntersecting: boolean }[]) => void) | null = null;
function flush(count: number) {
  for (let i = 0; i < count; i++) {
    clock += 16;
    const due = frames;
    frames = [];
    act(() => due.forEach((callback) => callback(clock)));
  }
}
function setHidden(hidden: boolean) {
  Object.defineProperty(document, 'hidden', { configurable: true, get: () => hidden });
  act(() => {
    document.dispatchEvent(new Event('visibilitychange'));
  });
}
function Loop({ active, onFrame }: { active: boolean; onFrame: (elapsed: number) => void }) {
  const target = useRef<HTMLDivElement>(null);
  useFrameLoop(target, onFrame, { active, interval: 30 });
  return <div ref={target} />;
}

beforeEach(() => {
  frames = [];
  clock = 0;
  vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => {
    frames.push(callback);
    return frames.length;
  });
  vi.stubGlobal('cancelAnimationFrame', () => {
    frames = [];
  });
  vi.stubGlobal(
    'IntersectionObserver',
    class {
      constructor(callback: (entries: { isIntersecting: boolean }[]) => void) {
        visibility = callback;
      }
      observe() {}
      disconnect() {}
    },
  );
});
afterEach(() => {
  cleanup();
  setHidden(false);
  vi.unstubAllGlobals();
});

describe('frame loop', () => {
  it('throttles to the interval and reports elapsed seconds', () => {
    const onFrame = vi.fn();
    render(<Loop active onFrame={onFrame} />);
    flush(9);
    expect(onFrame.mock.calls.length).toBeGreaterThanOrEqual(4);
    expect(onFrame.mock.calls.length).toBeLessThanOrEqual(5);
    expect(onFrame.mock.calls[0][0]).toBe(0);
    expect(onFrame.mock.calls[1][0]).toBeCloseTo(0.032, 3);
  });

  it('stops while paused, hidden or scrolled off screen, and resumes', () => {
    const onFrame = vi.fn();
    const { rerender } = render(<Loop active={false} onFrame={onFrame} />);
    flush(6);
    expect(onFrame).not.toHaveBeenCalled();

    rerender(<Loop active onFrame={onFrame} />);
    flush(6);
    const running = onFrame.mock.calls.length;
    expect(running).toBeGreaterThan(0);

    setHidden(true);
    flush(6);
    expect(onFrame.mock.calls.length).toBe(running);
    setHidden(false);
    flush(6);
    const visible = onFrame.mock.calls.length;
    expect(visible).toBeGreaterThan(running);

    act(() => visibility?.([{ isIntersecting: false }]));
    flush(6);
    expect(onFrame.mock.calls.length).toBe(visible);
    act(() => visibility?.([{ isIntersecting: true }]));
    flush(6);
    expect(onFrame.mock.calls.length).toBeGreaterThan(visible);
  });
});

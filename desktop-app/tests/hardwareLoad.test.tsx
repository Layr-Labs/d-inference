// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, renderHook } from '@testing-library/react';
import type { DesktopAPI, Snapshot } from '../src/shared/contracts';
import { isHardwareSample, type HardwareLoad, type HardwareSample } from '../src/shared/hardware';
import { useHardwareLoad } from '../src/renderer/hardware/useHardwareLoad';
import { isFresh, newerSample } from '../src/renderer/hardware/freshness';
import {
  previewHardwareLoad,
  previewHardwarePhase,
  previewHardwareSample,
  previewHardwareStream,
  previewTopology,
} from '../src/renderer/previewHardware';

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
});

// A desktop API whose hardware stream the test drives by hand.
function source(load: HardwareLoad) {
  const callbacks = new Set<(sample: HardwareSample) => void>();
  const unsubscribed = vi.fn();
  const api = {
    read: vi.fn(async () => load),
    onHardware: vi.fn((callback: (sample: HardwareSample) => void) => {
      callbacks.add(callback);
      return () => {
        callbacks.delete(callback);
        unsubscribed();
      };
    }),
  } as unknown as DesktopAPI;
  const emit = (sample: HardwareSample) => act(() => callbacks.forEach((fn) => fn(sample)));
  return { api, emit, unsubscribed, subscribers: () => callbacks.size };
}

const setVisibility = (state: 'visible' | 'hidden') =>
  act(() => {
    Object.defineProperty(document, 'visibilityState', { value: state, configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
  });

describe('freshness', () => {
  it('treats samples older than three seconds as stale', () => {
    const sample = previewHardwareSample(1000, true);
    expect(isFresh(sample, 1000_000 + 2999)).toBe(true);
    expect(isFresh(sample, 1000_000 + 3000)).toBe(false);
    expect(isFresh(null)).toBe(false);
  });

  it('never replaces a newer sample with an older one', () => {
    const older = previewHardwareSample(10, true);
    const newer = previewHardwareSample(11, true);
    expect(newerSample(newer, older)).toBe(newer);
    expect(newerSample(older, newer)).toBe(newer);
    expect(newerSample(null, older)).toBe(older);
  });
});

describe('useHardwareLoad', () => {
  it('loads topology, follows the stream and goes stale when frames stop', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
    vi.setSystemTime(1_790_000_000_000);
    const now = Date.now() / 1000;
    const { api, emit } = source(previewHardwareLoad(now - 1, true));
    const { result } = renderHook(() => useHardwareLoad(api));
    await act(async () => {});
    expect(result.current.topology).toEqual(previewTopology);
    expect(result.current.sample?.sampled_at).toBe(now - 1);
    expect(result.current.fresh).toBe(true);
    expect(result.current.capabilities.memory_bandwidth).toBe('estimated');

    emit(previewHardwareSample(now, true));
    expect(result.current.sample?.sampled_at).toBe(now);
    await act(async () => vi.advanceTimersByTimeAsync(2900));
    expect(result.current.fresh).toBe(true);
    await act(async () => vi.advanceTimersByTimeAsync(200));
    expect(result.current.fresh).toBe(false);
    expect(result.current.sample).not.toBeNull();
  });

  it('reports the whole machine and Darkbloom share while the provider is stopped', async () => {
    const now = Date.now() / 1000;
    const { api, emit } = source(previewHardwareLoad(now, false));
    const { result } = renderHook(() => useHardwareLoad(api));
    await act(async () => {});
    emit(previewHardwareSample(now + 0.5, false));
    expect(result.current.sample?.provider.running).toBe(false);
    expect(result.current.sample?.gpu.provider_share).toBe(0);
    expect(result.current.sample?.cpu.load).toHaveLength(16);
  });

  it('subscribes only while mounted and visible', async () => {
    const { api, unsubscribed, subscribers } = source(previewHardwareLoad(Date.now() / 1000, true));
    const { unmount } = renderHook(() => useHardwareLoad(api));
    await act(async () => {});
    expect(subscribers()).toBe(1);
    setVisibility('hidden');
    expect(subscribers()).toBe(0);
    expect(unsubscribed).toHaveBeenCalledTimes(1);
    setVisibility('visible');
    await act(async () => {});
    expect(subscribers()).toBe(1);
    expect(api.read).toHaveBeenCalledTimes(2);
    unmount();
    expect(subscribers()).toBe(0);
  });

  it('does not subscribe when the window starts hidden or no runtime exists', async () => {
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    const { api, subscribers } = source(previewHardwareLoad(Date.now() / 1000, true));
    renderHook(() => useHardwareLoad(api));
    expect(subscribers()).toBe(0);
    expect(api.read).not.toHaveBeenCalled();
    const { result } = renderHook(() => useHardwareLoad(undefined));
    expect(result.current).toMatchObject({ topology: null, sample: null, fresh: false });
  });

  it('ignores a snapshot from an incompatible protocol', async () => {
    const { api } = source({ ...previewHardwareLoad(Date.now() / 1000, true), protocol: 2 });
    const { result } = renderHook(() => useHardwareLoad(api));
    await act(async () => {});
    expect(result.current.topology).toBeNull();
    expect(result.current.sample).toBeNull();
  });
});

describe('preview hardware', () => {
  it('cycles idle, prefill and decode with measured M4 Max magnitudes', () => {
    const cycle = 1_790_000_016; // a multiple of the 24 s cycle
    expect(previewHardwarePhase(cycle + 2, true)).toBe('idle');
    expect(previewHardwarePhase(cycle + 7, true)).toBe('prefill');
    expect(previewHardwarePhase(cycle + 15, true)).toBe('decode');
    expect(previewHardwarePhase(cycle + 15, false)).toBe('idle');

    const prefill = previewHardwareSample(cycle + 7, true);
    const decode = previewHardwareSample(cycle + 15, true);
    const idle = previewHardwareSample(cycle + 2, true);
    expect(prefill.gpu.utilization).toBeGreaterThan(0.95);
    expect(decode.gpu.utilization).toBeGreaterThan(0.95);
    expect(prefill.gpu.power_w!).toBeGreaterThan(decode.gpu.power_w!);
    expect(prefill.memory.bandwidth_gbps!).toBeLessThan(160);
    expect(decode.memory.bandwidth_gbps!).toBeGreaterThan(420);
    expect(decode.memory.bandwidth_gbps!).toBeLessThanOrEqual(546);
    expect(idle.gpu.utilization!).toBeLessThan(0.1);
    expect(idle.ane.active).toBe(0);
    for (const sample of [prefill, decode, idle]) {
      expect(isHardwareSample(sample)).toBe(true);
      expect(sample.cpu.load.every((load) => load >= 0 && load <= 1)).toBe(true);
    }
  });

  it('describes the same Mac as the preview snapshot', async () => {
    const { previewAPI } = await import('../src/renderer/preview');
    const state = await previewAPI.read<Snapshot>('state');
    const load = await previewAPI.read<HardwareLoad>('hardware');
    expect(load.topology).toEqual(previewTopology);
    expect(state.machine.chip).toBe(previewTopology.chip);
    expect(state.machine.memory_gb).toBe(previewTopology.memory.total_gb);
    expect(state.memory.total_gb).toBe(previewTopology.memory.total_gb);
  });

  it('streams a sample per interval until unsubscribed', () => {
    vi.useFakeTimers();
    const received: HardwareSample[] = [];
    const stop = previewHardwareStream(
      (sample) => received.push(sample),
      () => true,
      1000,
    );
    vi.advanceTimersByTime(3000);
    expect(received).toHaveLength(3);
    stop();
    vi.advanceTimersByTime(3000);
    expect(received).toHaveLength(3);
  });
});

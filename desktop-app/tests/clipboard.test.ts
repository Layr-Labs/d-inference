// @vitest-environment jsdom
import { afterEach, expect, it, vi, type Mock } from 'vitest';
import { act, cleanup, renderHook } from '@testing-library/react';
import { useClipboard } from '../src/renderer/components/useClipboard';

// The copy controls of Clusters, Early access, Sandboxes and Studio share this hook.
const bridge = vi.hoisted(() => ({ current: { copy: vi.fn() } as { copy: Mock } | undefined }));
vi.mock('../src/renderer/useBackend', () => ({
  get api() {
    return bridge.current;
  },
}));
afterEach(() => {
  cleanup();
  vi.useRealTimers();
  bridge.current = { copy: vi.fn() };
});

it('confirms only the value just copied, and says Copy again after resetMs', async () => {
  vi.useFakeTimers();
  bridge.current!.copy.mockResolvedValue(undefined);
  const { result } = renderHook(() => useClipboard<'url' | 'example'>(1600));
  let copied: boolean | undefined;
  await act(async () => {
    copied = await result.current.copy('http://127.0.0.1:8000/v1', 'url');
  });
  expect(copied).toBe(true);
  expect(bridge.current!.copy).toHaveBeenCalledWith('http://127.0.0.1:8000/v1');
  expect(result.current.copied).toBe('url');
  await act(async () => {
    await result.current.copy('curl …', 'example');
  });
  expect(result.current.copied).toBe('example');
  act(() => {
    vi.advanceTimersByTime(1599);
  });
  expect(result.current.copied).toBe('example');
  act(() => {
    vi.advanceTimersByTime(1);
  });
  expect(result.current.copied).toBeNull();
});

it('keeps the confirmation without resetMs, keyed by the text itself', async () => {
  vi.useFakeTimers();
  bridge.current!.copy.mockResolvedValue(undefined);
  const { result } = renderHook(() => useClipboard());
  await act(async () => {
    await result.current.copy('WDJB-MJHT');
  });
  act(() => {
    vi.advanceTimersByTime(60_000);
  });
  expect(result.current.copied).toBe('WDJB-MJHT');
});

it('confirms nothing when the copy fails or there is no app to copy with', async () => {
  bridge.current!.copy.mockResolvedValueOnce(undefined).mockRejectedValueOnce(new Error('denied'));
  const { result } = renderHook(() => useClipboard());
  await act(async () => {
    await result.current.copy('darkbloom cluster');
  });
  expect(result.current.copied).toBe('darkbloom cluster');
  let copied: boolean | undefined;
  await act(async () => {
    copied = await result.current.copy('darkbloom cluster local');
  });
  expect(copied).toBe(false);
  expect(result.current.copied).toBeNull();
  bridge.current = undefined;
  await act(async () => {
    copied = await result.current.copy('darkbloom cluster');
  });
  expect(copied).toBe(false);
  expect(result.current.copied).toBeNull();
});

import { afterEach, expect, it, vi } from 'vitest';
import type { DesktopAPI, Operation, Snapshot } from '../src/shared/contracts';
import { submitAction } from '../src/renderer/actions';

afterEach(() => vi.useRealTimers());
const running: Operation = {
  id: 'operation',
  action: 'download',
  state: 'running',
  started_at: 1,
  message: 'Working',
  cancellable: true,
};

it('receives terminal progress from the state stream without polling', async () => {
  let observe!: (snapshot: Snapshot) => void;
  const off = vi.fn();
  const read = vi.fn();
  const api = {
    onState: vi.fn((callback) => {
      observe = callback;
      return off;
    }),
    act: vi.fn().mockResolvedValue(running),
    read,
  } as unknown as DesktopAPI;
  const work = submitAction(
    api,
    { action: 'download', model: 'model' },
    { timeoutMs: 60_000, timeout: 'Timed out' },
  );
  await Promise.resolve();
  observe({ operations: [{ ...running, state: 'succeeded' }] } as Snapshot);
  await work;
  expect(read).not.toHaveBeenCalled();
  expect(off).toHaveBeenCalledOnce();
});

it('falls back after stream silence and removes the subscriber on failure', async () => {
  vi.useFakeTimers();
  const off = vi.fn();
  const read = vi.fn().mockResolvedValue({
    operations: [{ ...running, state: 'failed', message: 'Download refused' }],
  });
  const api = {
    onState: () => off,
    act: vi.fn().mockResolvedValue(running),
    read,
  } as unknown as DesktopAPI;
  const work = submitAction(
    api,
    { action: 'download', model: 'model' },
    { timeoutMs: 60_000, timeout: 'Timed out' },
  );
  const failure = expect(work).rejects.toThrow('Download refused');
  await vi.advanceTimersByTimeAsync(10_000);
  await failure;
  expect(read).toHaveBeenCalledOnce();
  expect(off).toHaveBeenCalledOnce();
});

// @vitest-environment jsdom
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import type { Resource, Route } from '../src/shared/contracts';

// Cooling status is read by spawning `darkbloom fan status --json` in the
// native backend, so it is fetched only while the Cooling screen is shown.
let useBackend: typeof import('../src/renderer/useBackend').useBackend;
let previewAPI: typeof import('../src/renderer/preview').previewAPI;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  ({ useBackend } = await import('../src/renderer/useBackend'));
  ({ previewAPI } = await import('../src/renderer/preview'));
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
const reads = (spy: { mock: { calls: unknown[][] } }, resource: Resource) =>
  spy.mock.calls.filter(([name]) => name === resource).length;

async function mount(route: Route) {
  const read = vi.spyOn(previewAPI, 'read');
  const hook = renderHook(({ route }: { route: Route }) => useBackend(route), {
    initialProps: { route },
  });
  await waitFor(() => expect(read).toHaveBeenCalledWith('leaderboard'));
  return { read, ...hook };
}

it('does not read cooling while another screen is shown', async () => {
  const { read, result } = await mount('home');
  await act(() => result.current.refresh());
  expect(reads(read, 'state')).toBeGreaterThanOrEqual(2);
  expect(reads(read, 'cooling')).toBe(0);
});

it('reads cooling on entering the cooling screen and on each refresh there', async () => {
  const { read, result, rerender } = await mount('home');
  rerender({ route: 'cooling' });
  await waitFor(() => expect(reads(read, 'cooling')).toBe(1));
  await waitFor(() => expect(result.current.cooling?.supported).toBe(true));
  await act(() => result.current.refresh());
  expect(reads(read, 'cooling')).toBe(2);
  rerender({ route: 'models' });
  await act(() => result.current.refresh());
  expect(reads(read, 'cooling')).toBe(2);
});

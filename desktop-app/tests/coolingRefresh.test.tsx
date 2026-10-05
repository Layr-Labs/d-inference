// @vitest-environment jsdom
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import type { Resource, Route } from '../src/shared/contracts';

// Cooling status is read by spawning `darkbloom fan status --json` in the
// native backend, so it is fetched only while Cooling or This Mac's Overview is shown.
let useBackend: typeof import('../src/renderer/useBackend').useBackend;
let showsCooling: typeof import('../src/renderer/useBackend').showsCooling;
let previewAPI: typeof import('../src/renderer/preview').previewAPI;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  ({ useBackend, showsCooling } = await import('../src/renderer/useBackend'));
  ({ previewAPI } = await import('../src/renderer/preview'));
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
const reads = (spy: { mock: { calls: unknown[][] } }, resource: Resource) =>
  spy.mock.calls.filter(([name]) => name === resource).length;

type View = { route: Route; machine: string | null };
async function mount(route: Route, machine: string | null = null) {
  const read = vi.spyOn(previewAPI, 'read');
  const hook = renderHook(({ route, machine }: View) => useBackend(route, machine), {
    initialProps: { route, machine },
  });
  await waitFor(() => expect(read).toHaveBeenCalledWith('state'));
  return { read, ...hook };
}

it('shows cooling only on Cooling and on This Mac’s Overview', () => {
  expect(showsCooling('cooling')).toBe(true);
  expect(showsCooling('cooling', 'remote-studio')).toBe(true);
  expect(showsCooling('machines')).toBe(true);
  expect(showsCooling('machines', 'remote-studio')).toBe(false);
  for (const route of ['home', 'models', 'analysis', 'settings', 'studio'] as const)
    expect(showsCooling(route)).toBe(false);
});

it('does not read cooling while another screen is shown', async () => {
  const { read, result } = await mount('home');
  await act(() => result.current.refresh());
  expect(reads(read, 'state')).toBeGreaterThanOrEqual(2);
  expect(reads(read, 'cooling')).toBe(0);
});

it('reads cooling on entering the cooling screen and on each refresh there', async () => {
  const { read, result, rerender } = await mount('home');
  rerender({ route: 'cooling', machine: null });
  await waitFor(() => expect(reads(read, 'cooling')).toBe(1));
  await waitFor(() => expect(result.current.cooling?.supported).toBe(true));
  await act(() => result.current.refresh());
  expect(reads(read, 'cooling')).toBe(2);
  rerender({ route: 'models', machine: null });
  await act(() => result.current.refresh());
  expect(reads(read, 'cooling')).toBe(2);
});

it('reads cooling on This Mac’s Overview but not on a remote Mac’s', async () => {
  const { read, result, rerender } = await mount('machines');
  await waitFor(() => expect(reads(read, 'cooling')).toBe(1));
  await act(() => result.current.refresh());
  expect(reads(read, 'cooling')).toBe(2);
  rerender({ route: 'machines', machine: 'remote-studio' });
  await act(() => result.current.refresh());
  expect(reads(read, 'cooling')).toBe(2);
  rerender({ route: 'machines', machine: null });
  await waitFor(() => expect(reads(read, 'cooling')).toBe(3));
});

it('loads rankings and releases only when their pages are opened', async () => {
  const { read, rerender } = await mount('home');
  expect(reads(read, 'leaderboard')).toBe(0);
  expect(reads(read, 'release')).toBe(0);
  expect(reads(read, 'release-history')).toBe(0);
  rerender({ route: 'leaderboard', machine: null });
  await waitFor(() => expect(reads(read, 'leaderboard')).toBe(1));
  expect(reads(read, 'release')).toBe(0);
  rerender({ route: 'updates', machine: null });
  await waitFor(() => expect(reads(read, 'release')).toBe(1));
  expect(reads(read, 'release-history')).toBe(1);
});

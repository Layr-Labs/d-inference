// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Action, Snapshot } from '../src/shared/contracts';
import type { PreviewStore } from '../src/renderer/preview/types';
import { snapshot } from './onboardingFixtures';

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

// The preview module reads its query once, when it loads.
async function previewWith(query: string) {
  window.history.replaceState({}, '', `/?preview${query}`);
  vi.resetModules();
  return (await import('../src/renderer/preview/localServing')).localServingPreview;
}

const base = () =>
  snapshot({
    state: 'running',
    endpoint: {
      base_url: 'http://127.0.0.1:8000/v1',
      authenticated: true,
      models: ['gpt-oss-20b'],
    },
  });

function storeOf(state: Snapshot): PreviewStore & { current: () => Snapshot } {
  let current = state;
  return { get: () => current, set: (next) => (current = next), current: () => current };
}

async function act(
  store: PreviewStore,
  action: Action,
  preview: Awaited<ReturnType<typeof previewWith>>,
) {
  vi.useFakeTimers();
  const pending = preview.act!(store, action);
  await vi.advanceTimersByTimeAsync(2000);
  return pending;
}

it('shows the whole feature by default and keeps what a listless runtime offered', async () => {
  const preview = await previewWith('');
  const next = preview.snapshot!(base());
  expect(next.capabilities).toEqual([
    'autopilot',
    'waitlist',
    'local_serving',
    'tool_setup',
    'update_rollback',
  ]);
  expect(next.local).toMatchObject({
    mode: 'both',
    me_first: true,
    me_first_idle_minutes: 2,
    route: null,
    route_key: false,
    port: 8001,
    bind: '127.0.0.1',
    paused_until: null,
  });
  expect(next.endpoint).toEqual({
    base_url: 'http://127.0.0.1:8001/v1',
    authenticated: true,
    models: ['gpt-oss-20b'],
  });
  // A runtime's own list is kept as it is.
  expect(preview.snapshot!({ ...base(), capabilities: ['account-signin'] }).capabilities).toEqual([
    'account-signin',
    'local_serving',
    'tool_setup',
    'update_rollback',
  ]);
});

it.each([
  ['&local=only-me', 'local', true],
  ['&local=network', 'network', false],
  ['&local=both', 'both', true],
])('saves the choice %s names', async (query, mode, endpoint) => {
  const next = (await previewWith(query)).snapshot!(base());
  expect(next.local?.mode).toBe(mode);
  expect(!!next.endpoint).toBe(endpoint);
});

it('pauses Darkbloom for you with &local=paused, and offers nothing with &local=unsupported', async () => {
  const state = base();
  const paused = (await previewWith('&local=paused')).snapshot!(state);
  expect(paused.local?.paused_until).toBe(state.observed_at + 100);
  const unsupported = await previewWith('&local=unsupported');
  const older = unsupported.snapshot!(state);
  expect(older.local).toBeUndefined();
  expect(older.capabilities).toBeUndefined();
  expect(older.endpoint).toEqual(state.endpoint);
  // Drops them from a runtime that listed them too.
  expect(
    unsupported.snapshot!({
      ...state,
      capabilities: ['autopilot', 'local_serving', 'tool_setup', 'update_rollback'],
    }).capabilities,
  ).toEqual(['autopilot']);
});

it('refuses a route that passes requests on until a key is saved, and never keeps the key', async () => {
  const preview = await previewWith('');
  const store = storeOf(preview.snapshot!(base()));
  const refused = await act(store, { action: 'route', route: 'my-macs' }, preview);
  expect(refused?.state).toBe('failed');
  expect(refused?.message).toMatch(
    /^✗ Not saved: `darkbloom route my-macs` passes your requests on/,
  );
  expect(store.current().local?.route).toBeNull();
  const key = await act(store, { action: 'route_key', key: 'sk-preview-secret' }, preview);
  expect(key?.state).toBe('succeeded');
  expect(store.current().local?.route_key).toBe(true);
  expect(JSON.stringify(store.current())).not.toContain('sk-preview-secret');
  const saved = await act(store, { action: 'route', route: 'my-macs' }, preview);
  expect(saved?.state).toBe('succeeded');
  expect(store.current().local?.route).toBe('my-macs');
  const local = await act(store, { action: 'route_key', key: 'dk-local-abc' }, preview);
  expect(local?.state).toBe('failed');
});

it('applies a way to serve, saves me first and leaves a plain start to the shared preview', async () => {
  const preview = await previewWith('');
  const store = storeOf(preview.snapshot!(base()));
  await act(store, { action: 'start', models: ['gpt-oss-20b'], network: true }, preview);
  expect(store.current().local?.mode).toBe('network');
  expect(store.current().endpoint).toBeUndefined();
  await act(store, { action: 'start', models: ['gpt-oss-20b'], local: true }, preview);
  expect(store.current().local?.mode).toBe('local');
  expect(store.current().endpoint?.base_url).toBe('http://127.0.0.1:8001/v1');
  expect(await preview.act!(store, { action: 'start', models: ['gpt-oss-20b'] })).toBeUndefined();
  const refused = await act(
    store,
    { action: 'local_settings', me_first: true, me_first_idle_minutes: 0 },
    preview,
  );
  expect(refused?.state).toBe('failed');
  await act(
    store,
    { action: 'local_settings', me_first: false, me_first_idle_minutes: 9 },
    preview,
  );
  expect(store.current().local).toMatchObject({ me_first: false, me_first_idle_minutes: 9 });
  const tool = await act(store, { action: 'tool_setup', tool: 'opencode' }, preview);
  expect(tool?.message).toMatch(/^✓ OpenCode can use Darkbloom/);
});

it('falls through for a runtime without local-first serving', async () => {
  const preview = await previewWith('&local=unsupported');
  const store = storeOf(preview.snapshot!(base()));
  expect(await preview.act!(store, { action: 'route', route: 'this-mac' })).toBeUndefined();
});

it('opens Studio from This Mac in the preview with the three ways to serve', async () => {
  window.history.replaceState({}, '', '/?preview');
  vi.resetModules();
  const App = (await import('../src/renderer/App')).default;
  render(<App />);
  await screen.findByRole('heading', { name: 'Your contribution' });
  fireEvent.click(screen.getByRole('button', { name: 'My Macs' }));
  fireEvent.click(await screen.findByRole('button', { name: /^Studio/ }));
  expect(await screen.findByRole('heading', { name: 'How this Mac serves' })).toBeVisible();
  expect(screen.getByRole('radio', { name: 'Both, me first' })).toBeChecked();
  expect(screen.getByRole('button', { name: 'Set up OpenCode' })).toBeEnabled();
});

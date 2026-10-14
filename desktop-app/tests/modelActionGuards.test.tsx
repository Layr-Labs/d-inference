// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Action, Snapshot } from '../src/shared/contracts';
import { Models } from '../src/renderer/features/models/Models';
import { backendWith } from './onboardingFixtures';
import { poolModels, poolSnapshot, succeeded } from './modelsFixtures';

const api = vi.hoisted(() => ({ act: vi.fn(), read: vi.fn(), onNavigate: () => () => {} }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));

let current: Snapshot;
beforeEach(() => {
  api.act.mockImplementation(async (action: Action) => succeeded(action.action));
  api.read.mockImplementation(async () => current);
});
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});
const sent = () => api.act.mock.calls.map(([action]) => action);
const row = (name: string) => screen.getByRole('heading', { name }).closest('article')!;

it('preserves the serving selection when adding a downloaded model before Autopilot is set up', async () => {
  current = poolSnapshot({ enabled: false, configured: false, selected: [], pinned: [] });
  render(<Models backend={backendWith(current)} />);
  const add = within(row('Qwen 3.5 9B')).getByRole('button', { name: /Add to pool/ });
  await act(async () => fireEvent.click(add));
  expect(sent()).toEqual([
    {
      action: 'autopilot',
      models: ['gpt-oss-20b', 'gemma-4-26b'],
      pinned: [],
      endpoint: false,
    },
  ]);
});

it('starts only one cached model when a new pool would exceed the combined load budget', async () => {
  // Both cached models fit alone, but loading them together would exceed the 25 GB budget.
  const models = [poolModels[0], poolModels[2]].map((model) => ({
    ...model,
    loaded: false,
    serving: false,
    memory_gb: 20,
  }));
  current = poolSnapshot(
    { enabled: false, configured: false, selected: [], pinned: [] },
    { state: 'stopped', models, memory: { total_gb: 32, active_gb: 0, free_for_load_gb: 25 } },
  );
  render(<Models backend={backendWith(current)} />);
  const add = within(row('Qwen 3.5 9B')).getByRole('button', { name: /Add to pool/ });
  await act(async () => fireEvent.click(add));
  expect(sent()).toEqual([
    { action: 'autopilot', models: ['gpt-oss-20b'], pinned: [], endpoint: false },
  ]);
});

it('submits Add to pool once while the initial state read is pending', async () => {
  current = poolSnapshot({ enabled: false, configured: false, selected: [], pinned: [] });
  let release!: (state: Snapshot) => void;
  const gate = new Promise<Snapshot>((resolve) => (release = resolve));
  api.read.mockImplementation(async (resource: string) => (resource === 'state' ? gate : current));
  render(<Models backend={backendWith(current)} />);
  const add = within(row('Qwen 3.5 9B')).getByRole('button', { name: /Add to pool/ });
  act(() => {
    fireEvent.click(add);
    fireEvent.click(add);
  });
  expect(api.read.mock.calls.filter(([resource]) => resource === 'state')).toHaveLength(1);
  expect(api.act).not.toHaveBeenCalled();
  expect(within(row('Qwen 3.5 9B')).getByRole('status')).toHaveTextContent('Starting');
  await act(async () => release(current));
  expect(sent()).toHaveLength(1);
  expect(sent()[0].action).toBe('autopilot');
});

it('does not offer Turn on Autopilot while another operation runs', () => {
  current = poolSnapshot({ enabled: false, phase: 'off' });
  render(<Models backend={backendWith(current, { busy: true })} />);
  expect(screen.getByRole('button', { name: 'Turn on Autopilot' })).toBeDisabled();
});

it('locks a model action on the first click, so a double click sends it once', async () => {
  current = poolSnapshot();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  api.read.mockImplementation(async () => {
    await gate;
    return current;
  });
  render(<Models backend={backendWith(current)} />);
  const keep = screen.getByRole('button', { name: 'Keep Qwen 3.5 9B in memory' });
  fireEvent.click(keep);
  expect(within(row('Qwen 3.5 9B')).getByRole('status')).toBeVisible();
  fireEvent.click(keep);
  await act(async () => {
    release();
    await new Promise((resolve) => setTimeout(resolve, 20));
  });
  expect(sent().filter((action) => action.action === 'autopilot_pin')).toHaveLength(1);
});

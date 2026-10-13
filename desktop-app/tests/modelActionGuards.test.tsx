// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Action, Snapshot } from '../src/shared/contracts';
import { Models } from '../src/renderer/features/models/Models';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot, succeeded } from './modelsFixtures';

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

it('adds a downloaded model by starting Autopilot with it before Autopilot is set up', async () => {
  current = poolSnapshot({ enabled: false, configured: false, selected: [], pinned: [] });
  render(<Models backend={backendWith(current)} />);
  const add = within(row('Qwen 3.5 9B')).getByRole('button', { name: /Add to pool/ });
  await act(async () => fireEvent.click(add));
  const start = sent().find((action) => action.action === 'autopilot');
  expect(start).toBeDefined();
  expect(start.models).toContain('qwen-3.5-9b');
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

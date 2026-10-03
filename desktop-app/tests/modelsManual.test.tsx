// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Action } from '../src/shared/contracts';
import { Models } from '../src/renderer/features/models/Models';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot, succeeded } from './modelsFixtures';

const api = vi.hoisted(() => ({ act: vi.fn(), read: vi.fn(), onNavigate: () => () => {} }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

function renderModels(state = poolSnapshot({ enabled: false, phase: 'off' })) {
  const backend = backendWith(state);
  render(<Models backend={backend} />);
  return backend;
}

it('keeps the manual workflow while Autopilot is off', () => {
  const backend = renderModels();
  expect(screen.getByText('Native load allowance')).toBeVisible();
  expect(screen.getByRole('checkbox', { name: 'Select Qwen 3.6 35B A3B' })).toBeDisabled();
  fireEvent.click(screen.getByRole('checkbox', { name: 'Select Qwen 3.5 9B' }));
  fireEvent.click(screen.getByRole('button', { name: /Apply selection/ }));
  expect(backend.act).toHaveBeenCalledWith({
    action: 'switch',
    models: ['gpt-oss-20b', 'gemma-4-26b', 'qwen-3.5-9b'],
  });
});

it('offers to turn Autopilot on with the models serving now', async () => {
  api.act.mockImplementation(async (action: Action) => succeeded(action.action));
  renderModels();
  const offer = screen.getByRole('region', { name: 'Autopilot' });
  expect(offer).toHaveTextContent('downloaded models form Autopilot’s pool');
  expect(offer).toHaveTextContent('pin the ones that must always stay loaded');
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Turn on Autopilot' })));
  expect(api.act).toHaveBeenCalledExactlyOnceWith({
    action: 'autopilot',
    models: ['gpt-oss-20b', 'gemma-4-26b'],
    pinned: [],
    endpoint: false,
  });
});

it('shows an honest error when the runtime can’t turn Autopilot on', async () => {
  api.act.mockRejectedValue(new Error('Unknown action'));
  renderModels();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Turn on Autopilot' })));
  expect(screen.getByRole('alert')).toHaveTextContent(
    'This version of Darkbloom doesn’t support that Autopilot change.',
  );
  expect(screen.getByRole('button', { name: /Apply selection/ })).toBeEnabled();
});

it('falls back to manual selection with a note on a runtime without Autopilot', () => {
  renderModels(poolSnapshot(null));
  expect(screen.getByText(/Autopilot needs a newer Darkbloom runtime/)).toBeVisible();
  expect(screen.queryByRole('region', { name: 'Autopilot' })).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: /Pin/ })).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: /Apply selection/ })).toBeVisible();
});

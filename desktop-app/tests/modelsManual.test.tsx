// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
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
  expect(screen.getByText('Memory available for models')).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: /Show \d+ more models/ }));
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
  expect(offer).toHaveTextContent('Choose downloads. Autopilot manages what’s loaded.');
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

it('drops a chosen model from the selection once it is removed', () => {
  const state = poolSnapshot({ enabled: false, phase: 'off' });
  const backend = backendWith(state);
  const view = render(<Models backend={backend} />);
  fireEvent.click(screen.getByRole('checkbox', { name: 'Select Qwen 3.5 9B' }));
  const removed = {
    ...state,
    models: state.models.map((model) =>
      model.id === 'qwen-3.5-9b' ? { ...model, downloaded: false } : model,
    ),
  };
  view.rerender(<Models backend={backendWith(removed, { act: backend.act })} />);
  expect(screen.getByRole('checkbox', { name: 'Select Qwen 3.5 9B' })).not.toBeChecked();
  fireEvent.click(screen.getByRole('button', { name: /Apply selection/ }));
  expect(backend.act).toHaveBeenCalledWith({
    action: 'switch',
    models: ['gpt-oss-20b', 'gemma-4-26b'],
  });
});

it('does not draw unreported memory use as an empty bar', () => {
  const state = poolSnapshot({ enabled: false, phase: 'off' });
  const { container } = render(
    <Models
      backend={backendWith({ ...state, memory: { ...state.memory, active_gb: undefined } })}
    />,
  );
  expect(container.querySelector('.model-memory .memory-track')).toBeNull();
});

it('explains an empty Downloaded filter instead of blaming the catalog', () => {
  const state = poolSnapshot({ enabled: false, phase: 'off' });
  renderModels({
    ...state,
    models: state.models.map((model) => ({
      ...model,
      downloaded: false,
      serving: false,
      loaded: false,
    })),
  });
  fireEvent.click(screen.getByRole('button', { name: 'Downloaded' }));
  expect(screen.getByText('No downloaded models')).toBeVisible();
  expect(screen.queryByText(/load the model catalog/)).not.toBeInTheDocument();
});

it('does not offer to download a model this Mac cannot run', () => {
  const state = poolSnapshot({ enabled: false, phase: 'off' });
  renderModels({
    ...state,
    models: state.models.map((model) =>
      model.id === 'qwen-3.6-35b'
        ? { ...model, eligible: false, reason: 'Needs 512 GB of unified memory' }
        : model,
    ),
  });
  fireEvent.click(screen.getByRole('button', { name: /Show \d+ more models/ }));
  const row = screen.getByRole('heading', { name: 'Qwen 3.6 35B A3B' }).closest('article')!;
  expect(within(row as HTMLElement).getByRole('button', { name: /Download/ })).toBeDisabled();
});

it('locks the manual selection while Autopilot is turning on', async () => {
  api.act.mockReturnValueOnce(new Promise(() => {}));
  const backend = renderModels();
  fireEvent.click(screen.getByRole('button', { name: /Show \d+ more models/ }));
  fireEvent.click(screen.getByRole('checkbox', { name: 'Select Qwen 3.5 9B' }));
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Turn on Autopilot' })));
  expect(screen.getByRole('button', { name: 'Turning on…' })).toBeDisabled();
  expect(screen.getByRole('button', { name: /Apply selection/ })).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Remove Qwen 3.5 9B' })).toBeDisabled();
  for (const download of screen.getAllByRole('button', { name: 'Download' }))
    expect(download).toBeDisabled();
  fireEvent.click(screen.getByRole('button', { name: /Apply selection/ }));
  expect(backend.act).not.toHaveBeenCalled();
});

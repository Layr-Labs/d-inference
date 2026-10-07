// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
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

function renderModels(state = poolSnapshot()) {
  current = state;
  const backend = backendWith(state);
  render(<Models backend={backend} />);
  fireEvent.click(screen.getByRole('button', { name: 'Browse models' }));
  fireEvent.click(screen.getByRole('button', { name: /Show \d+ more models/ }));
  return backend;
}
const row = (name: string) => screen.getByRole('heading', { name }).closest('article')!;
const card = () => screen.getByRole('region', { name: 'Autopilot' });
const sent = () => api.act.mock.calls.map(([action]) => action);

describe('Autopilot on', () => {
  it('shows a compact live status and direct controls without serving selection', () => {
    renderModels();
    expect(within(card()).getByText('On')).toBeVisible();
    expect(card()).toHaveTextContent('3 available · 2 in memory');
    expect(screen.getByRole('button', { name: 'Keep GPT-OSS 20B in memory' })).toBeVisible();
    expect(screen.queryByRole('button', { name: /Apply selection/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
  });

  it('lists the catalog as the pool, with each model’s state and facts', () => {
    renderModels();
    expect(row('GPT-OSS 20B')).toHaveTextContent('In memory');
    expect(row('GPT-OSS 20B')).toHaveTextContent('12.1 GB on disk · needs 16.4 GB memory');
    expect(row('Gemma 4 26B')).toHaveTextContent('In memory · kept');
    expect(row('Qwen 3.5 9B')).toHaveTextContent('Available to Autopilot');
    expect(row('Qwen 3.6 35B A3B')).toHaveTextContent('Not downloaded');
    expect(row('Qwen 3.6 35B A3B')).toHaveTextContent('21.3 GB download');
    expect(row('Kimi K2.6')).toHaveTextContent('Not available');
    expect(row('Kimi K2.6')).toHaveTextContent('Needs 512 GB of unified memory.');
    expect(within(row('Kimi K2.6')).queryByRole('button')).not.toBeInTheDocument();
  });

  it('filters by pool state and searches', () => {
    renderModels();
    const headings = () => screen.getAllByRole('heading', { level: 3 }).map((h) => h.textContent);
    fireEvent.click(screen.getByRole('button', { name: 'Kept in memory' }));
    expect(headings()).toEqual(['Autopilot', 'Gemma 4 26B']);
    fireEvent.click(screen.getByRole('button', { name: 'Your models' }));
    expect(headings()).toEqual(['Autopilot', 'GPT-OSS 20B', 'Gemma 4 26B', 'Qwen 3.5 9B']);
    fireEvent.click(screen.getByRole('button', { name: 'Not downloaded' }));
    expect(headings()).toEqual(['Autopilot', 'Qwen 3.6 35B A3B']);
    fireEvent.click(screen.getByRole('button', { name: 'Browse models' }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Search models' }), {
      target: { value: 'qwen' },
    });
    expect(headings()).toEqual(['Autopilot', 'Qwen 3.5 9B', 'Qwen 3.6 35B A3B']);
  });

  it('downloads a model, then adds it to the pool', async () => {
    renderModels();
    await act(async () =>
      fireEvent.click(within(row('Qwen 3.6 35B A3B')).getByRole('button', { name: 'Download' })),
    );
    expect(sent()).toEqual([
      { action: 'download', model: 'qwen-3.6-35b' },
      { action: 'autopilot_models' },
    ]);
  });

  it('pins a model that isn’t downloaded by downloading it into the pool first', async () => {
    renderModels();
    await act(async () =>
      fireEvent.click(
        screen.getByRole('button', { name: 'Download & keep Qwen 3.6 35B A3B in memory' }),
      ),
    );
    expect(sent()).toEqual([
      { action: 'download', model: 'qwen-3.6-35b' },
      { action: 'autopilot_models' },
      { action: 'autopilot_pin', models: ['qwen-3.6-35b'] },
    ]);
  });

  it('pins a pool model directly and unpins a pinned one', async () => {
    renderModels();
    await act(async () =>
      fireEvent.click(screen.getByRole('button', { name: 'Keep Qwen 3.5 9B in memory' })),
    );
    const unpin = screen.getByRole('button', { name: 'Stop keeping Gemma 4 26B in memory' });
    expect(unpin).toHaveAttribute('aria-pressed', 'true');
    await act(async () => fireEvent.click(unpin));
    expect(sent()).toEqual([
      { action: 'autopilot_pin', models: ['qwen-3.5-9b'] },
      { action: 'autopilot_unpin', models: ['gemma-4-26b'] },
    ]);
  });

  it('adds a downloaded model outside the pool', async () => {
    renderModels(poolSnapshot({ selected: ['gpt-oss-20b', 'gemma-4-26b'] }));
    expect(row('Qwen 3.5 9B')).toHaveTextContent('Downloaded · not in Autopilot');
    await act(async () =>
      fireEvent.click(within(row('Qwen 3.5 9B')).getByRole('button', { name: /Add to pool/ })),
    );
    expect(sent()).toEqual([{ action: 'autopilot_models' }]);
  });

  it('protects resident and pinned models from removal', () => {
    renderModels();
    expect(screen.getByRole('button', { name: 'Remove Gemma 4 26B' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Remove GPT-OSS 20B' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Remove Qwen 3.5 9B' })).toBeEnabled();
    expect(sent()).toEqual([]);
  });

  it('refuses a pin that would need more memory than this Mac has', () => {
    renderModels(poolSnapshot({}, { memory: { total_gb: 32, free_for_load_gb: 4 } }));
    const pin = screen.getByRole('button', { name: 'Keep GPT-OSS 20B in memory' });
    expect(pin).toBeDisabled();
    expect(pin).toHaveAttribute('title', 'Pinning this needs more memory than this Mac has.');
    expect(screen.getByRole('button', { name: 'Keep Qwen 3.5 9B in memory' })).toBeEnabled();
  });

  it('shows download progress reported by the runtime', () => {
    renderModels(
      poolSnapshot(
        {},
        {
          operations: [
            {
              ...succeeded('download'),
              state: 'running',
              model: 'qwen-3.6-35b',
              progress: 0.4,
            },
          ],
        },
      ),
    );
    expect(row('Qwen 3.6 35B A3B')).toHaveTextContent('Downloading');
    expect(within(row('Qwen 3.6 35B A3B')).getByRole('progressbar')).toHaveAttribute(
      'aria-valuenow',
      '40',
    );
    expect(row('Qwen 3.6 35B A3B')).toHaveTextContent('40%');
  });

  it('starts with the saved startup models instead of loading the whole pool', async () => {
    renderModels(poolSnapshot({ phase: undefined }, { state: 'stopped' }));
    expect(within(card()).getByText('Ready')).toBeVisible();
    await act(async () => fireEvent.click(screen.getByRole('button', { name: /Start serving/ })));
    expect(api.act).toHaveBeenCalledWith({
      action: 'autopilot',
      models: ['gpt-oss-20b', 'gemma-4-26b'],
      pinned: [],
      endpoint: false,
    });
  });

  it('surfaces a rejected change honestly and stays usable', async () => {
    api.act.mockRejectedValueOnce(
      new Error("Error invoking remote method 'darkbloom:act': Error: Unknown action"),
    );
    renderModels();
    await act(async () =>
      fireEvent.click(screen.getByRole('button', { name: 'Keep Qwen 3.5 9B in memory' })),
    );
    expect(screen.getByRole('alert')).toHaveTextContent(
      'This version of Darkbloom doesn’t support that Autopilot change.',
    );
    expect(screen.getByRole('button', { name: 'Keep Qwen 3.5 9B in memory' })).toBeEnabled();
  });

  it('links first when a new user enables Autopilot from Models', async () => {
    renderModels(
      poolSnapshot(
        { enabled: false, configured: false, selected: [], pinned: [], phase: undefined },
        { linked: false },
      ),
    );
    await act(async () =>
      fireEvent.click(screen.getByRole('button', { name: 'Turn on Autopilot' })),
    );
    expect(sent().map((action) => action.action)).toEqual(['link', 'autopilot']);
  });

  it('never starts serving after account linking fails', async () => {
    api.act.mockResolvedValueOnce({
      ...succeeded('link'),
      state: 'failed',
      message: 'Link expired',
    });
    renderModels(
      poolSnapshot(
        { enabled: false, configured: false, selected: [], pinned: [], phase: undefined },
        { linked: false },
      ),
    );
    await act(async () =>
      fireEvent.click(screen.getByRole('button', { name: 'Turn on Autopilot' })),
    );
    expect(sent().map((action) => action.action)).toEqual(['link']);
    expect(screen.getByRole('alert')).toHaveTextContent('Link expired');
  });
});

describe('Autopilot phases', () => {
  it('says plainly that shadow mode leaves models as they are', () => {
    renderModels(poolSnapshot({ phase: 'shadow' }));
    expect(within(card()).getByText('Observing demand')).toBeVisible();
    expect(card()).toHaveTextContent(
      'Autopilot is observing demand; models stay as they are for now.',
    );
  });

  it('offers to refresh the pool when the runtime is waiting for it', async () => {
    renderModels(poolSnapshot({ phase: 'waiting_inventory' }));
    await act(async () =>
      fireEvent.click(screen.getByRole('button', { name: /Update available models/ })),
    );
    expect(sent()).toEqual([{ action: 'autopilot_models' }]);
  });

  it('pauses after confirming, and resumes', async () => {
    renderModels();
    fireEvent.click(screen.getByRole('button', { name: /Pause/ }));
    expect(screen.getByRole('dialog')).toHaveTextContent('Models stay loaded as they are');
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Pause Autopilot' })));
    expect(sent()).toEqual([{ action: 'autopilot_pause' }]);
    cleanup();
    renderModels(poolSnapshot({ paused: true, phase: 'paused' }));
    expect(within(card()).getByText('Paused')).toBeVisible();
    await act(async () => fireEvent.click(screen.getByRole('button', { name: /Resume/ })));
    expect(sent()).toContainEqual({ action: 'autopilot_resume' });
  });

  it('turns off after confirming that manual selection takes over', async () => {
    renderModels();
    fireEvent.click(screen.getByRole('button', { name: /Switch to manual/ }));
    expect(screen.getByRole('dialog')).toHaveTextContent(
      'Models stay loaded as they are and manual selection takes over',
    );
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(api.act).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: /Switch to manual/ }));
    await act(async () =>
      fireEvent.click(screen.getByRole('button', { name: 'Turn off Autopilot' })),
    );
    await waitFor(() => expect(sent()).toEqual([{ action: 'autopilot_disable' }]));
  });
});

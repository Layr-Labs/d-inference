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
  return backend;
}
const row = (name: string) => screen.getByRole('heading', { name }).closest('article')!;
const card = () => screen.getByRole('region', { name: 'Autopilot' });
const sent = () => api.act.mock.calls.map(([action]) => action);

describe('Autopilot on', () => {
  it('explains Autopilot and shows what is loaded, pinned and free to load', () => {
    renderModels();
    expect(within(card()).getByText('On')).toBeVisible();
    expect(card()).toHaveTextContent(
      'You choose which models live on this Mac. Autopilot decides which ones to load into memory as demand changes.',
    );
    expect(card()).toHaveTextContent('Loaded nowGPT-OSS 20B, Gemma 4 26B');
    expect(card()).toHaveTextContent('Pinned · always onGemma 4 26B');
    expect(card()).toHaveTextContent('Free to load20.0 GB of 64.0 GB');
    expect(card()).toHaveTextContent('1 pinned · 21.4 GB of 64 GB memory');
    expect(screen.queryByRole('button', { name: /Apply selection/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
  });

  it('lists the catalog as the pool, with each model’s state and facts', () => {
    renderModels();
    expect(row('GPT-OSS 20B')).toHaveTextContent('Loaded now · Autopilot');
    expect(row('GPT-OSS 20B')).toHaveTextContent('12.1 GB on disk · needs 16.4 GB memory');
    expect(row('Gemma 4 26B')).toHaveTextContent('Pinned · always on');
    expect(row('Qwen 3.5 9B')).toHaveTextContent('In pool');
    expect(row('Qwen 3.6 35B A3B')).toHaveTextContent('Not downloaded');
    expect(row('Qwen 3.6 35B A3B')).toHaveTextContent('21.3 GB download');
    expect(row('Kimi K2.6')).toHaveTextContent('Not available');
    expect(row('Kimi K2.6')).toHaveTextContent('Needs 512 GB of unified memory.');
    expect(within(row('Kimi K2.6')).queryByRole('button')).not.toBeInTheDocument();
  });

  it('filters by pool state and searches', () => {
    renderModels();
    const headings = () => screen.getAllByRole('heading', { level: 3 }).map((h) => h.textContent);
    fireEvent.click(screen.getByRole('button', { name: 'Pinned' }));
    expect(headings()).toEqual(['Autopilot', 'Gemma 4 26B']);
    fireEvent.click(screen.getByRole('button', { name: 'In pool' }));
    expect(headings()).toEqual(['Autopilot', 'GPT-OSS 20B', 'Gemma 4 26B', 'Qwen 3.5 9B']);
    fireEvent.click(screen.getByRole('button', { name: 'Not downloaded' }));
    expect(headings()).toEqual(['Autopilot', 'Qwen 3.6 35B A3B']);
    fireEvent.click(screen.getByRole('button', { name: 'All' }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Search models' }), {
      target: { value: 'qwen' },
    });
    expect(headings()).toEqual(['Autopilot', 'Qwen 3.5 9B', 'Qwen 3.6 35B A3B']);
  });

  it('downloads a model, then adds it to the pool', async () => {
    renderModels();
    await act(async () =>
      fireEvent.click(within(row('Qwen 3.6 35B A3B')).getByRole('button', { name: /Download/ })),
    );
    expect(sent()).toEqual([
      { action: 'download', model: 'qwen-3.6-35b' },
      { action: 'autopilot_models' },
    ]);
  });

  it('pins a model that isn’t downloaded by downloading it into the pool first', async () => {
    renderModels();
    await act(async () =>
      fireEvent.click(screen.getByRole('button', { name: 'Pin Qwen 3.6 35B A3B' })),
    );
    expect(sent()).toEqual([
      { action: 'download', model: 'qwen-3.6-35b' },
      { action: 'autopilot_models' },
      { action: 'autopilot_pin', models: ['qwen-3.6-35b'] },
    ]);
  });

  it('pins a pool model directly and unpins a pinned one', async () => {
    renderModels();
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Pin Qwen 3.5 9B' })));
    const unpin = screen.getByRole('button', { name: 'Unpin Gemma 4 26B' });
    expect(unpin).toHaveAttribute('aria-pressed', 'true');
    await act(async () => fireEvent.click(unpin));
    expect(sent()).toEqual([
      { action: 'autopilot_pin', models: ['qwen-3.5-9b'] },
      { action: 'autopilot_unpin', models: ['gemma-4-26b'] },
    ]);
  });

  it('adds a downloaded model outside the pool', async () => {
    renderModels(poolSnapshot({ selected: ['gpt-oss-20b', 'gemma-4-26b'] }));
    expect(row('Qwen 3.5 9B')).toHaveTextContent('On this Mac · not in pool');
    await act(async () =>
      fireEvent.click(within(row('Qwen 3.5 9B')).getByRole('button', { name: /Add to pool/ })),
    );
    expect(sent()).toEqual([{ action: 'autopilot_models' }]);
  });

  it('blocks removing a pinned model, and explains that a loaded model is unloaded first', async () => {
    renderModels();
    expect(screen.getByRole('button', { name: 'Remove Gemma 4 26B' })).toBeDisabled();
    expect(row('Gemma 4 26B')).toHaveTextContent('Unpin it to remove it from this Mac.');
    fireEvent.click(screen.getByRole('button', { name: 'Remove GPT-OSS 20B' }));
    expect(screen.getByRole('dialog')).toHaveTextContent(
      'This deletes GPT-OSS 20B from this Mac and takes it out of the Autopilot pool. Autopilot unloads it first.',
    );
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Remove model' })));
    expect(sent()).toEqual([{ action: 'remove', model: 'gpt-oss-20b' }]);
  });

  it('refuses a pin that would need more memory than this Mac has', () => {
    renderModels(poolSnapshot({}, { memory: { total_gb: 32, free_for_load_gb: 4 } }));
    const pin = screen.getByRole('button', { name: 'Pin GPT-OSS 20B' });
    expect(pin).toBeDisabled();
    expect(pin).toHaveAttribute('title', 'Pinning this needs more memory than this Mac has.');
    expect(screen.getByRole('button', { name: 'Pin Qwen 3.5 9B' })).toBeEnabled();
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

  it('starts serving the pool when this Mac is stopped', () => {
    const backend = renderModels(poolSnapshot({ phase: undefined }, { state: 'stopped' }));
    expect(within(card()).getByText('Ready')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: /Start serving/ }));
    expect(backend.act).toHaveBeenCalledWith({
      action: 'start',
      models: ['gpt-oss-20b', 'gemma-4-26b', 'qwen-3.5-9b'],
    });
  });

  it('surfaces a rejected change honestly and stays usable', async () => {
    api.act.mockRejectedValueOnce(
      new Error("Error invoking remote method 'darkbloom:act': Error: Unknown action"),
    );
    renderModels();
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Pin Qwen 3.5 9B' })));
    expect(screen.getByRole('alert')).toHaveTextContent(
      'This version of Darkbloom doesn’t support that Autopilot change.',
    );
    expect(screen.getByRole('button', { name: 'Pin Qwen 3.5 9B' })).toBeEnabled();
  });
});

describe('Autopilot phases', () => {
  it('says plainly that shadow mode leaves models as they are', () => {
    renderModels(poolSnapshot({ phase: 'shadow' }));
    expect(within(card()).getByText('Learning')).toBeVisible();
    expect(card()).toHaveTextContent('Autopilot is learning; models stay as they are for now.');
  });

  it('offers to refresh the pool when the runtime is waiting for it', async () => {
    renderModels(poolSnapshot({ phase: 'waiting_inventory' }));
    await act(async () => fireEvent.click(screen.getByRole('button', { name: /Refresh pool/ })));
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
    fireEvent.click(screen.getByRole('button', { name: /Turn off/ }));
    expect(screen.getByRole('dialog')).toHaveTextContent(
      'Models stay loaded as they are and manual selection takes over',
    );
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(api.act).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: /Turn off/ }));
    await act(async () =>
      fireEvent.click(screen.getByRole('button', { name: 'Turn off Autopilot' })),
    );
    await waitFor(() => expect(sent()).toEqual([{ action: 'autopilot_disable' }]));
  });
});

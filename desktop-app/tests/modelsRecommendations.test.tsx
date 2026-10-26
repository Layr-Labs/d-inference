// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { NetworkData } from '../src/shared/contracts';
import {
  networkEarnings,
  recommendedModels,
  recommendedStart,
} from '../src/renderer/features/models/recommendations';
import { RecommendedModels } from '../src/renderer/features/models/RecommendedModels';
import { Models } from '../src/renderer/features/models/Models';
import { backendWith } from './onboardingFixtures';
import { poolModels, poolSnapshot } from './modelsFixtures';
import { pinnedMemory } from '../src/renderer/models/selection';

vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api: undefined }));
afterEach(cleanup);
const network: NetworkData = {
  model_earnings: {
    window: '7d',
    as_of: new Date().toISOString(),
    models: [
      { id: 'kimi-k2.6', earnings_micro_usd: '9007199254740999' },
      { id: 'qwen-3.6-35b', earnings_micro_usd: '4000000' },
      { id: 'qwen-3.5-9b', earnings_micro_usd: '3000000' },
      { id: 'gpt-oss-20b', earnings_micro_usd: '2000000' },
      { id: 'gemma-4-26b', earnings_micro_usd: '1000000' },
    ],
  },
};

describe('network recommendations', () => {
  it('browses native catalog models whose memory has not been measured yet', () => {
    // Swift serializes absent measurements as JSON null, including undownloaded models.
    const models = poolModels.map((model) =>
      model.downloaded ? model : { ...model, memory_gb: null },
    );
    const snapshot = poolSnapshot({}, { models });
    render(<Models backend={backendWith(snapshot)} />);
    fireEvent.click(screen.getByRole('button', { name: 'Browse models' }));
    fireEvent.click(screen.getByRole('button', { name: 'Show 2 more models' }));
    const row = screen.getByRole('heading', { name: 'Qwen 3.6 35B A3B' }).closest('article')!;
    expect(row).toHaveTextContent('21.3 GB download');
    expect(row).not.toHaveTextContent('needs');
    expect(within(row).getByRole('button', { name: 'Download' })).toBeEnabled();
    expect(pinnedMemory(snapshot, ['qwen-3.6-35b'])).toMatchObject({
      needed: 21.3,
      measured: false,
    });
    fireEvent.click(screen.getByRole('button', { name: 'Not downloaded' }));
    expect(screen.getByRole('heading', { name: 'Qwen 3.6 35B A3B' })).toBeVisible();
  });
  it('chooses three compatible models using network earnings independently of downloads', () => {
    const selected = recommendedModels(poolModels, networkEarnings(network));
    expect(selected.map((m) => m.id)).toEqual(['qwen-3.6-35b', 'qwen-3.5-9b', 'gpt-oss-20b']);
    expect(recommendedStart(poolSnapshot(), selected)).toEqual({
      action: 'autopilot',
      models: ['qwen-3.6-35b'],
      pinned: [],
      downloads: ['qwen-3.6-35b'],
      endpoint: false,
    });
  });
  it('preserves integer precision and rejects missing or invalid ranking data', () => {
    expect(networkEarnings(network)?.get('kimi-k2.6')).toBe(9007199254740999n);
    expect(recommendedModels(poolModels, networkEarnings(undefined))).toEqual([]);
    expect(networkEarnings({ ...network, error: 'Unavailable' })).toBeNull();
    expect(
      networkEarnings({
        ...network,
        model_earnings: {
          ...network.model_earnings!,
          as_of: new Date(Date.now() - 6 * 60_000).toISOString(),
        },
      }),
    ).toBeNull();
    expect(
      networkEarnings({
        ...network,
        model_earnings: {
          ...network.model_earnings!,
          models: [{ id: 'a', earnings_micro_usd: '-1' }],
        },
      }),
    ).toBeNull();
    expect(
      networkEarnings({
        ...network,
        model_earnings: {
          ...network.model_earnings!,
          models: [
            { id: 'a', earnings_micro_usd: '1' },
            { id: 'a', earnings_micro_usd: '2' },
          ],
        },
      }),
    ).toBeNull();
  });
  it('preselects all three downloads and lets people remove one before starting', () => {
    const selected = recommendedModels(poolModels, networkEarnings(network));
    const onStart = vi.fn();
    render(
      <RecommendedModels
        snapshot={poolSnapshot()}
        models={selected}
        earnings={networkEarnings(network)}
        setup
        busy={false}
        onStart={onStart}
      />,
    );
    expect(screen.getAllByRole('checkbox')).toHaveLength(3);
    for (const checkbox of screen.getAllByRole('checkbox')) expect(checkbox).toBeChecked();
    fireEvent.click(screen.getByRole('checkbox', { name: 'Choose Qwen 3.6 35B A3B' }));
    fireEvent.click(screen.getByRole('button', { name: 'Start Autopilot' }));
    expect(onStart).toHaveBeenCalledWith({
      action: 'autopilot',
      models: ['qwen-3.5-9b'],
      pinned: [],
      downloads: [],
      endpoint: false,
    });
  });
  it('opens Your models by default and sorts Browse using network earnings', () => {
    render(<Models backend={backendWith(poolSnapshot(), { network })} />);
    expect(screen.getByRole('button', { name: 'Your models' })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    const rows = () =>
      screen
        .getAllByRole('heading', { level: 3 })
        .filter((h) => h.closest('article'))
        .map((h) => h.textContent);
    expect(rows()).toEqual(['GPT-OSS 20B', 'Gemma 4 26B', 'Qwen 3.5 9B']);
    fireEvent.click(screen.getByRole('button', { name: 'Browse models' }));
    expect(rows()).toEqual(['Kimi K2.6', 'Qwen 3.6 35B A3B', 'Qwen 3.5 9B']);
    const expand = screen.getByRole('button', { name: 'Show 2 more models' });
    expect(expand).toHaveAttribute('aria-expanded', 'false');
    fireEvent.click(expand);
    expect(rows()).toEqual([
      'Kimi K2.6',
      'Qwen 3.6 35B A3B',
      'Qwen 3.5 9B',
      'GPT-OSS 20B',
      'Gemma 4 26B',
    ]);
    fireEvent.click(screen.getByRole('button', { name: 'Show fewer models' }));
    expect(rows()).toHaveLength(3);
    fireEvent.click(screen.getByRole('button', { name: 'Show 2 more models' }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Search models' }), {
      target: { value: 'gpt' },
    });
    expect(rows()).toEqual(['GPT-OSS 20B']);
    expect(screen.queryByRole('button', { name: /Show .* models/ })).not.toBeInTheDocument();
    fireEvent.change(screen.getByRole('textbox', { name: 'Search models' }), {
      target: { value: '' },
    });
    expect(rows()).toHaveLength(3);
    expect(screen.getByText('Network earnings · 7 days')).toBeVisible();
  });
  it('shows a cold pin as waiting instead of claiming it is resident', () => {
    render(<Models backend={backendWith(poolSnapshot({ pinned: ['qwen-3.5-9b'] }))} />);
    const row = screen.getByRole('heading', { name: 'Qwen 3.5 9B' }).closest('article')!;
    expect(row).toHaveTextContent('Kept · waiting to load');
    expect(
      within(row).getByRole('button', { name: 'Stop keeping Qwen 3.5 9B in memory' }),
    ).toHaveAttribute('aria-pressed', 'true');
  });
  it('first use shows Autopilot setup and does not silently invent missing recommendations', () => {
    render(
      <Models
        backend={backendWith(
          poolSnapshot({
            enabled: false,
            configured: false,
            selected: [],
            pinned: [],
            phase: undefined,
          }),
        )}
      />,
    );
    expect(screen.getByText(/Network recommendations are unavailable/)).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Apply selection' })).not.toBeInTheDocument();
  });
});

// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Models } from '../src/renderer/features/models/Models';
import { parseInsights } from '../src/renderer/features/insights/types';
import { previewInsights } from '../src/renderer/previewInsights';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';

const mocks = vi.hoisted(() => ({ data: null as any }));
vi.mock('../src/renderer/features/insights/useInsights', () => ({
  useInsights: () => ({ data: mocks.data, error: null }),
}));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api: undefined }));
afterEach(cleanup);

for (const enabled of [false, true]) {
  it(`orders ${enabled ? 'Autopilot' : 'manual'} rows by earnings while preserving filters and selections`, () => {
    const state = poolSnapshot({ enabled });
    const insights = parseInsights(previewInsights('30d'));
    const template = insights.models[0];
    insights.models = [
      { ...template, id: 'gpt-oss-20b', work_micro_usd: 1_000_000n, base_reward_micro_usd: 0n },
      { ...template, id: 'gemma-4-26b', work_micro_usd: 4_000_000n, base_reward_micro_usd: 0n },
      { ...template, id: 'qwen-3.5-9b', work_micro_usd: 2_000_000n, base_reward_micro_usd: 0n },
    ];
    mocks.data = insights;
    const backend = backendWith(state);
    render(<Models backend={backend} />);
    expect(
      screen
        .getAllByRole('heading', { level: 3 })
        .filter((heading) => heading.closest('.model-row'))
        .map((heading) => heading.textContent),
    ).toEqual(['Gemma 4 26B', 'Qwen 3.5 9B', 'GPT-OSS 20B', 'Qwen 3.6 35B A3B', 'Kimi K2.6']);
    expect(screen.getByText('Most earned · 30d')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: enabled ? 'In pool' : 'Serving' }));
    expect(screen.queryByRole('heading', { name: 'Qwen 3.6 35B A3B' })).not.toBeInTheDocument();
    if (!enabled) {
      expect(screen.getByRole('checkbox', { name: 'Select Gemma 4 26B' })).toBeChecked();
      fireEvent.click(screen.getByRole('button', { name: /Apply selection/ }));
      expect(backend.act).toHaveBeenCalledWith({
        action: 'switch',
        models: ['gpt-oss-20b', 'gemma-4-26b'],
      });
    }
  });
}

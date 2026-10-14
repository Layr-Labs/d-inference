// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { EarningsBreakdown } from '../src/renderer/features/insights/EarningsBreakdown';
import { parseInsights } from '../src/renderer/features/insights/types';
import { previewInsights } from '../src/renderer/previewInsights';
import { poolSnapshot } from './modelsFixtures';

const api = vi.hoisted(() => ({ read: vi.fn(), copy: vi.fn(), onNavigate: () => () => {} }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

it('names models from the catalog and keeps unknown ids readable', () => {
  const data = parseInsights(previewInsights('7d'));
  const models = poolSnapshot().models.filter((model) => model.id !== 'qwen-3.5-9b');
  render(<EarningsBreakdown data={data} metric="earnings" models={models} />);
  expect(screen.getByText('GPT-OSS 20B')).toBeVisible();
  expect(screen.queryByText('gpt-oss-20b')).not.toBeInTheDocument();
  // Not in the catalog: the settled id is still shown.
  expect(screen.getByText('qwen-3.5-9b')).toBeVisible();
});

it('clears “Copied” after confirming a CSV copy', async () => {
  vi.useFakeTimers();
  api.copy.mockResolvedValue(undefined);
  api.read.mockResolvedValue(previewInsights('7d'));
  const { Earnings } = await import('../src/renderer/features/Earnings');
  const { backendWith } = await import('./onboardingFixtures');
  const state = { ...poolSnapshot(), account: { signed_in: true } };
  render(<Earnings backend={backendWith(state)} />);
  await act(async () => {
    await vi.runOnlyPendingTimersAsync();
  });
  await act(async () => fireEvent.click(screen.getByRole('button', { name: /Copy CSV/ })));
  expect(screen.getByRole('button', { name: /Copied/ })).toBeVisible();
  await act(async () => {
    await vi.advanceTimersByTimeAsync(2000);
  });
  expect(screen.getByRole('button', { name: /Copy CSV/ })).toBeVisible();
});

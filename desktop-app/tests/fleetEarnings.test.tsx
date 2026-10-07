// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { FleetEarnings } from '../src/renderer/features/home/FleetEarnings';
import { parseInsights } from '../src/renderer/features/insights/types';
import { previewInsights } from '../src/renderer/previewInsights';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';
import { ModelEarningsOrder } from '../src/renderer/features/models/ModelEarnings';
import { modelEarnings } from '../src/renderer/features/models/earnings';

const mocks = vi.hoisted(() => ({ data: null as any }));
vi.mock('../src/renderer/features/insights/useInsights', () => ({
  useInsights: () => ({ data: mocks.data, error: null }),
}));
afterEach(cleanup);
it('shows account lifetime and summed recent history without projecting a truncated week', () => {
  mocks.data = parseInsights({
    ...previewInsights('7d'),
    history_complete: false,
    lifetime: {
      count: '1234',
      total_micro_usd: '12345678',
      prompt_tokens: null,
      completion_tokens: null,
    },
  });
  const backend = backendWith(poolSnapshot());
  backend.cloud = {
    linked: true,
    observed_at: 1,
    machines: [],
    lifetime_micro_usd: '12345678',
    week_micro_usd: '1200000',
    earnings_complete: false,
    earnings_since: 1791052800,
    settled_records: '1234',
  };
  render(<FleetEarnings backend={backend} onEarnings={vi.fn()} />);
  expect(screen.getByText('$12.35')).toBeVisible();
  expect(screen.getByText('$1.20')).toBeVisible();
  expect(screen.getByText('Recent earnings')).toBeVisible();
  expect(screen.getByText('1,234')).toBeVisible();
  expect(screen.queryByText('Annualized pace')).not.toBeInTheDocument();
  expect(screen.queryByText('Past 7 days')).not.toBeInTheDocument();
  expect(screen.getByText('Daily earnings · 7 days')).toBeVisible();
});
it('keeps the week and annualized pace for complete history', () => {
  mocks.data = parseInsights(previewInsights('7d'));
  const backend = backendWith(poolSnapshot());
  backend.cloud = {
    linked: true,
    observed_at: 1,
    machines: [],
    lifetime_micro_usd: '12345678',
    week_micro_usd: '7000000',
    earnings_complete: true,
  };
  render(<FleetEarnings backend={backend} onEarnings={vi.fn()} />);
  expect(screen.getByText('Past 7 days')).toBeVisible();
  expect(screen.getByText('Annualized pace')).toBeVisible();
  expect(screen.getByText('$365')).toBeVisible();
});
it('does not call a ranking from bounded history a full thirty-day ranking', () => {
  const data = parseInsights({ ...previewInsights('30d'), history_complete: false });
  render(<ModelEarningsOrder earnings={modelEarnings(data)} error={null} linked />);
  expect(screen.getByText('Most earned · Recent')).toBeVisible();
  expect(screen.queryByText('Most earned · 30d')).not.toBeInTheDocument();
});

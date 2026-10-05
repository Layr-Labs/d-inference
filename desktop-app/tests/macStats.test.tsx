// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { ChipReadouts } from '../src/renderer/features/home/chip/ChipReadouts';
import { EarningsTimeline } from '../src/renderer/features/insights/EarningsTimeline';
import { parseInsights } from '../src/renderer/features/insights/types';
import { previewInsights } from '../src/renderer/previewInsights';
import {
  parseRequestHistory,
  tokensPerSecond,
} from '../src/renderer/features/stats/activity/requests';
import { RequestTable } from '../src/renderer/features/stats/activity/RequestTable';
import { recordedTraffic } from '../src/renderer/features/stats/data';
import { tokenBars } from '../src/renderer/features/stats/tokenSeries';
import { MacPerformance } from '../src/renderer/features/stats/Performance';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';

const mocks = vi.hoisted(() => ({ history: undefined as any }));
vi.mock('../src/renderer/features/stats/activity/useRequestHistory', () => ({
  useRequestHistory: () => ({ history: mocks.history }),
}));
afterEach(cleanup);
const history = () =>
  parseRequestHistory({
    observed_at: 100,
    records: [
      {
        id: 'ledger-1',
        settled_at: 99,
        model: 'actual-model',
        input_tokens: 12000,
        output_tokens: 1000,
        outcome: 'settled',
        earnings_micro_usd: '123',
      },
    ],
  });
it('hides missing live activity while preserving measured zeroes', () => {
  const props = { mode: 'Live from this Mac', live: true, phase: null, hardware: null };
  const view = render(
    <ChipReadouts {...props} tokensPerSecond={null} running={null} waiting={null} />,
  );
  for (const label of ['tokens per second', 'In progress', 'Waiting'])
    expect(screen.queryByText(label)).not.toBeInTheDocument();
  view.rerender(<ChipReadouts {...props} tokensPerSecond={0} running={0} waiting={0} />);
  for (const label of ['tokens per second', 'In progress', 'Waiting'])
    expect(screen.getByText(label)).toBeVisible();
});
it('shows seven calendar days and identifies unavailable history without zero earnings', () => {
  const fixture = previewInsights('7d');
  const data = parseInsights({
    ...fixture,
    days: fixture.days.map((day, i) => ({ ...day, available: i >= 5, complete: i === 5 })),
  });
  render(<EarningsTimeline days={data.days} metric="earnings" partial />);
  const bars = within(screen.getByRole('group', { name: 'Daily earnings in UTC' })).getAllByRole(
    'button',
  );
  expect(bars).toHaveLength(7);
  expect(bars[0]).toHaveAccessibleName(/History unavailable/);
  fireEvent.click(bars[0]);
  expect(screen.getByText('History unavailable')).toBeVisible();
  expect(screen.queryByText(/inference$/)).not.toBeInTheDocument();
});
it('uses settlement time and omits unreported duration and speed columns', () => {
  const data = history();
  expect(tokensPerSecond(data.records[0])).toBeUndefined();
  render(<RequestTable records={data.records} names={new Map()} now={100} />);
  expect(screen.getByRole('columnheader', { name: 'Settled at' })).toBeVisible();
  expect(screen.queryByRole('columnheader', { name: 'Duration' })).not.toBeInTheDocument();
  expect(screen.queryByRole('columnheader', { name: 'Tokens/s' })).not.toBeInTheDocument();
  expect(screen.getByText('12,000')).toBeVisible();
  expect(screen.getByText('Settled')).toBeVisible();
});
it('fills this Mac Stats with verified input, output, session earnings and model history', () => {
  mocks.history = history();
  const state = poolSnapshot();
  state.activity = {
    ...state.activity,
    requests: '4',
    processed_input_tokens: '12000',
    processed_output_tokens: '1000',
    processed_tokens: '13000',
    earnings_micro_usd: '123',
    samples: [],
  };
  render(<MacPerformance backend={backendWith(state)} />);
  expect(screen.getByText('13,000')).toBeVisible();
  expect(screen.getByText('Input tokens')).toBeVisible();
  expect(screen.getByText('actual-model')).toBeVisible();
  expect(screen.queryByText('Success rate')).not.toBeInTheDocument();
  expect(screen.queryByText('Waiting for activity')).not.toBeInTheDocument();
  expect(
    screen.queryByText(/Per-model traffic history is not yet available/),
  ).not.toBeInTheDocument();
});

it('builds traffic from settlement metadata including input without inventing cached tokens', () => {
  const records = history().records;
  const points = recordedTraffic([...records, { ...records[0], id: 'later', settled_at: 4000 }]);
  expect(points.map((point) => point.requests)).toEqual([1, 0, 1]);
  expect(points.reduce((sum, point) => sum + point.input!, 0)).toBe(24000);
  expect(tokenBars(points).reduce((sum, bar) => sum + bar.total, 0)).toBe(26000);
  expect(points.every((point) => point.cached === undefined)).toBe(true);
});

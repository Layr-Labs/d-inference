// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { RequestFlow } from '../src/renderer/features/stats/RequestFlow';
import { TrafficChart } from '../src/renderer/features/stats/TrafficChart';
import { observedTraffic, activityFresh } from '../src/renderer/features/stats/data';
import { tokenBars } from '../src/renderer/features/stats/tokenSeries';
import { previewAPI } from '../src/renderer/preview';
import type { Snapshot } from '../src/shared/contracts';
afterEach(() => {
  cleanup();
  vi.useRealTimers();
});
it('stops the illustrative flow when paused, stopped, stale, or idle', async () => {
  const state = await previewAPI.read<Snapshot>('state');
  state.observed_at = Date.now() / 1000;
  state.activity.sampled_at = state.observed_at;
  const { rerender } = render(<RequestFlow state={state} preview />);
  const flow = screen.getByRole('region', { name: 'Requests moving through this Mac' });
  expect(flow).toHaveAttribute('data-animate', 'true');
  fireEvent.click(screen.getByRole('button', { name: 'Pause activity animation' }));
  expect(flow).toHaveAttribute('data-animate', 'false');
  fireEvent.click(screen.getByRole('button', { name: 'Resume activity animation' }));
  rerender(<RequestFlow state={{ ...state, state: 'stopped' }} preview />);
  expect(flow).toHaveAttribute('data-animate', 'false');
  rerender(<RequestFlow state={{ ...state, observed_at: 1 }} preview />);
  expect(flow).toHaveAttribute('data-animate', 'false');
  rerender(
    <RequestFlow state={{ ...state, activity: { ...state.activity, models: [] } }} preview />,
  );
  expect(flow).toHaveAttribute('data-animate', 'false');
});
it('does not invent live stages or counts for a runtime without activity observations', async () => {
  const state = await previewAPI.read<Snapshot>('state');
  state.activity.models = undefined;
  expect(activityFresh(state, Date.now() / 1000)).toBe(false);
  render(<RequestFlow state={state} preview={false} />);
  expect(screen.queryByText('Receive')).not.toBeInTheDocument();
  expect(screen.getAllByText('—')).toHaveLength(2);
});
it('uses observed counter deltas and discards resets or reversed timestamps', async () => {
  const state = await previewAPI.read<Snapshot>('state');
  state.activity.samples = [
    { at: 1, requests: 10, tokens: 100 },
    { at: 2, requests: 12, tokens: 150 },
    { at: 3, requests: 1, tokens: 10 },
    { at: 2, requests: 3, tokens: 30 },
  ];
  expect(observedTraffic(state)).toEqual([{ at: 2, requests: 2, tokens: 50 }]);
});
it('makes plotted traffic inspectable and allows changing the metric', () => {
  const change = vi.fn();
  render(
    <TrafficChart
      points={[{ at: 1, requests: 5, tokens: 100 }]}
      metric="requests"
      onMetric={change}
      scope="Observed intervals"
    />,
  );
  expect(screen.getByRole('img', { name: 'requests over time' })).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Tokens served' }));
  expect(change).toHaveBeenCalledWith('tokens');
  expect(screen.getByRole('button', { name: /5 requests/ })).toBeVisible();
  expect(screen.queryByRole('list', { name: 'Chart legend' })).not.toBeInTheDocument();
});
it('splits prompt counters into uncached and cached input deltas', async () => {
  const state = await previewAPI.read<Snapshot>('state');
  state.activity.samples = [
    { at: 1, requests: 1, tokens: 100, input_tokens: 300, cached_input_tokens: 200 },
    { at: 2, requests: 2, tokens: 160, input_tokens: 420, cached_input_tokens: 500 },
    { at: 3, requests: 3, tokens: 200, input_tokens: 20, cached_input_tokens: 600 },
    { at: 4, requests: 4, tokens: 260 },
    { at: 5, requests: 5, tokens: 300, input_tokens: 50, cached_input_tokens: 10 },
    { at: 6, requests: 6, tokens: 330, input_tokens: 80 },
  ];
  expect(observedTraffic(state)).toEqual([
    { at: 2, requests: 1, tokens: 60, input: 120, cached: 300 },
    { at: 4, requests: 1, tokens: 60 },
    { at: 5, requests: 1, tokens: 40 },
    { at: 6, requests: 1, tokens: 30, input: 30 },
  ]);
});
it('sums a split into a bar only when every interval in it reported the split', () => {
  const points = [
    { at: 1, requests: 1, tokens: 10, input: 5, cached: 1 },
    { at: 2, requests: 1, tokens: 20, input: 6, cached: 2 },
    { at: 3, requests: 1, tokens: 30, input: 7 },
  ];
  expect(tokenBars(points, 2)).toEqual([
    { at: 2, input: 11, cached: 3, output: 30, total: 44 },
    { at: 3, input: 7, output: 30, total: 37 },
  ]);
  expect(tokenBars(points)).toHaveLength(3);
});
it('stacks input, cached input and output tokens with a legend and labelled bars', () => {
  const at = new Date(2026, 9, 2, 16).getTime() / 1000;
  render(
    <TrafficChart
      points={[
        { at, requests: 5, tokens: 1_000, input: 2_500, cached: 1_500 },
        { at: at + 1800, requests: 2, tokens: 400, input: 900, cached: 2_100 },
      ]}
      metric="tokens"
      onMetric={vi.fn()}
      scope="Past 24 hours"
    />,
  );
  expect(screen.getByRole('button', { name: 'Tokens served' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  expect(screen.getAllByRole('listitem').map((item) => item.textContent)).toEqual([
    'Input tokens',
    'Cached input tokens',
    'Output tokens',
  ]);
  const bar = screen.getByRole('button', {
    name: '04:00 PM: Input 2,500 · Cached input 1,500 · Output 1,000 · Total 5,000 tokens',
  });
  expect(bar).toHaveAttribute('title', bar.getAttribute('aria-label'));
  expect(screen.getByText('8.4K')).toBeVisible();
  expect(screen.queryByText(/not reported by this runtime/)).not.toBeInTheDocument();
});
it('falls back to output-only bars with a note when the runtime reports no prompt split', () => {
  render(
    <TrafficChart
      points={[{ at: new Date(2026, 9, 2, 9).getTime() / 1000, requests: 3, tokens: 700 }]}
      metric="tokens"
      onMetric={vi.fn()}
      scope="Observed intervals"
    />,
  );
  expect(screen.getAllByRole('listitem').map((item) => item.textContent)).toEqual([
    'Output tokens',
  ]);
  expect(
    screen.getByRole('button', {
      name: '09:00 AM: Input not reported · Cached input not reported · Output 700 · Total 700 tokens',
    }),
  ).toBeVisible();
  expect(
    screen.getByText('Input and cached input counts are not reported by this runtime yet.'),
  ).toBeVisible();
});

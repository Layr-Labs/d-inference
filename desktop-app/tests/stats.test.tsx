// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { RequestFlow } from '../src/renderer/features/stats/RequestFlow';
import { TrafficChart } from '../src/renderer/features/stats/TrafficChart';
import { observedTraffic, activityFresh } from '../src/renderer/features/stats/data';
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
  fireEvent.click(screen.getByRole('button', { name: 'Output tokens' }));
  expect(change).toHaveBeenCalledWith('tokens');
  expect(screen.getByRole('button', { name: /5 requests/ })).toBeVisible();
});

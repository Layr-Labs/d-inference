// @vitest-environment jsdom
import React from 'react';
import {
  act,
  cleanup,
  fireEvent,
  render,
  renderHook,
  screen,
  waitFor,
} from '@testing-library/react';
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { parseInsights, money, percent } from '../src/renderer/features/insights/types';
import { tokenProgress } from '../src/renderer/features/insights/activity';
import { LiveModels } from '../src/renderer/features/insights/LiveModels';
import { TokenMilestones } from '../src/renderer/features/insights/TokenMilestones';
import { previewInsights } from '../src/renderer/previewInsights';
import type { Snapshot } from '../src/shared/contracts';

beforeAll(() => {
  window.history.replaceState({}, '', '/?preview');
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.useRealTimers();
});

it('preserves ledger integers beyond JavaScript number precision', () => {
  const fixture = previewInsights('7d');
  fixture.totals.work_micro_usd = '9007199254740993';
  const data = parseInsights(fixture);
  expect(data.totals.work_micro_usd).toBe(9007199254740993n);
  expect(money(data.totals.work_micro_usd)).toBe('$9,007,199,254.74');
  expect(percent(1n, 4n)).toBe(25);
  expect(() => parseInsights({ ...fixture, totals: { ...fixture.totals, jobs: 4 } })).toThrow();
});
it('does not animate or claim stale native model counts', () => {
  const state = {
    state: 'running',
    observed_at: Date.now() / 1000,
    models: [],
    activity: {
      sampled_at: Date.now() / 1000,
      models: [{ model: 'test', state: 'running', running: 5, waiting: 0 }],
    },
  } as unknown as Snapshot;
  const { rerender, container } = render(<LiveModels state={state} />);
  expect(screen.getByText('5 running')).toBeInTheDocument();
  expect(container.querySelectorAll('[data-active="true"]')).toHaveLength(5);
  fireEvent.click(screen.getByRole('button', { name: 'Pause activity animation' }));
  expect(container.querySelector('[data-animate="false"]')).toBeInTheDocument();
  rerender(<LiveModels state={{ ...state, activity: { ...state.activity, sampled_at: 1 } }} />);
  expect(screen.queryByText('5 running')).not.toBeInTheDocument();
  expect(container.querySelectorAll('[data-active="true"]')).toHaveLength(0);
  rerender(
    <LiveModels
      state={{
        ...state,
        activity: {
          ...state.activity,
          models: [{ model: 'test', state: 'crashed', running: 5, waiting: 0 }],
        },
      }}
    />,
  );
  expect(screen.queryByText('5 running')).not.toBeInTheDocument();
  expect(container.querySelectorAll('[data-active="true"]')).toHaveLength(0);
});
it('celebrates a new milestone once and handles exact boundaries', () => {
  vi.useFakeTimers();
  expect(tokenProgress(100000n).next).toBe(1000000n);
  const { rerender } = render(<TokenMilestones tokens={999999n} />);
  expect(screen.queryByText(/Milestone reached!/)).not.toBeInTheDocument();
  rerender(<TokenMilestones tokens={1000000n} />);
  expect(screen.getByText(/Milestone reached!/)).toBeInTheDocument();
  act(() => vi.advanceTimersByTime(10000));
  expect(screen.queryByText(/Milestone reached!/)).not.toBeInTheDocument();
  expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '0');
});
it('discards account-switched native responses and never carries old earnings into the next account', async () => {
  const { previewAPI } = await import('../src/renderer/preview');
  const { useInsights } = await import('../src/renderer/features/insights/useInsights');
  let resolve!: (value: unknown) => void;
  const old = new Promise((r) => {
    resolve = r;
  });
  vi.spyOn(previewAPI, 'read')
    .mockImplementationOnce(() => old as Promise<any>)
    .mockResolvedValue({ ...previewInsights('7d'), account_id: 'new-owner' });
  const initial = { linked: true, installation_id: 'runtime', account_revision: 'one' } as Snapshot;
  const { result, rerender } = renderHook(({ state }) => useInsights(state), {
    initialProps: { state: initial },
  });
  rerender({ state: { ...initial, account_revision: 'two' } });
  expect(result.current.data).toBeNull();
  await waitFor(() => expect(result.current.data?.account_id).toBe('new-owner'));
  await act(async () => resolve(previewInsights('7d')));
  expect(result.current.data?.account_id).toBe('new-owner');
  rerender({ state: { ...initial, linked: false } });
  expect(result.current.data).toBeNull();
});
it('opens earnings inside the desktop app and switches the chart and machine breakdown', async () => {
  const App = (await import('../src/renderer/App')).default;
  render(<App />);
  await screen.findByRole('heading', { name: 'Your contribution' });
  fireEvent.click(screen.getByRole('button', { name: 'View earnings' }));
  expect(await screen.findByRole('heading', { name: 'Earnings', level: 1 })).toBeInTheDocument();
  await screen.findByText('Where it comes from');
  fireEvent.click(screen.getByRole('button', { name: '30 days' }));
  await waitFor(() =>
    expect(
      screen.getByRole('group', { name: 'Daily earnings in UTC' }).querySelectorAll('button'),
    ).toHaveLength(30),
  );
  fireEvent.click(screen.getByRole('button', { name: 'Output tokens' }));
  expect(screen.getByRole('group', { name: 'Daily tokens in UTC' })).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'By Mac' }));
  expect(screen.getByText('Mac studio-1')).toBeInTheDocument();
  fireEvent.change(screen.getByRole('combobox', { name: 'Appearance' }), {
    target: { value: 'dark' },
  });
  expect(document.documentElement.dataset.theme).toBe('dark');
  fireEvent.change(screen.getByRole('combobox', { name: 'Appearance' }), {
    target: { value: 'light' },
  });
  expect(document.documentElement.dataset.theme).toBe('light');
});

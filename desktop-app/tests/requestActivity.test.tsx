// @vitest-environment jsdom
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { duration, parseRequestHistory } from '../src/renderer/features/stats/activity/requests';
import type { Resource } from '../src/shared/contracts';

let Stats: typeof import('../src/renderer/features/Stats').Stats;
let previewAPI: typeof import('../src/renderer/preview').previewAPI;
let previewBackend: typeof import('./previewBackend').previewBackend;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  ({ Stats } = await import('../src/renderer/features/Stats'));
  ({ previewAPI } = await import('../src/renderer/preview'));
  ({ previewBackend } = await import('./previewBackend'));
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
const historyReads = (spy: { mock: { calls: unknown[][] } }) =>
  spy.mock.calls.filter(([resource]) => resource === 'request-history').length;
const rows = () => within(screen.getByRole('table')).getAllByRole('row').slice(1);
const column = (index: number) =>
  rows().map((row) => within(row).getAllByRole('cell')[index].textContent);
const privacy = /Prompt and response content is never stored or shown/;

async function openActivity() {
  render(<Stats backend={await previewBackend()} embedded />);
  fireEvent.click(screen.getByRole('tab', { name: 'Activity' }));
}

it('reads request history only when Activity opens and on refresh', async () => {
  const backend = await previewBackend();
  const read = vi.spyOn(previewAPI, 'read');
  render(<Stats backend={backend} embedded />);
  expect(screen.getByRole('tab', { name: 'Performance' })).toHaveAttribute('aria-selected', 'true');
  expect(historyReads(read)).toBe(0);
  fireEvent.click(screen.getByRole('tab', { name: 'Activity' }));
  await screen.findByRole('table');
  expect(historyReads(read)).toBe(1);
  fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));
  await waitFor(() => expect(historyReads(read)).toBe(2));
});

it('lists every serviced request with filters, paging and a privacy note', async () => {
  await openActivity();
  const table = await screen.findByRole('table');
  expect(
    within(table)
      .getAllByRole('columnheader')
      .map((header) => header.textContent),
  ).toEqual([
    'Time',
    'Model',
    'Input tokens',
    'Output tokens',
    'Duration',
    'Tokens/s',
    'Outcome',
    'Earned',
  ]);
  expect(rows()).toHaveLength(25);
  expect(screen.getByText(/^80 requests · .* output tokens · \$0\.\d{4} earned$/)).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Show more' }));
  expect(rows()).toHaveLength(50);
  const model = screen.getByRole('combobox', { name: 'Filter by model' });
  fireEvent.change(model, { target: { value: 'gemma-4-26b' } });
  expect(rows().length).toBeLessThanOrEqual(25);
  expect(new Set(column(1))).toEqual(new Set(['Gemma 4 26B']));
  fireEvent.change(model, { target: { value: 'all' } });
  fireEvent.change(screen.getByRole('combobox', { name: 'Filter by outcome' }), {
    target: { value: 'failed' },
  });
  expect(new Set(column(6))).toEqual(new Set(['Failed']));
  expect(new Set(column(5))).toEqual(new Set(['—']));
  expect(screen.getByText(privacy)).toBeVisible();
});

it('shows an honest unavailable state when the runtime does not serve history', async () => {
  const backend = await previewBackend();
  const read = previewAPI.read;
  const failing = vi
    .spyOn(previewAPI, 'read')
    .mockImplementation(((resource: Resource) =>
      resource === 'request-history'
        ? Promise.reject(new Error('Unknown route'))
        : read(resource)) as typeof previewAPI.read);
  render(<Stats backend={backend} embedded />);
  fireEvent.click(screen.getByRole('tab', { name: 'Activity' }));
  expect(await screen.findByText('Request history is unavailable')).toBeVisible();
  expect(screen.queryByRole('table')).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Show more' })).not.toBeInTheDocument();
  expect(screen.getByText(privacy)).toBeVisible();
  failing.mockRestore();
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  expect(await screen.findByRole('table')).toBeVisible();
});

it('keeps the last observation when a refresh fails', async () => {
  await openActivity();
  await screen.findByRole('table');
  vi.spyOn(previewAPI, 'read').mockRejectedValue(new Error('offline'));
  fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));
  expect(
    await screen.findByText('Couldn’t refresh request history. Showing the last observation.'),
  ).toBeVisible();
  expect(rows()).toHaveLength(25);
});

it('switches Stats views with the keyboard', async () => {
  render(<Stats backend={await previewBackend()} embedded />);
  const performance = screen.getByRole('tab', { name: 'Performance' });
  performance.focus();
  fireEvent.keyDown(performance, { key: 'ArrowRight' });
  const activity = screen.getByRole('tab', { name: 'Activity' });
  expect(activity).toHaveFocus();
  expect(activity).toHaveAttribute('aria-selected', 'true');
  expect(screen.getByRole('tabpanel')).toHaveAttribute('aria-labelledby', activity.id);
  await screen.findByRole('table');
  fireEvent.keyDown(activity, { key: 'ArrowRight' });
  expect(performance).toHaveFocus();
});

it('accepts only well-formed request metadata from the runtime', () => {
  const kept = {
    id: 'a',
    started_at: 10,
    model: 'gpt-oss-20b',
    input_tokens: 5,
    output_tokens: 3,
    duration_ms: 400,
    outcome: 'completed',
  };
  const record = { ...kept, earnings_micro_usd: null, prompt: 'never kept' };
  expect(
    parseRequestHistory({
      observed_at: 20,
      since: null,
      records: [record, { ...record, id: 'b', started_at: 15, earnings_micro_usd: '12' }],
    }),
  ).toEqual({
    observed_at: 20,
    since: undefined,
    records: [{ ...kept, id: 'b', started_at: 15, earnings_micro_usd: '12' }, kept],
  });
  for (const invalid of [
    { outcome: 'timeout' },
    { outcome: 'toString' },
    { output_tokens: -1 },
    { input_tokens: 1.5 },
    { duration_ms: Number.NaN },
    { earnings_micro_usd: 12 },
    { earnings_micro_usd: '-3' },
  ])
    expect(() =>
      parseRequestHistory({ observed_at: 20, records: [{ ...record, ...invalid }] }),
    ).toThrow('Invalid request record');
  expect(() => parseRequestHistory({ records: [] })).toThrow('Invalid request history');
  expect(() => parseRequestHistory(null)).toThrow('Invalid request history');
});

it('formats request durations', () => {
  expect([640, 19_640, 59_960, 72_400].map(duration)).toEqual([
    '640 ms',
    '19.6 s',
    '1m 0s',
    '1m 12s',
  ]);
});

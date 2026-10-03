// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Leaderboard } from '../src/renderer/features/Leaderboard';
import { NetworkMap } from '../src/renderer/features/leaderboard/NetworkMap';
import { annualPace, parseLeaderboard } from '../src/renderer/features/leaderboard/data';
import { regionsFrom } from '../src/renderer/features/leaderboard/geography';
import type { BackendState } from '../src/renderer/useBackend';

afterEach(cleanup);
function backend(): BackendState {
  return {
    status: { state: 'ready' },
    state: undefined,
    cloud: undefined,
    cooling: undefined,
    release: undefined,
    releaseHistory: undefined,
    network: undefined,
    error: '',
    leaderError: '',
    setError: vi.fn(),
    busy: false,
    act: vi.fn(),
    refresh: vi.fn(),
    leaders: Array.from({ length: 12 }, (_, i) => ({
      rank: i + 1,
      name: `provider-${i + 1}`,
      tokens: '5000000',
      earnings_micro_usd: '1000000',
    })),
  };
}
it('keeps ranking details collapsed, paginates, and distinguishes actual earnings from pace', () => {
  render(<Leaderboard backend={backend()} />);
  const summary = screen.getByLabelText('Rank 1, provider-1');
  const details = summary.closest('details')!;
  expect(details).not.toHaveAttribute('open');
  expect(summary).toHaveTextContent('$365/yr');
  expect(details).toHaveTextContent('Earned in 24 hours$1.00');
  expect(screen.queryByLabelText('Rank 11, provider-11')).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Show more providers' }));
  expect(screen.getByLabelText('Rank 12, provider-12')).toBeInTheDocument();
  expect(screen.getByText('24-hour earnings × 365. A pace, not guaranteed income.')).toBeVisible();
});
it('labels stale rankings and does not invent provider results', () => {
  const state = { ...backend(), leaderError: 'Rankings could not refresh.' };
  const { rerender } = render(<Leaderboard backend={state} />);
  expect(screen.getByRole('status')).toHaveTextContent('Showing the last results');
  rerender(<Leaderboard backend={{ ...state, leaders: [] }} />);
  expect(screen.getByText('Leaderboard unavailable')).toBeInTheDocument();
  expect(screen.queryByLabelText('Rank 1, provider-1')).not.toBeInTheDocument();
});
it('keeps missing geography unknown and makes real region counts available by keyboard selection', () => {
  const { rerender } = render(<NetworkMap />);
  expect(screen.getByText('Location data unavailable')).toBeVisible();
  const region = { region: 'Tokyo', country: 'Japan', latitude: 35, longitude: 139, providers: 7 };
  rerender(<NetworkMap network={{ provider_regions: [region] }} />);
  const selector = screen.getByRole('combobox', { name: 'Explore provider regions' });
  const option = screen.getByRole('option', { name: 'Tokyo, Japan: 7 Macs' }) as HTMLOptionElement;
  fireEvent.change(selector, { target: { value: option.value } });
  expect(screen.getByText('7 Macs · Tokyo, Japan')).toBeVisible();
});
it('rejects malformed geographic observations and uses exact integers for annualized pace', () => {
  const region = { region: 'Tokyo', country: 'Japan', latitude: 35, longitude: 139, providers: 7 };
  expect(
    regionsFrom([
      region,
      { ...region, latitude: NaN },
      { ...region, providers: -3 },
      { ...region, longitude: 200 },
    ]),
  ).toHaveLength(1);
  expect(regionsFrom(null)).toEqual([]);
  expect(annualPace('9007199254740993')).toBe('$3,287,627,727,980');
  expect(annualPace(undefined)).toBe('—');
});

it('rejects old all-time rankings rather than annualizing the wrong window', () => {
  const entries = backend().leaders;
  expect(parseLeaderboard({ metric: 'earnings', window: '24h', entries })).toEqual(entries);
  expect(() => parseLeaderboard(entries)).toThrow();
  expect(() => parseLeaderboard({ metric: 'tokens', window: 'all', entries })).toThrow();
  expect(() =>
    parseLeaderboard({ metric: 'earnings', window: '24h', entries: [{ rank: 1 }] }),
  ).toThrow();
});

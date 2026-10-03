// @vitest-environment jsdom
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import stats from './fixtures/public-stats.json';
import type { NetworkData } from '../src/shared/contracts';
import {
  milestoneProgress,
  networkStatus,
  nextMilestone,
} from '../src/renderer/features/home/milestones';
import { NetworkMilestone } from '../src/renderer/features/home/NetworkMilestone';
import { networkFromStats } from '../src/renderer/previewNetwork';

let Home: typeof import('../src/renderer/features/Home').Home;
let previewBackend: typeof import('./previewBackend').previewBackend;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  ({ Home } = await import('../src/renderer/features/Home'));
  ({ previewBackend } = await import('./previewBackend'));
});
afterEach(cleanup);

const strip = () => screen.getByRole('region', { name: 'Collective network progress' });
const cellsOn = () => strip().querySelectorAll('[role=progressbar] i[data-on]').length;

it('climbs the 1, 2.5, 5 ladder past each mark', () => {
  expect(
    [0, 999e9, 2e9, 659_103_744_009, 1e12, 1.2e12, 2.5e12, 7e12, 99e12].map(nextMilestone),
  ).toEqual([1e9, 1e12, 2.5e9, 1e12, 2.5e12, 2.5e12, 5e12, 10e12, 100e12]);
  expect(() => nextMilestone(Number.NaN)).toThrow(RangeError);
});

it('measures progress as the share of the next milestone already processed', () => {
  expect(milestoneProgress(659_103_744_009)).toEqual({ next: 1e12, progress: 0.659103744009 });
  expect(milestoneProgress(1e12)).toEqual({ next: 2.5e12, progress: 0.4 });
  expect(milestoneProgress(0)).toEqual({ next: 1e9, progress: 0 });
});

it('derives freshness from whether totals exist and whether the last refresh failed', () => {
  const live = networkFromStats(stats);
  expect(networkStatus(undefined)).toBe('connecting');
  expect(networkStatus(live)).toBe('live');
  expect(networkStatus({ ...live, error: 'Network statistics are unavailable.' })).toBe('stale');
  expect(networkStatus({ error: 'Network statistics are unavailable.' })).toBe('unavailable');
  expect(networkStatus({ total_tokens: 'many' })).toBe('unavailable');
});

it('shows live production totals, the day’s tokens and the next proposed milestone', () => {
  render(<NetworkMilestone network={networkFromStats(stats)} />);
  const region = strip();
  expect(within(region).getByText('659.1B')).toBeVisible();
  expect(within(region).getByText('tokens processed by the network')).toBeVisible();
  expect(within(region).getByText('+14.6B')).toBeVisible();
  expect(within(region).getByText('1,137')).toBeVisible();
  expect(within(region).getByText('Next milestone 1T')).toBeVisible();
  expect(within(region).getByText('Proposed')).toBeVisible();
  expect(within(region).getByText('Live')).toBeVisible();
  expect(within(region).getByRole('progressbar')).toHaveAttribute('aria-valuenow', '66');
  expect(within(region).getByRole('progressbar')).toHaveAttribute(
    'aria-valuetext',
    '659.1B of a proposed 1T tokens',
  );
  expect(cellsOn()).toBe(16);
});

it('omits the 24-hour cell when the runtime does not relay it', () => {
  const { last_24h_tokens: _, ...network } = networkFromStats(stats);
  render(<NetworkMilestone network={network} />);
  expect(screen.queryByText('Last 24 hours')).not.toBeInTheDocument();
  expect(within(strip()).getByText('Macs connected')).toBeVisible();
});

it('keeps the last known totals while reconnecting', () => {
  const network: NetworkData = {
    ...networkFromStats(stats),
    error: 'Network statistics are unavailable.',
  };
  render(<NetworkMilestone network={network} />);
  expect(within(strip()).getByText('Last known, reconnecting')).toBeVisible();
  expect(within(strip()).getByText('659.1B')).toBeVisible();
  expect(cellsOn()).toBe(16);
});

it('says when statistics are unavailable or still connecting, without inventing numbers', () => {
  const { rerender } = render(<NetworkMilestone network={undefined} />);
  expect(within(strip()).getByText('Connecting')).toBeVisible();
  expect(within(strip()).getByText('Connecting to public network statistics')).toBeVisible();
  rerender(<NetworkMilestone network={{ error: 'Network statistics are unavailable.' }} />);
  expect(within(strip()).getByText('Unavailable')).toBeVisible();
  expect(
    within(strip()).getByText('Statistics unavailable. Retrying automatically.'),
  ).toBeVisible();
  expect(screen.queryByText('Macs connected')).not.toBeInTheDocument();
  expect(within(strip()).getByText('Next milestone')).toBeVisible();
  expect(within(strip()).getByRole('progressbar')).not.toHaveAttribute('aria-valuenow');
  expect(cellsOn()).toBe(0);
});

it('leads Home with the network milestone and drops the duplicated collective block', async () => {
  render(
    <Home
      backend={await previewBackend({ network: networkFromStats(stats) })}
      navigate={vi.fn()}
      openMachine={vi.fn()}
    />,
  );
  const session = screen.getByText('Tokens shared this session');
  expect(strip().compareDocumentPosition(session) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  expect(screen.getByRole('heading', { name: 'Your contribution' })).toBeVisible();
  expect(screen.queryByText('Macs powering the network')).not.toBeInTheDocument();
  expect(screen.queryByText(/tokens shared together/)).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: /Explore Stats/ })).toBeVisible();
});

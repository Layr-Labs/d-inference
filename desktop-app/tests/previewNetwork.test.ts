import { afterEach, expect, it, vi } from 'vitest';
import stats from './fixtures/public-stats.json';
import rankings from './fixtures/public-leaderboard.json';
import {
  leaderboardFromRankings,
  networkFromStats,
  publicOrFixture,
} from '../src/renderer/previewNetwork';

// Trimmed from production responses: /v1/stats on 2026-10-02 and /v1/leaderboard on 2026-09-18.
const fixture = { total_macs: 8 };

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

// The Vite dev server behind the browser preview, with the coordinator replaced by `respond`.
function inDevServer(respond: (input: string, init: RequestInit) => Promise<Response>) {
  vi.stubEnv('DEV', true);
  vi.stubEnv('MODE', 'development');
  const fetch = vi.fn(respond);
  vi.stubGlobal('fetch', fetch);
  return fetch;
}
const reply = (body: unknown, status = 200) =>
  Promise.resolve(new Response(JSON.stringify(body), { status }));

it('shapes production statistics the way the native relay does', () => {
  expect(networkFromStats(stats)).toEqual({
    total_tokens: '659103744009',
    total_requests: '200188251',
    last_24h_tokens: '14592165861',
    total_macs: 1137,
    provider_regions: stats.provider_regions,
  });
  expect(networkFromStats({ ...stats, total_tokens: '659103744009' }).total_tokens).toBe(
    '659103744009',
  );
  const { last_24h_total_tokens: _, ...lifetimeOnly } = stats;
  expect(networkFromStats(lifetimeOnly).last_24h_tokens).toBeUndefined();
});

it('rejects payloads that are not network statistics', () => {
  for (const value of [
    null,
    [],
    'stats',
    {},
    { ...stats, active_providers: -1 },
    { ...stats, active_providers: 1.5 },
    { ...stats, active_providers: '1137' },
    { ...stats, total_tokens: 1e300 },
    { ...stats, total_tokens: '6.6e11' },
    { ...stats, total_requests: undefined },
  ])
    expect(() => networkFromStats(value)).toThrow();
});

it('shapes production rankings into the desktop contract, including an empty ranking', () => {
  expect(leaderboardFromRankings(rankings)).toEqual({
    metric: 'earnings',
    window: '24h',
    entries: [
      { rank: 1, name: 'forest-komodo-7812', tokens: '275964094', earnings_micro_usd: '15645601' },
      { rank: 2, name: 'downy-scorpion-2274', tokens: '159792697', earnings_micro_usd: '10134353' },
      { rank: 3, name: 'pluckier-stoat-9536', tokens: '86487839', earnings_micro_usd: '9699908' },
    ],
  });
  expect(leaderboardFromRankings({ ...rankings, entries: [] }).entries).toEqual([]);
});

it('rejects rankings of another scope or with malformed providers', () => {
  const [entry] = rankings.entries;
  for (const value of [
    null,
    { ...rankings, entries: undefined },
    { ...rankings, window: 'all' },
    { ...rankings, metric: 'tokens' },
    { ...rankings, entries: [null] },
    { ...rankings, entries: [{ ...entry, pseudonym: '' }] },
    { ...rankings, entries: [{ ...entry, rank: 0 }] },
    { ...rankings, entries: [{ ...entry, tokens: -5 }] },
    { ...rankings, entries: [{ ...entry, earnings_micro_usd: 1.5 }] },
  ])
    expect(() => leaderboardFromRankings(value)).toThrow();
});

it('never reaches the network under test', async () => {
  const fetch = vi.fn();
  vi.stubGlobal('fetch', fetch);
  expect(import.meta.env.MODE).toBe('test');
  await expect(publicOrFixture('network', fixture)).resolves.toBe(fixture);
  await expect(publicOrFixture('leaderboard', fixture)).resolves.toBe(fixture);
  expect(fetch).not.toHaveBeenCalled();
});

it('reads public statistics and rankings without credentials in the dev server', async () => {
  const fetch = inDevServer((input) => reply(input === '/v1/stats' ? stats : rankings));
  await expect(publicOrFixture('network', fixture)).resolves.toEqual(networkFromStats(stats));
  await expect(publicOrFixture('leaderboard', fixture)).resolves.toEqual(
    leaderboardFromRankings(rankings),
  );
  await expect(publicOrFixture('state', fixture)).resolves.toBe(fixture);
  expect(fetch.mock.calls.map(([input]) => input)).toEqual([
    '/v1/stats',
    '/v1/leaderboard?metric=earnings&window=24h',
  ]);
  for (const [, init] of fetch.mock.calls)
    expect(init).toMatchObject({ credentials: 'omit', cache: 'no-store' });
});

it.each([
  ['offline', () => Promise.reject(new TypeError('Failed to fetch'))],
  ['failing', () => reply(stats, 503)],
  ['returning a page instead of JSON', () => Promise.resolve(new Response('<html>'))],
  ['returning malformed statistics', () => reply({ ...stats, active_providers: null })],
])('keeps the fixture when the coordinator is %s', async (_, respond) => {
  inDevServer(respond);
  await expect(publicOrFixture('network', fixture)).resolves.toBe(fixture);
});

it('gives up on a stalled coordinator after 12 seconds', async () => {
  vi.useFakeTimers();
  inDevServer(
    (_, init) =>
      new Promise((_, reject) =>
        init.signal!.addEventListener('abort', () => reject(new DOMException('', 'AbortError'))),
      ),
  );
  let settled = false;
  const read = publicOrFixture('network', fixture).finally(() => (settled = true));
  await vi.advanceTimersByTimeAsync(11_999);
  expect(settled).toBe(false);
  await vi.advanceTimersByTimeAsync(1);
  await expect(read).resolves.toBe(fixture);
});

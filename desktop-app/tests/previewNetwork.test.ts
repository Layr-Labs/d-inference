import { afterEach, expect, it, vi } from 'vitest';
import stats from './fixtures/public-stats.json';
import rankings from './fixtures/public-leaderboard.json';
import catalog from './fixtures/public-model-catalog.json';
import capacity from './fixtures/public-model-capacity.json';
import latest from './fixtures/public-release-latest.json';
import {
  historyFromLatest,
  leaderboardFromRankings,
  networkChatModels,
  networkFromStats,
  publicOrFixture,
  readPublic,
  releaseFromLatest,
} from '../src/renderer/previewNetwork';
import { reasoningEfforts } from '../src/shared/chat';

// Trimmed from production responses: /v1/stats on 2026-10-02, /v1/leaderboard on 2026-09-18, and
// /v1/models/catalog?include_aliases=1, /v1/models/capacity and /v1/releases/latest (its changelog
// cut to two paragraphs) on 2026-11-09.
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
  await expect(publicOrFixture('release', fixture)).resolves.toBe(fixture);
  await expect(publicOrFixture('release-history', fixture)).resolves.toBe(fixture);
  await expect(readPublic('/v1/models/catalog?include_aliases=1')).resolves.toBeUndefined();
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

it('shapes the latest release as the native relay does, and its history as that release alone', () => {
  expect(releaseFromLatest(latest)).toEqual({
    version: '0.10.11',
    published_at: '2026-11-09T20:46:47.305512Z',
    notes: latest.changelog,
  });
  expect(historyFromLatest(latest)).toEqual({
    history: [
      {
        version: '0.10.11',
        published_at: '2026-11-09T20:46:47.305512Z',
        notes: latest.changelog,
        active: true,
      },
    ],
  });
  const { created_at: _, changelog: __, ...bare } = latest;
  expect(historyFromLatest(bare).history).toEqual([
    { version: '0.10.11', published_at: '', notes: '', active: true },
  ]);
  for (const value of [null, [], {}, { ...latest, version: '' }, { ...latest, version: 10 }])
    expect(() => releaseFromLatest(value)).toThrow();
});

it('reads the latest release without credentials in the dev server', async () => {
  const fetch = inDevServer(() => reply(latest));
  await expect(publicOrFixture('release', fixture)).resolves.toEqual(releaseFromLatest(latest));
  await expect(publicOrFixture('release-history', fixture)).resolves.toEqual(
    historyFromLatest(latest),
  );
  expect(fetch.mock.calls.map(([input]) => input)).toEqual([
    '/v1/releases/latest',
    '/v1/releases/latest',
  ]);
  for (const [, init] of fetch.mock.calls)
    expect(init).toMatchObject({ credentials: 'omit', cache: 'no-store' });
});

it('lists the network’s models as the coordinator lists them to an account key', () => {
  const reasons = { reasoning: true, reasoning_efforts: [...reasoningEfforts] };
  expect(networkChatModels(catalog, capacity)).toEqual([
    {
      // The alias, by the desired build's limits; its desired, previous and retired builds hide.
      model: {
        id: 'gemma-4-26b',
        name: 'Gemma 4 26B',
        owned_by: 'darkbloom',
        ...reasons,
        context_length: 131_072,
        max_output_length: 32_768,
        input_modalities: ['text', 'image', 'video'],
      },
      builds: ['gemma-4-26b-qat-4bit', 'gemma-4-26b'],
    },
    {
      model: {
        id: 'mimo-v2.6-flash-mopd',
        name: 'Xiaomi: MiMo-V2.6-Flash',
        owned_by: 'darkbloom',
        ...reasons,
        context_length: 1_048_576,
        max_output_length: 131_072,
        input_modalities: ['text'],
      },
      builds: ['mimo-v2.6-flash-mopd'],
    },
    {
      model: {
        id: 'glm-5.3-flash',
        name: 'Z.ai: GLM-5.3-Flash',
        owned_by: 'darkbloom',
        ...reasons,
        context_length: 262_144,
        max_output_length: 65_536,
        input_modalities: ['text', 'image', 'video'],
      },
      builds: ['glm-5.3-flash'],
    },
    {
      // No features listed: whether it reasons is unknown, as the local API's list leaves it.
      model: {
        id: 'gpt-oss-20b',
        name: 'GPT-OSS 20B',
        owned_by: 'darkbloom',
        reasoning: null,
        reasoning_efforts: null,
        context_length: 131_072,
        max_output_length: 32_768,
        input_modalities: ['text'],
      },
      builds: ['gpt-oss-20b'],
    },
  ]);
});

it('lists every active build when the capacity can’t say, and no inactive build or alias', () => {
  const ids = (value: unknown, served?: unknown) =>
    networkChatModels(value, served).map(({ model }) => model.id);
  const everything = [
    'gemma-4-26b',
    'gpt-oss-20b',
    'Qwen3.5-9B',
    'glm-5.3-flash',
    'mimo-v2.6-flash-mopd',
  ];
  expect(ids(catalog)).toEqual(everything);
  expect(ids(catalog, { error: 'unavailable' })).toEqual(everything);
  const qwen = networkChatModels(catalog).find(({ model }) => model.id === 'Qwen3.5-9B')!;
  expect(qwen.model).toMatchObject({
    name: 'Qwen 3.5 9B',
    reasoning: false,
    reasoning_efforts: null,
  });
  const models = catalog.models.map((model) =>
    model.id === 'glm-5.3-flash' ? { ...model, active: false } : model,
  );
  expect(ids({ ...catalog, models })).not.toContain('glm-5.3-flash');
  const [alias] = catalog.aliases;
  // An inactive alias neither lists nor hides its builds.
  expect(ids({ ...catalog, aliases: [{ ...alias, active: false }] }, capacity)).toEqual([
    'gemma-4-26b-qat-4bit',
    'gemma-4-26b-8bit',
    'mimo-v2.6-flash-mopd',
    'glm-5.3-flash',
    'gemma-4-26b',
    'gpt-oss-20b',
  ]);
  // An alias without a build in the catalog isn't listed, and still hides its retired builds.
  const gone = { ...alias, desired_build: 'gone', previous_build: '' };
  expect(ids({ ...catalog, aliases: [gone] }, capacity)).toEqual([
    'gemma-4-26b-qat-4bit',
    'mimo-v2.6-flash-mopd',
    'glm-5.3-flash',
    'gemma-4-26b',
    'gpt-oss-20b',
  ]);
  for (const value of [null, [], {}, { models: 'none' }])
    expect(() => networkChatModels(value)).toThrow();
});

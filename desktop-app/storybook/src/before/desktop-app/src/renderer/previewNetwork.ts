import type { NetworkData, Resource } from '../shared/contracts';
import { parseLeaderboard } from './features/leaderboard/data';

// Development preview only. The network map and rankings show the production coordinator's public
// statistics, shaped as the native runtime relays them (DesktopResources.swift) and read through
// the dev server's same-origin proxy (vite.config.ts). A failed or malformed read keeps the fixture.
const TIMEOUT_MS = 12_000; // outlasts the coordinator's 10-second rankings query

const count = (value: unknown) =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
// Counts are JSON numbers upstream and decimal strings in the desktop contract.
const integerText = (value: unknown) =>
  typeof value === 'string' && /^\d+$/.test(value) ? value : count(value)?.toString();

function object(value: unknown) {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new Error('Expected a JSON object');
  return value as Record<string, unknown>;
}

export function networkFromStats(value: unknown): NetworkData {
  const stats = object(value);
  const network = {
    total_tokens: integerText(stats.total_tokens),
    total_requests: integerText(stats.total_requests),
    last_24h_tokens: integerText(stats.last_24h_total_tokens),
    total_macs: count(stats.active_providers),
    provider_regions: stats.provider_regions,
  };
  if (!network.total_tokens || !network.total_requests || network.total_macs === undefined)
    throw new Error('Invalid network statistics');
  return network;
}

export function leaderboardFromRankings(value: unknown) {
  const rankings = object(value);
  if (!Array.isArray(rankings.entries)) throw new Error('Missing rankings');
  const leaderboard = {
    metric: rankings.metric,
    window: rankings.window,
    entries: rankings.entries.map((entry: unknown) => {
      const row = object(entry);
      return {
        rank: row.rank,
        name: row.pseudonym,
        tokens: integerText(row.tokens),
        earnings_micro_usd: integerText(row.earnings_micro_usd),
      };
    }),
  };
  parseLeaderboard(leaderboard);
  return leaderboard;
}

const sources: Partial<Record<Resource, { path: string; shape: (value: unknown) => unknown }>> = {
  network: { path: '/v1/stats', shape: networkFromStats },
  leaderboard: {
    path: '/v1/leaderboard?metric=earnings&window=24h',
    shape: leaderboardFromRankings,
  },
};

// Vitest runs in mode "test", so tests never reach production.
const live = () => import.meta.env.DEV && import.meta.env.MODE !== 'test';

export async function publicOrFixture(resource: Resource, fixture: unknown): Promise<unknown> {
  const source = sources[resource];
  if (!source || !live()) return fixture;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(source.path, {
      credentials: 'omit',
      cache: 'no-store',
      signal: controller.signal,
    });
    if (response.status !== 200) return fixture;
    return source.shape(await response.json());
  } catch {
    return fixture;
  } finally {
    clearTimeout(timer);
  }
}

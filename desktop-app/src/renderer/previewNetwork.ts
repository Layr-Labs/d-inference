import { reasoningEfforts, type ChatModel } from '../shared/chat';
import type { NetworkData, ReleaseData, ReleaseHistory, Resource } from '../shared/contracts';
import { parseLeaderboard } from './features/leaderboard/data';

// Development preview only. The network map, the rankings and the latest release show the
// production coordinator's public data, shaped as the native runtime relays them
// (DesktopResources.swift), and Chat lists the network's models from its public catalog. All of
// it is read keyless through the dev server's same-origin proxy (vite.config.ts). A failed or
// malformed read keeps the fixture.
const TIMEOUT_MS = 12_000; // outlasts the coordinator's 10-second rankings query

const count = (value: unknown) =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
// Counts are JSON numbers upstream and decimal strings in the desktop contract.
const integerText = (value: unknown) =>
  typeof value === 'string' && /^\d+$/.test(value) ? value : count(value)?.toString();
const text = (value: unknown) => (typeof value === 'string' && value.trim() ? value : undefined);
const strings = (value: unknown) =>
  Array.isArray(value)
    ? value.filter((item): item is string => typeof item === 'string')
    : undefined;
const positive = (value: unknown) =>
  typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : null;
const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === 'object' && !Array.isArray(value);

function object(value: unknown) {
  if (!isRecord(value)) throw new Error('Expected a JSON object');
  return value;
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

// `/v1/releases/latest` as the runtime relays it: the version, when it was published and its
// changelog.
export function releaseFromLatest(value: unknown): ReleaseData {
  const latest = object(value);
  const version = text(latest.version);
  if (!version) throw new Error('Missing release version');
  return { version, published_at: text(latest.created_at), notes: text(latest.changelog) };
}

// The runtime's release history: the latest release alone, active. The coordinator's minimum
// version comes with the account's data (`cloud`), never here.
export function historyFromLatest(value: unknown): ReleaseHistory {
  const release = releaseFromLatest(value);
  return {
    history: [
      {
        version: release.version!,
        published_at: release.published_at ?? '',
        notes: release.notes ?? '',
        active: true,
      },
    ],
  };
}

// A model the network lists, with the builds it stands for: an alias its desired, primary and
// previous builds, a build itself. The local API leaves out an alias of a build this Mac serves.
export interface NetworkChatModel {
  model: ChatModel;
  builds: string[];
}

// One catalog build under `id`, as the app reads the local API's list (parseModelList in
// main/chat.ts): `supported_features` says whether it reasons, and one that reasons takes every
// effort.
function networkModel(id: string, name: string | undefined, build: Record<string, unknown>) {
  const features = strings(build.supported_features);
  const reasoning = features
    ? features.some((feature) => feature.toLowerCase() === 'reasoning')
    : null;
  return {
    id,
    name: name && name !== id ? name : null,
    owned_by: 'darkbloom',
    reasoning,
    reasoning_efforts: reasoning ? [...reasoningEfforts] : null,
    context_length: positive(build.max_context_length),
    max_output_length: positive(build.max_output_length),
    input_modalities: strings(build.input_modalities) ?? null,
  } satisfies ChatModel;
}

// The builds Macs serve now (`/v1/models/capacity`), in its order; undefined when it can't say.
function servedBuilds(value: unknown) {
  const models = isRecord(value) ? value.models : undefined;
  if (!Array.isArray(models)) return undefined;
  return models.flatMap((entry) => {
    const id = isRecord(entry) ? text(entry.id) : undefined;
    return id ? [id] : [];
  });
}

// The network's models as the coordinator lists them to an account key (`GET /v1/models`, which
// needs one), from the keyless `/v1/models/catalog?include_aliases=1` and `/v1/models/capacity`:
// each active public alias under its own id and name, then each build Macs serve now (every
// active build without the capacity), leaving out every build an alias covers: its desired,
// previous and retired builds (the coordinator's models_endpoints.go and alias_projection.go).
export function networkChatModels(catalogValue: unknown, capacity?: unknown): NetworkChatModel[] {
  const catalog = object(catalogValue);
  if (!Array.isArray(catalog.models)) throw new Error('Missing catalog models');
  const builds = new Map<string, Record<string, unknown>>();
  for (const build of catalog.models) {
    const id = isRecord(build) ? text(build.id) : undefined;
    if (id && isRecord(build) && build.active !== false) builds.set(id, build);
  }
  const listed: NetworkChatModel[] = [];
  const hidden = new Set<string>();
  for (const alias of Array.isArray(catalog.aliases) ? catalog.aliases : []) {
    if (!isRecord(alias) || alias.active === false || alias.openrouter_only === true) continue;
    const id = text(alias.id);
    const desired = text(alias.desired_build);
    const previous = text(alias.previous_build);
    if (!id || !desired) continue;
    for (const build of [desired, previous, ...(strings(alias.retired_builds) ?? [])])
      if (build && builds.has(build)) hidden.add(build);
    const primary = [desired, previous].find((build) => build && builds.has(build));
    if (!primary) continue;
    const build = builds.get(primary)!;
    listed.push({
      model: networkModel(id, text(alias.display_name) ?? text(build.display_name), build),
      builds: [
        ...new Set([desired, text(alias.primary_build), previous].filter((b) => b !== undefined)),
      ],
    });
  }
  const seen = new Set(listed.map(({ model }) => model.id));
  for (const id of servedBuilds(capacity) ?? builds.keys()) {
    const build = builds.get(id);
    if (!build || hidden.has(id) || seen.has(id)) continue;
    seen.add(id);
    listed.push({
      model: networkModel(id, text(build.display_name) ?? text(build.name), build),
      builds: [id],
    });
  }
  return listed;
}

const sources: Partial<Record<Resource, { path: string; shape: (value: unknown) => unknown }>> = {
  network: { path: '/v1/stats', shape: networkFromStats },
  leaderboard: {
    path: '/v1/leaderboard?metric=earnings&window=24h',
    shape: leaderboardFromRankings,
  },
  release: { path: '/v1/releases/latest', shape: releaseFromLatest },
  'release-history': { path: '/v1/releases/latest', shape: historyFromLatest },
};

// Vitest runs in mode "test", so tests never reach production.
const live = () => import.meta.env.DEV && import.meta.env.MODE !== 'test';

// One public read through the dev server's proxy: its JSON, or undefined outside the dev server,
// on a failed read or past the timeout.
export async function readPublic(path: string): Promise<unknown> {
  if (!live()) return undefined;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(path, {
      credentials: 'omit',
      cache: 'no-store',
      signal: controller.signal,
    });
    return response.status === 200 ? await response.json() : undefined;
  } catch {
    return undefined;
  } finally {
    clearTimeout(timer);
  }
}

export async function publicOrFixture(resource: Resource, fixture: unknown): Promise<unknown> {
  const source = sources[resource];
  if (!source) return fixture;
  const value = await readPublic(source.path);
  if (value === undefined) return fixture;
  try {
    return source.shape(value);
  } catch {
    return fixture;
  }
}

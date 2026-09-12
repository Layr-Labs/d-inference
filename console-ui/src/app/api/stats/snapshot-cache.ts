const SNAPSHOT_TTL_MS = 30_000;
const UPSTREAM_TIMEOUT_MS = 20_000;
const SOURCE_TIMESTAMP_FORMAT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+|)(?:Z|[+-]\d{2}:\d{2})$/;

type StatsSnapshot = {
  data: unknown;
  fetchedAt: number;
  snapshotAt: number | null;
  expiresAt: number;
};

type CacheEntry = {
  snapshot?: StatsSnapshot;
  pending?: Promise<StatsSnapshot>;
};

// Shared by requests handled by this server instance, including in local dev.
// The configured coordinator is the key so different environments cannot reuse
// one another's data. Mock geography never passes through this cache.
const snapshots = new Map<string, CacheEntry>();

export class StatsUpstreamError extends Error {
  constructor(public readonly status: number) {
    super(`Upstream ${status}`);
  }
}

async function fetchSnapshot(coordinator: string): Promise<StatsSnapshot> {
  // Anchor freshness before the request so upstream latency consumes the TTL.
  const fetchedAt = Date.now();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
  try {
    const response = await fetch(`${coordinator}/v1/stats`, { cache: "no-store", signal: controller.signal });
    if (!response.ok) throw new StatsUpstreamError(response.status);
    const data: unknown = await response.json();
    const sourceTime = data && typeof data === "object" && "snapshot_at" in data ? data.snapshot_at : null;
    const parsedTime = typeof sourceTime === "string" && SOURCE_TIMESTAMP_FORMAT.test(sourceTime) ? Date.parse(sourceTime) : Number.NaN;
    const snapshotAt = Number.isFinite(parsedTime) ? parsedTime : null;
    const expiresAt = snapshotAt === null
      ? fetchedAt + SNAPSHOT_TTL_MS
      : Math.min(fetchedAt + SNAPSHOT_TTL_MS, snapshotAt + SNAPSHOT_TTL_MS);
    return { data, fetchedAt, snapshotAt, expiresAt };
  } catch (error) {
    if (controller.signal.aborted) throw new StatsUpstreamError(504);
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

export async function getStatsSnapshot(coordinator: string) {
  const existing = snapshots.get(coordinator);
  if (existing?.snapshot && Date.now() < existing.snapshot.expiresAt) {
    return { snapshot: existing.snapshot, cache: "HIT" } as const;
  }
  if (existing?.pending) {
    return { snapshot: await existing.pending, cache: "HIT" } as const;
  }

  const entry: CacheEntry = {};
  snapshots.set(coordinator, entry);
  entry.pending = fetchSnapshot(coordinator);
  try {
    entry.snapshot = await entry.pending;
    return { snapshot: entry.snapshot, cache: "MISS" } as const;
  } catch (error) {
    // Do not cache failures or relabel an expired snapshot as fresh on error.
    snapshots.delete(coordinator);
    throw error;
  } finally {
    entry.pending = undefined;
  }
}

export function statsSnapshotHeaders(snapshot: StatsSnapshot, cache: "HIT" | "MISS") {
  const remainingSeconds = Math.max(0, Math.floor((snapshot.expiresAt - Date.now()) / 1_000));
  return {
    // An edge receives only the remaining lifetime, never a new 30-second TTL.
    // Browsers revalidate through this route; stale snapshots are not extended.
    "Cache-Control": `public, max-age=0, s-maxage=${remainingSeconds}, must-revalidate`,
    "X-Stats-Fetched-At": new Date(snapshot.fetchedAt).toISOString(),
    ...(snapshot.snapshotAt === null ? {} : { "X-Stats-Snapshot-At": new Date(snapshot.snapshotAt).toISOString() }),
    "X-Stats-Expires-At": new Date(snapshot.expiresAt).toISOString(),
    "X-Stats-Cache": cache,
  };
}

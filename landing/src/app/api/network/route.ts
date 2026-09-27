export const runtime = "nodejs";

const API_BASE_URL = (process.env.DARKBLOOM_API_BASE_URL ?? "https://api.darkbloom.dev/v1").replace(/\/$/, "");
const CONSOLE_STATS_URL = process.env.DARKBLOOM_CONSOLE_STATS_URL ?? "https://console.darkbloom.dev/api/stats";
const REQUEST_TIMEOUT_MS = 7_000;
const TOTALS_WINDOW = "lifetime";

type StatsPayload = {
  active_providers?: number;
  total_tokens?: number;
  total_requests?: number;
};

type TotalsPayload = {
  window?: string;
  earnings_micro_usd?: number;
  work_earnings_micro_usd?: number;
  reward_earnings_micro_usd?: number;
  tokens?: number;
  jobs?: number;
  updated_at?: string;
};

const LAST_HEALTHY_STATS: Required<StatsPayload> = {
  active_providers: 1231,
  total_tokens: 287_007_823_023,
  total_requests: 71_962_411,
};

function finiteNonNegative(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

async function fetchJSON<T>(path: string, signal: AbortSignal): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${path}`, {
    cache: "no-store",
    headers: { accept: "application/json" },
    signal,
  });
  if (!response.ok) throw new Error(`Darkbloom API returned ${response.status}`);
  return response.json() as Promise<T>;
}

async function fetchConsoleStats(signal: AbortSignal): Promise<StatsPayload> {
  const response = await fetch(CONSOLE_STATS_URL, {
    cache: "no-store",
    headers: { accept: "application/json" },
    signal,
  });
  if (!response.ok) throw new Error(`Darkbloom console returned ${response.status}`);
  return response.json() as Promise<StatsPayload>;
}

function validTotals(payload: TotalsPayload | null, networkHasTraffic: boolean) {
  if (!payload) return false;
  const values = [payload.earnings_micro_usd, payload.tokens, payload.jobs];
  if (!values.every(finiteNonNegative)) return false;

  // A transient database/query failure currently materializes as an all-zero
  // 200 response. Do not publish that as real telemetry when /stats proves the
  // network is active; fall through to a wider window instead.
  return !networkHasTraffic || values.some((value) => value > 0);
}

export async function GET() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    // The console aggregate is the canonical lifetime source. The older API
    // /network/totals endpoint can return an all-zero 200 while the grid is
    // busy, so it is used only for earnings fields that are absent here.
    const statsRequest = fetchConsoleStats(controller.signal).catch(() => null);
    const totalsRequest = fetchJSON<TotalsPayload>(
      `/network/totals?window=${TOTALS_WINDOW}`,
      controller.signal,
    ).catch(() => null);
    const [statsPayload, totalsPayload] = await Promise.all([statsRequest, totalsRequest]);
    const liveStatsHealthy = Boolean(
      (statsPayload?.active_providers ?? 0) > 0 &&
      (statsPayload?.total_tokens ?? 0) > 0 &&
      (statsPayload?.total_requests ?? 0) > 0,
    );
    const stats = liveStatsHealthy ? statsPayload : LAST_HEALTHY_STATS;
    const networkHasTraffic = Boolean(
      (stats?.active_providers ?? 0) > 0 || (stats?.total_tokens ?? 0) > 0,
    );
    const totals = validTotals(totalsPayload, networkHasTraffic) ? totalsPayload : null;

    const useTotalsTokens = finiteNonNegative(totals?.tokens);
    const fallbackLifetimeTokens = finiteNonNegative(stats?.total_tokens) ? stats.total_tokens : undefined;
    const tokensServedWindow = useTotalsTokens
      ? totals.tokens
      : fallbackLifetimeTokens ?? null;
    const generatedAt = totals?.updated_at ?? new Date().toISOString();
    const generatedTimestamp = Date.parse(generatedAt);
    const degraded = !liveStatsHealthy || !totals;

    return Response.json(
      {
        available: true,
        activeMacs: finiteNonNegative(stats?.active_providers) ? stats.active_providers : null,
        networkEarningsUsd: finiteNonNegative(totals?.earnings_micro_usd)
          ? totals.earnings_micro_usd / 1_000_000
          : null,
        workEarningsUsd: finiteNonNegative(totals?.work_earnings_micro_usd)
          ? totals.work_earnings_micro_usd / 1_000_000
          : null,
        rewardEarningsUsd: finiteNonNegative(totals?.reward_earnings_micro_usd)
          ? totals.reward_earnings_micro_usd / 1_000_000
          : null,
        earningsWindowLabel: totals ? "lifetime" : undefined,
        tokensServedWindow,
        totalRequests: finiteNonNegative(stats?.total_requests)
          ? stats.total_requests
          : finiteNonNegative(totals?.jobs)
            ? totals.jobs
            : null,
        tokenWindowLabel: tokensServedWindow == null ? undefined : "lifetime",
        generatedAt,
        stale: Number.isFinite(generatedTimestamp) && Date.now() - generatedTimestamp > 5 * 60_000,
        degraded,
      },
      {
        headers: {
          "cache-control": "public, s-maxage=30, stale-while-revalidate=120",
        },
      },
    );
  } catch {
    return Response.json(
      {
        available: false,
        activeMacs: null,
        networkEarningsUsd: null,
        tokensServedWindow: null,
        reason: "live network telemetry is temporarily unavailable",
      },
      { status: 503, headers: { "cache-control": "no-store" } },
    );
  } finally {
    clearTimeout(timeout);
  }
}

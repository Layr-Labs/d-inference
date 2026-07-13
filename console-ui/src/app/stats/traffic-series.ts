import type { TimeSeriesBucket, TrafficRange } from "./types";

export interface TrafficRangeConfig {
  value: TrafficRange;
  label: string;
  description: string;
  bucketSeconds: number;
  bucketCount: number;
  bucketLabel: string;
  rateControlLabel: string;
}

const THIRTY_MINUTES: TrafficRangeConfig = {
  value: "30m",
  label: "30m",
  description: "Last 30 completed minutes",
  bucketSeconds: 60,
  bucketCount: 30,
  bucketLabel: "minute",
  rateControlLabel: "Per minute",
};
const TWENTY_FOUR_HOURS: TrafficRangeConfig = {
  value: "24h",
  label: "24h",
  description: "Last 24 completed hours",
  bucketSeconds: 30 * 60,
  bucketCount: 48,
  bucketLabel: "30 min",
  rateControlLabel: "Per 30 min",
};
const SEVEN_DAYS: TrafficRangeConfig = {
  value: "7d",
  label: "7d",
  description: "Last 7 completed days",
  bucketSeconds: 4 * 60 * 60,
  bucketCount: 42,
  bucketLabel: "4 hours",
  rateControlLabel: "Per 4 hours",
};
const THIRTY_DAYS: TrafficRangeConfig = {
  value: "30d",
  label: "30d",
  description: "Last 30 completed days",
  bucketSeconds: 12 * 60 * 60,
  bucketCount: 60,
  bucketLabel: "12 hours",
  rateControlLabel: "Per 12 hours",
};

export const TRAFFIC_RANGES: TrafficRangeConfig[] = [
  THIRTY_MINUTES,
  TWENTY_FOUR_HOURS,
  SEVEN_DAYS,
  THIRTY_DAYS,
];

export function trafficRangeConfig(value: TrafficRange): TrafficRangeConfig {
  switch (value) {
    case "24h":
      return TWENTY_FOUR_HOURS;
    case "7d":
      return SEVEN_DAYS;
    case "30d":
      return THIRTY_DAYS;
    default:
      return THIRTY_MINUTES;
  }
}

function bucketStart(date: Date, bucketMilliseconds: number): Date {
  return new Date(Math.floor(date.getTime() / bucketMilliseconds) * bucketMilliseconds);
}

export function normalizeTrafficSeries(
  data: TimeSeriesBucket[],
  config: TrafficRangeConfig,
  endAt?: string,
): TimeSeriesBucket[] {
  const bucketMilliseconds = config.bucketSeconds * 1000;
  const byBucket = new Map<string, TimeSeriesBucket>();
  for (const bucket of data) {
    const parsed = new Date(bucket.timestamp);
    if (Number.isNaN(parsed.getTime())) continue;
    const key = bucketStart(parsed, bucketMilliseconds).toISOString();
    const existing = byBucket.get(key);
    byBucket.set(key, {
      timestamp: key,
      requests: (existing?.requests ?? 0) + bucket.requests,
      prompt_tokens: (existing?.prompt_tokens ?? 0) + bucket.prompt_tokens,
      completion_tokens: (existing?.completion_tokens ?? 0) + bucket.completion_tokens,
      active_providers: Math.max(existing?.active_providers ?? 0, bucket.active_providers ?? 0),
    });
  }

  const parsedEnd = endAt ? new Date(endAt) : new Date();
  const end = Number.isNaN(parsedEnd.getTime())
    ? bucketStart(new Date(), bucketMilliseconds)
    : bucketStart(parsedEnd, bucketMilliseconds);

  return Array.from({ length: config.bucketCount }, (_, index) => {
    const date = new Date(
      end.getTime() - (config.bucketCount - index) * bucketMilliseconds,
    );
    const key = date.toISOString();
    return byBucket.get(key) ?? {
      timestamp: key,
      requests: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      active_providers: 0,
    };
  });
}

export function formatTrafficTimestamp(timestamp: string, range: TrafficRange): string {
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return "—";
  if (range === "30m") {
    return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  }
  if (range === "24h") {
    return date.toLocaleString([], {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    });
  }
  return date.toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "numeric",
  });
}

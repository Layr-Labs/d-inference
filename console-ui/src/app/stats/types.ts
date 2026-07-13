export interface TimeSeriesBucket {
  timestamp: string;
  requests: number;
  prompt_tokens: number;
  completion_tokens: number;
  active_providers: number;
}

export interface NetworkWindowTotals {
  window: string;
  tokens: number;
  jobs: number;
  updated_at: string;
}

export type TrafficRange = "30m" | "24h" | "7d" | "30d";

export interface NetworkSeriesResponse {
  window: TrafficRange;
  bucket_seconds: number;
  start_at: string;
  end_at: string;
  time_series: TimeSeriesBucket[];
  updated_at: string;
}

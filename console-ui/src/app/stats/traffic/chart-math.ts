import type { TimeSeriesBucket } from "../types";

export type TrafficMetric = "requests" | "tokens";
export type TrafficView = "rate" | "cumulative";
// Normalized data coordinates. Axis labels and gutters are sized in CSS pixels.
export const PLOT = { width: 960, height: 200 };

export function plotValues(data: TimeSeriesBucket[], metric: TrafficMetric, view: TrafficView) {
  let input = 0;
  let output = 0;
  let requests = 0;
  return data.map((bucket) => {
    input = (view === "cumulative" ? input : 0) + Math.max(0, bucket.prompt_tokens);
    output = (view === "cumulative" ? output : 0) + Math.max(0, bucket.completion_tokens);
    requests = (view === "cumulative" ? requests : 0) + Math.max(0, bucket.requests);
    return { timestamp: bucket.timestamp, value: metric === "requests" ? requests : input + output, input, output };
  });
}

export function plotScale(values: number[]) {
  const peak = Math.max(...values, 1);
  const power = 10 ** Math.floor(Math.log10(peak));
  return Math.ceil(peak / power) * power;
}

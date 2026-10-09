import { bucketLabel } from "./history";
import type { ModelDemand } from "./types";

export function DemandIntervalTable({ model, bucketSeconds }: { model: ModelDemand; bucketSeconds: number }) {
  return <details className="mt-4 text-xs text-text-secondary">
    <summary className="min-h-8 cursor-pointer font-medium">View published interval data</summary>
    <div className="max-h-80 overflow-auto rounded-lg border border-border-dim">
      <table className="w-full min-w-[900px] text-left tabular-nums">
        <caption className="sr-only">{model.model} published request outcomes by interval</caption>
        <thead className="sticky top-0 bg-bg-secondary"><tr>{["Interval (local time)", "Published requests", "Completed", "Capacity", "Latency limited", "Timeouts", "Service errors", "Departed", "Unknown", "HTTP 429"].map(label => <th key={label} className="whitespace-nowrap px-3 py-3 font-medium">{label}</th>)}</tr></thead>
        <tbody>{model.time_series.map(bucket => <tr key={bucket.timestamp} className="border-t border-border-dim">
          <th scope="row" className="px-3 py-3 font-normal">{bucketLabel(bucket.timestamp, bucketSeconds)}</th>
          {bucket.counts ? [bucket.counts.requests, bucket.counts.completed, bucket.counts.capacity_rejected, bucket.counts.latency_rejected, bucket.counts.timed_out, bucket.counts.failed, bucket.counts.cancelled, bucket.counts.unknown, bucket.counts.http_429].map((value, index) => <td key={index} className="px-3 py-3">{value.toLocaleString()}</td>) : <td colSpan={9} className="px-3 py-3 text-text-tertiary">Not published</td>}
        </tr>)}</tbody>
      </table>
    </div>
  </details>;
}

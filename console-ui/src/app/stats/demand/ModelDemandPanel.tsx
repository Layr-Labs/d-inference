"use client";

import { useState } from "react";
import type { CatalogDataSummary } from "@/lib/stats-model-filter";
import type { DemandMetric } from "./history";
import { DemandHistory } from "./DemandHistory";
import { DEMAND_COLUMNS, DemandRow } from "./DemandRow";
import { useModelDemand } from "./useModelDemand";
import type { DemandWindow } from "./types";

const WINDOWS: [DemandWindow, string][] = [["24h", "24 hours"], ["7d", "7 days"], ["30d", "30 days"]];
const date = (value: string) => new Date(value).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" });

export function ModelDemandPanel({ refreshToken, catalogData }: { refreshToken: string | null; catalogData: CatalogDataSummary | null }) {
  const [window, setWindow] = useState<DemandWindow>("24h");
  const [historyModel, setHistoryModel] = useState("");
  const [historyMetric, setHistoryMetric] = useState<DemandMetric>("requests");
  const [sort, setSort] = useState("requests");
  const [selected, setSelected] = useState<string | null>(null);
  const { data, loading, error, retry } = useModelDemand(window, refreshToken);
  const models = [...(data?.models ?? [])].sort((a, b) => (sort === "capacity" ? b.capacity_rejected - a.capacity_rejected : b.requests - a.requests) || a.model.localeCompare(b.model));
  const maximum = Math.max(1, ...models.map(m => m.requests));
  const names = new Map([
    ...(catalogData?.models.map(m => [m.id, m.displayName || m.name || m.id] as const) ?? []),
    ...(catalogData?.aliases.map(m => [m.id, m.displayName || m.id] as const) ?? []),
  ]);
  let content;
  if (loading) content = <p role="status" className="py-12 text-sm text-text-secondary">Loading model demand…</p>;
  else if (error || !data) content = <div role="alert" className="py-10 text-sm text-text-secondary"><p>Model demand couldn’t be loaded.</p><button type="button" onClick={retry} className="mt-3 min-h-10 text-accent-brand">Retry model demand</button></div>;
  else content = <>
          <p className="mt-4 text-xs leading-5 text-text-tertiary">{date(data.start_at)} – {date(data.end_at)}. Data is delayed by at least one hour.</p>
          <p className="mt-2 text-xs leading-5 text-text-tertiary">Recording is best-effort. Percentages describe recorded requests, not guaranteed network-wide coverage.</p>
          {Date.parse(data.collection_started_at) > Date.parse(data.start_at) && <p role="status" className="mt-3 text-xs leading-5 text-text-secondary">Collection began {date(data.collection_started_at)}. This window has only partial history.</p>}
          <DemandHistory data={data} names={names} modelId={historyModel} onModelChange={setHistoryModel} metric={historyMetric} onMetricChange={setHistoryMetric} />
          <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-3 text-xs text-text-tertiary">
            <span className="inline-flex items-center gap-2"><span aria-hidden="true" className="h-2 w-5 rounded-sm bg-accent-brand" />Completed</span>
            <span className="inline-flex items-center gap-2"><span aria-hidden="true" className="h-2 w-5 rounded-sm bg-accent-amber" />Capacity rejected</span>
            <span className="inline-flex items-center gap-2"><span aria-hidden="true" className="h-2 w-5 rounded-sm bg-text-tertiary/40" />Other outcomes</span>
            <label className="flex items-center gap-2 sm:ml-auto">Sort by<select aria-label="Sort model demand" value={sort} onChange={event => setSort(event.target.value)} className="min-h-10 rounded-lg border border-border-dim bg-bg-white px-3 text-text-secondary"><option value="requests">Requests received</option><option value="capacity">Capacity rejections</option></select></label>
          </div>
          {models.length ? <>
            <div className={`mt-6 hidden items-end gap-5 text-xs text-text-tertiary lg:grid ${DEMAND_COLUMNS}`} aria-hidden="true"><span>Model</span><span>Recorded requests · shared scale</span><span className="text-right">Completed</span><span className="text-right">Capacity rejected</span><span className="text-right">Other</span><span /></div>
            <div className="mt-3 border-t border-border-dim">{models.map(model => <DemandRow key={model.model} model={model} name={names.get(model.model) || model.model} maximum={maximum} expanded={selected === model.model} onToggle={() => setSelected(v => v === model.model ? null : model.model)} />)}</div>
          </> : <p className="mt-5 border-y border-border-dim py-10 text-sm text-text-secondary">No publishable model demand for this window yet. Low-volume cohorts are hidden for privacy; this does not mean no requests were received.</p>}
          <details className="mt-5 text-xs leading-5 text-text-tertiary">
            <summary className="min-h-8 cursor-pointer font-medium text-text-secondary">How these numbers are counted</summary>
            <p className="mt-2 max-w-4xl">Counts and percentages cover recorded public requests that reached routing admission after account and request checks. Each incoming HTTP request counts once; internal retries do not add requests. Client retries count separately. Private, owner-preferred, and machine-restricted requests are excluded, along with validation and account-limit rejections. Admin-key traffic is excluded. Authenticated load tests using ordinary public keys cannot be distinguished from other traffic.</p>
            <p className="mt-2 max-w-4xl">Recording is best-effort: missing observations are not estimated, and these percentages are not a guaranteed network-wide success rate. Models need at least 20 recorded requests from 3 consumer accounts in the selected window to appear. A gateway can represent many users under one account. No suppressed totals or account identifiers are published.</p>
            <p className="mt-2 max-w-4xl">Completed means the coordinator observed provider completion and successfully wrote a completed response. It does not prove receipt by the client. Capacity rejections include unavailable eligible providers and coordinator saturation; more machines may not resolve every rejection. Token demand is not included until served counts and rejected-request estimates can be reconciled.</p>
          </details>
        </>;
  return (
    <section aria-labelledby="model-demand-title" className="min-w-0 border-t border-border-dim pt-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div><h2 id="model-demand-title" className="text-xl font-semibold tracking-tight text-text-primary">Model demand &amp; fulfillment</h2><p className="mt-2 text-sm leading-6 text-text-tertiary">Which models receive requests, and how often the network completes them.</p></div>
        <div role="group" aria-label="Model demand time range" className="flex rounded-lg bg-bg-secondary p-1">
          {WINDOWS.map(([value, label]) => <button key={value} type="button" aria-pressed={window === value} onClick={() => { setWindow(value); setSelected(null); }} className={`min-h-10 rounded-md px-3 text-xs ${window === value ? "bg-bg-white font-medium text-text-primary shadow-sm" : "text-text-secondary hover:text-text-primary"}`}>{label}</button>)}
        </div>
      </div>
      {content}
    </section>
  );
}

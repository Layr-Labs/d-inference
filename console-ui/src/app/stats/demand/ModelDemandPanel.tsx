"use client";

import { useState } from "react";
import type { CatalogDataSummary } from "@/lib/stats-model-filter";
import type { DemandMetric } from "./history";
import { DemandHistory } from "./DemandHistory";
import { DemandRow } from "./DemandRow";
import { DemandSummary } from "./DemandSummary";
import { DemandMethodology } from "./DemandMethodology";
import { useModelDemand } from "./useModelDemand";
import type { DemandWindow } from "./types";
import styles from "./demand.module.css";

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
  const total = models.reduce((sum, model) => sum + model.requests, 0);
  const names = new Map([
    ...(catalogData?.models.map(m => [m.id, m.displayName || m.name || m.id] as const) ?? []),
    ...(catalogData?.aliases.map(m => [m.id, m.displayName || m.id] as const) ?? []),
  ]);
  let content;
  if (loading) content = <p role="status" className="py-12 text-sm text-text-secondary">Loading model demand…</p>;
  else if (error || !data) content = <div role="alert" className="py-10 text-sm text-text-secondary"><p>Model demand couldn’t be loaded.</p><button type="button" onClick={retry} className="mt-3 min-h-10 text-accent-brand">Retry model demand</button></div>;
  else content = <>
    <p className="mt-4 text-xs leading-5 text-text-tertiary">{date(data.start_at)} – {date(data.end_at)} · At least one hour delayed.</p>
    <p className="mt-1 text-xs leading-5 text-text-tertiary">Counts and shares cover published observations only. Recording is best-effort; private traffic and low-volume hours are excluded.</p>
    {Date.parse(data.collection_started_at) > Date.parse(data.start_at) && <p role="status" className="mt-3 text-xs leading-5 text-text-secondary">Collection began {date(data.collection_started_at)}. This window has only partial history.</p>}
    <DemandSummary models={models} names={names} />
    <DemandHistory data={data} names={names} modelId={historyModel} onModelChange={setHistoryModel} metric={historyMetric} onMetricChange={setHistoryMetric} />
    {models.length ? <>
      <div className="mb-4 mt-8 flex flex-wrap items-center justify-between gap-3">
        <div><h3 className="text-sm font-medium text-text-primary">Traffic share and outcomes</h3><p className="mt-1 text-xs text-text-tertiary">Compare volume separately from each model’s completion and rejection rates.</p></div>
        <label className="flex items-center gap-2 text-xs text-text-secondary">Sort by<select aria-label="Sort model demand" value={sort} onChange={event => setSort(event.target.value)} className="min-h-10 rounded-lg border border-border-dim bg-bg-white px-3"><option value="requests">Published requests</option><option value="capacity">Capacity rejections</option></select></label>
      </div>
      <div className={`${styles.header} mb-3 items-end text-xs text-text-tertiary`} aria-hidden="true"><span>Model</span><span>Share of published traffic</span><span>Outcomes within this model</span><span /></div>
      <div className="border-t border-border-dim">{models.map(model => <DemandRow key={model.model} model={model} name={names.get(model.model) || model.model} total={total} expanded={selected === model.model} onToggle={() => setSelected(v => v === model.model ? null : model.model)} onHistory={() => setHistoryModel(model.model)} />)}</div>
      <p className="mt-3 flex flex-wrap gap-x-5 gap-y-2 text-xs text-text-tertiary"><span className="inline-flex items-center gap-2"><i className="h-2 w-4 rounded-sm bg-accent-brand" />Completed</span><span className="inline-flex items-center gap-2"><i className="h-2 w-4 rounded-sm bg-accent-amber" />Capacity rejected</span><span className="inline-flex items-center gap-2"><i className="h-2 w-4 rounded-sm bg-text-tertiary/40" />Other outcomes</span><span>Expand a model for exact counts.</span></p>
    </> : <p className="mt-5 border-y border-border-dim py-10 text-sm text-text-secondary">No publishable model demand for this window yet. Low-volume cohorts are hidden for privacy; this does not mean no requests were received.</p>}
    <DemandMethodology />
  </>;
  return <section aria-labelledby="model-demand-title" className={`${styles.panel} min-w-0 border-t border-border-dim pt-8`}>
    <div className="flex flex-wrap items-start justify-between gap-4">
      <div><h2 id="model-demand-title" className="text-xl font-semibold tracking-tight text-text-primary">Model traffic &amp; fulfillment</h2><p className="mt-2 text-sm leading-6 text-text-tertiary">Which models receive requests, and how those requests turn out.</p></div>
      <div role="group" aria-label="Model demand time range" className="flex rounded-lg bg-bg-secondary p-1">{WINDOWS.map(([value, label]) => <button key={value} type="button" aria-pressed={window === value} onClick={() => { setWindow(value); setSelected(null); }} className={`min-h-10 rounded-md px-3 text-xs ${window === value ? "bg-bg-white font-medium text-text-primary shadow-sm" : "text-text-secondary hover:text-text-primary"}`}>{label}</button>)}</div>
    </div>
    {content}
  </section>;
}

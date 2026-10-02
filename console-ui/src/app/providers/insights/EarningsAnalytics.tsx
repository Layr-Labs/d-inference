"use client";

import { useState } from "react";
import { Download } from "lucide-react";
import { compact, earned, money, type ProviderInsights } from "./types";
import { EarningsTimeline, type InsightMetric } from "./EarningsTimeline";
import { EarningsBreakdown } from "./EarningsBreakdown";
import { TokenMilestones } from "./TokenMilestones";
import { useProviderInsights } from "./useProviderInsights";
import styles from "./insights.module.css";

const metricOptions: { value: InsightMetric; label: string }[] = [
  { value: "earnings", label: "Earnings" },
  { value: "tokens", label: "Output tokens" },
  { value: "jobs", label: "Requests" },
];

function downloadHistory(data: ProviderInsights) {
  const rows = ["date_utc,inference_micro_usd,base_reward_micro_usd,settled_requests,input_tokens,output_tokens", ...data.days.map(day => [day.id, day.work_micro_usd, day.base_reward_micro_usd, day.jobs, day.prompt_tokens, day.completion_tokens].join(","))];
  const url = URL.createObjectURL(new Blob([rows.join("\n")], { type: "text/csv;charset=utf-8" }));
  const link = document.createElement("a"); link.href = url; link.download = `darkbloom-earnings-${data.window}.csv`; link.click(); URL.revokeObjectURL(url);
}

export function EarningsAnalyticsView({ data, window, onWindowChange, error }: {
  data: ProviderInsights; window: "7d" | "30d"; onWindowChange: (value: "7d" | "30d") => void; error?: string | null;
}) {
  const [metric, setMetric] = useState<InsightMetric>("earnings");
  return (
    <div className={styles.analytics}>
      <div className={styles.sectionHead}><div><h2>Your earnings, in detail</h2><p className={styles.note}>Settled earnings through {new Date(data.as_of).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}. Today is partial.</p></div><div className={styles.segmented} aria-label="Earnings period">{(["7d", "30d"] as const).map(value => <button type="button" key={value} aria-pressed={window === value} onClick={() => onWindowChange(value)}>{value === "7d" ? "7 days" : "30 days"}</button>)}</div></div>
      {error && <p role="status" className={styles.notice}>{error} Showing the last successful snapshot.</p>}
      <div className={styles.metrics}>
        <div><span>Earned in this period</span><strong>{money(earned(data.totals))}</strong><small>{money(data.totals.work_micro_usd)} inference + {money(data.totals.base_reward_micro_usd)} base rewards</small></div>
        <div><span>Output tokens</span><strong>{compact(data.totals.completion_tokens)}</strong><small>{compact(data.totals.prompt_tokens)} input tokens processed</small></div>
        <div><span>Settled requests</span><strong>{compact(data.totals.jobs)}</strong><small>{data.totals.jobs > 0 ? `${money(data.totals.work_micro_usd / data.totals.jobs)} average inference earnings` : "Your first settled request starts here"}</small></div>
      </div>
      <div className={styles.chartToolbar}><div className={styles.segmented} aria-label="Chart metric">{metricOptions.map(({ value, label }) => <button type="button" key={value} aria-pressed={metric === value} onClick={() => setMetric(value)}>{label}</button>)}</div><button type="button" className={styles.textButton} onClick={() => downloadHistory(data)}><Download size={14} />CSV</button></div>
      <EarningsTimeline days={data.days} metric={metric} />
      <EarningsBreakdown data={data} metric={metric} />
      <TokenMilestones tokens={data.lifetime.completion_tokens} />
    </div>
  );
}

export function EarningsAnalytics() {
  const [window, setWindow] = useState<"7d" | "30d">("7d");
  const { data, error, loading, refresh } = useProviderInsights(window);
  if (!data) return <section className={styles.analytics}><h2>Earnings insights</h2><p role="status" className={styles.notice}>{loading ? "Loading your earnings history…" : error || "No earnings data available."}</p>{error && <button type="button" className={styles.textButton} onClick={refresh}>Try again</button>}</section>;
  return <EarningsAnalyticsView data={data} window={window} onWindowChange={setWindow} error={error} />;
}

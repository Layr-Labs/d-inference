"use client";

import Link from "next/link";
import type { MyProvider } from "../types";
import { compact, earned, money, type ProviderInsights } from "./types";
import { useProviderInsights } from "./useProviderInsights";
import { LiveModels } from "./LiveModels";
import { TokenMilestones } from "./TokenMilestones";
import styles from "./insights.module.css";

export function EarningsPulse({ data }: { data: ProviderInsights }) {
  const max = Math.max(1, ...data.days.map(earned));
  return <section className={styles.pulse}><div className={styles.sectionHead}><h2>Last {data.window === "7d" ? 7 : 30} days</h2><Link href="/providers/earnings">Explore earnings</Link></div><p className={styles.pulseTotal}>{money(earned(data.totals))}<span>settled earnings</span></p><div className={styles.sparkline} role="img" aria-label={`Daily settled earnings for the selected period. ${money(data.totals.work_micro_usd)} inference, ${money(data.totals.base_reward_micro_usd)} base rewards.`}>{data.days.map(day => <span key={day.id} title={`${day.id}: ${money(earned(day))}`}><i style={{ height: `${earned(day) / max * 100}%` }} /></span>)}</div><p className={styles.note}>{compact(data.totals.jobs)} settled requests · {compact(data.totals.completion_tokens)} output tokens<br />Includes {money(data.totals.base_reward_micro_usd)} base rewards. Today is partial.</p></section>;
}

export function ProviderExperience({ providers, heartbeatSeconds, pollFailed, lastUpdatedAt }: {
  providers: MyProvider[]; heartbeatSeconds: number; pollFailed: boolean; lastUpdatedAt: number | null;
}) {
  const { data, error } = useProviderInsights();
  return <div className={styles.experience}>
    <LiveModels providers={providers} heartbeatSeconds={heartbeatSeconds} pollFailed={pollFailed} lastUpdatedAt={lastUpdatedAt} />
    {data ? <><div className={styles.twoUp}><TokenMilestones tokens={data.lifetime.completion_tokens} /><EarningsPulse data={data} /></div>{error && <p className={styles.notice} role="status">{error} Earnings and milestones show the last successful snapshot.</p>}</> : <p className={styles.note} role="status">{error || "Loading earnings and token milestones…"}</p>}
  </div>;
}

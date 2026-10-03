import { useId, useState } from 'react';
import { compact } from '../../format';
import { dayLabel, earned, money, maximum, percent, type InsightSlice } from './types';
import styles from './insights.module.css';

export type InsightMetric = 'earnings' | 'tokens' | 'jobs';
export function metricValue(row: InsightSlice, metric: InsightMetric) {
  if (metric === 'earnings') return earned(row);
  if (metric === 'tokens') return row.completion_tokens;
  return row.jobs;
}
export const metricLabel = (value: bigint, metric: InsightMetric) =>
  metric === 'earnings' ? money(value) : compact(value);

export function EarningsTimeline({
  days,
  metric,
}: {
  days: InsightSlice[];
  metric: InsightMetric;
}) {
  const [selectedID, setSelectedID] = useState<string | null>(null);
  const detailID = useId();
  const selected = days.find((day) => day.id === selectedID) ?? days.at(-1);
  const max = maximum(days.map((day) => metricValue(day, metric)));
  return (
    <div className={styles.timeline}>
      <div className={styles.chartScale}>
        <span>{metricLabel(max, metric)}</span>
        <span>{metricLabel(max / 2n, metric)}</span>
        <span>0</span>
      </div>
      <div className={styles.bars} role="group" aria-label={`Daily ${metric} in UTC`}>
        {days.map((day, index) => {
          const value = metricValue(day, metric);
          const base = metric === 'earnings' ? day.base_reward_micro_usd : 0n;
          return (
            <button
              type="button"
              key={day.id}
              aria-pressed={selected?.id === day.id}
              aria-describedby={detailID}
              aria-label={`${dayLabel(day.id)}${index === days.length - 1 ? ', today so far' : ''}: ${metricLabel(value, metric)} ${metric}`}
              onClick={() => setSelectedID(day.id)}
              onMouseEnter={() => setSelectedID(day.id)}
              onFocus={() => setSelectedID(day.id)}
              className={styles.barButton}
            >
              <span
                className={styles.barStack}
                data-partial={index === days.length - 1}
                style={{ height: `${Math.max(value > 0n ? 1 : 0, percent(value, max))}%` }}
              >
                {base > 0 && <i className={styles.rewardBar} style={{ flexGrow: Number(base) }} />}
                <i className={styles.workBar} style={{ flexGrow: Number(value - base) }} />
              </span>
            </button>
          );
        })}
      </div>
      <div className={styles.chartDates}>
        <span>{days[0] && dayLabel(days[0].id)}</span>
        <span>Today so far · UTC</span>
      </div>
      {selected && (
        <div id={detailID} className={styles.chartDetail}>
          <strong>{dayLabel(selected.id)}</strong>
          <span>
            <i className={styles.workDot} />
            {money(selected.work_micro_usd)} inference
          </span>
          <span>
            <i className={styles.rewardDot} />
            {money(selected.base_reward_micro_usd)} base rewards
          </span>
          <span>{compact(selected.jobs)} settled requests</span>
          <span>{compact(selected.completion_tokens)} output tokens</span>
        </div>
      )}
    </div>
  );
}

import { useState } from 'react';
import { shortModelName } from '../../format';
import { compact } from '../../format';
import { money, percent, type InsightSlice, type ProviderInsights } from './types';
import { metricLabel, metricValue, type InsightMetric } from './EarningsTimeline';
import styles from './insights.module.css';

function rowLabel(row: InsightSlice, dimension: 'models' | 'machines') {
  if (dimension === 'models')
    return row.id === 'base_reward'
      ? 'Base rewards'
      : shortModelName(row.id) || 'Unspecified model';
  return row.id ? `Mac ${row.id.slice(0, 8)}` : 'Account-level rewards / unassigned';
}

export function EarningsBreakdown({
  data,
  metric,
}: {
  data: ProviderInsights;
  metric: InsightMetric;
}) {
  const [dimension, setDimension] = useState<'models' | 'machines'>('models');
  const [showAll, setShowAll] = useState(false);
  const rows = [...(dimension === 'models' ? data.models : data.machines)].sort((a, b) =>
    metricValue(a, metric) === metricValue(b, metric)
      ? a.id.localeCompare(b.id)
      : metricValue(a, metric) > metricValue(b, metric)
        ? -1
        : 1,
  );
  const total = rows.reduce((sum, row) => sum + metricValue(row, metric), 0n);
  return (
    <section className={styles.breakdown} aria-labelledby="earnings-breakdown-title">
      <div className={styles.sectionHead}>
        <h3 id="earnings-breakdown-title">Where it comes from</h3>
        <div className={styles.segmented} aria-label="Breakdown grouping">
          {(['models', 'machines'] as const).map((value) => (
            <button
              type="button"
              key={value}
              aria-pressed={dimension === value}
              onClick={() => setDimension(value)}
            >
              {value === 'models' ? 'By model' : 'By Mac'}
            </button>
          ))}
        </div>
      </div>
      {rows.length === 0 && (
        <p className={styles.empty}>
          No settled earnings in this period. Your first inference payment will appear here.
        </p>
      )}
      {(showAll ? rows : rows.slice(0, 6)).map((row) => (
        <details className={styles.breakdownRow} key={row.id}>
          <summary>
            <span title={row.id}>{rowLabel(row, dimension)}</span>
            <span className={styles.shareTrack}>
              <i
                style={{ width: `${total > 0 ? percent(metricValue(row, metric), total) : 0}%` }}
              />
            </span>
            <strong>{metricLabel(metricValue(row, metric), metric)}</strong>
            <small>
              {total > 0 ? percent(metricValue(row, metric), total).toFixed(1) : '0.0'}%
            </small>
          </summary>
          <div className={styles.chartDetail}>
            <span>{money(row.work_micro_usd)} inference</span>
            <span>{money(row.base_reward_micro_usd)} base rewards</span>
            <span>{compact(row.jobs)} settled requests</span>
            <span>
              {compact(row.prompt_tokens)} input / {compact(row.completion_tokens)} output tokens
            </span>
          </div>
        </details>
      ))}
      {rows.length > 6 && (
        <button className={styles.textButton} type="button" onClick={() => setShowAll(!showAll)}>
          {showAll ? 'Show fewer' : `Show all ${rows.length} ${dimension}`}
        </button>
      )}
      {dimension === 'machines' && (
        <p className={styles.note}>
          Historical machine IDs are retained after removal. Earnings without a machine ID,
          including account-level base rewards, appear separately.
        </p>
      )}
    </section>
  );
}

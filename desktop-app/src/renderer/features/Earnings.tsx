import { useState } from 'react';
import { Copy, Check } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { api } from '../useBackend';
import { Header, Button } from '../components/UI';
import { useInsights } from './insights/useInsights';
import { compact } from '../format';
import { earned, money } from './insights/types';
import { EarningsTimeline, type InsightMetric } from './insights/EarningsTimeline';
import { EarningsBreakdown } from './insights/EarningsBreakdown';
import { TokenMilestones } from './insights/TokenMilestones';
import styles from './insights/insights.module.css';

export function Earnings({ backend }: { backend: BackendState }) {
  const [window, setWindow] = useState<'7d' | '30d'>('7d');
  const [metric, setMetric] = useState<InsightMetric>('earnings');
  const [copied, setCopied] = useState(false);
  const { data, error, refresh } = useInsights(backend.state!, window);
  const copy = async () => {
    if (!data) return;
    const rows = [
      'date_utc,inference_micro_usd,base_reward_micro_usd,settled_requests,input_tokens,output_tokens',
      ...data.days.map((d) =>
        d.available === false
          ? `${d.id},,,,,`
          : [
              d.id,
              d.work_micro_usd,
              d.base_reward_micro_usd,
              d.jobs,
              d.prompt_tokens,
              d.completion_tokens,
            ].join(','),
      ),
    ];
    try {
      await api?.copy(rows.join('\n'));
      setCopied(true);
    } catch {
      backend.setError('Could not copy earnings history.');
    }
  };
  return (
    <>
      <Header
        title="Earnings"
        description="The work your Macs do, and what it earns."
        action={
          <div className={styles.segmented} aria-label="Earnings period">
            {(['7d', '30d'] as const).map((value) => (
              <button
                key={value}
                aria-pressed={window === value}
                onClick={() => {
                  setWindow(value);
                  setCopied(false);
                }}
              >
                {value === '7d' ? '7 days' : '30 days'}
              </button>
            ))}
          </div>
        }
      />
      {!data ? (
        <div className="empty-state">
          <h2>{backend.state?.linked ? 'Earnings insights' : 'Link your account'}</h2>
          <p>
            {!backend.state?.linked
              ? 'Link this Mac to see earnings and lifetime milestones.'
              : error || 'Loading settled earnings…'}
          </p>
          {error && <Button onClick={() => void refresh()}>Try again</Button>}
        </div>
      ) : (
        <div className={styles.analytics}>
          {error && (
            <p className={styles.notice} role="status">
              {error} Showing the last observation.
            </p>
          )}
          <div className={styles.metrics}>
            <div>
              <span
                title={
                  !data.history_complete
                    ? `Recorded history since ${new Date(data.since).toLocaleString()}`
                    : undefined
                }
              >
                {data.history_complete ? 'Earned in this period' : 'Recorded earnings'}
              </span>
              <strong>{money(earned(data.totals))}</strong>
              <small>
                {money(data.totals.work_micro_usd)} inference +{' '}
                {money(data.totals.base_reward_micro_usd)} base rewards
              </small>
            </div>
            <div>
              <span>Output tokens</span>
              <strong>{compact(data.totals.completion_tokens)}</strong>
              <small>{compact(data.totals.prompt_tokens)} input tokens processed</small>
            </div>
            <div>
              <span>Settled requests</span>
              <strong>{compact(data.totals.jobs)}</strong>
              <small>
                {data.totals.jobs > 0n
                  ? `${money(data.totals.work_micro_usd / data.totals.jobs)} average inference earnings`
                  : 'Your first settled request starts here'}
              </small>
            </div>
          </div>
          <div className={styles.chartToolbar}>
            <div className={styles.segmented} aria-label="Chart metric">
              {(
                [
                  { id: 'earnings', label: 'Earnings' },
                  { id: 'tokens', label: 'Output tokens' },
                  { id: 'jobs', label: 'Requests' },
                ] as const
              ).map(({ id, label }) => (
                <button key={id} aria-pressed={metric === id} onClick={() => setMetric(id)}>
                  {label}
                </button>
              ))}
            </div>
            <button className={styles.textButton} onClick={() => void copy()}>
              {copied ? <Check size={14} /> : <Copy size={14} />} {copied ? 'Copied' : 'Copy CSV'}
            </button>
          </div>
          <EarningsTimeline days={data.days} metric={metric} partial={!data.history_complete} />
          <EarningsBreakdown data={data} metric={metric} />
          {data.lifetime.completion_tokens !== null && (
            <TokenMilestones tokens={data.lifetime.completion_tokens} />
          )}
          <p className={styles.note}>
            Settled through {new Date(data.as_of).toLocaleString()}. Calendar days are UTC; today is
            partial. Balances and withdrawals remain in the console.
          </p>
        </div>
      )}
    </>
  );
}

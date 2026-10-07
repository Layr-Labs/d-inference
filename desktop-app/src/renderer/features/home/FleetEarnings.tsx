import { ArrowUpRight } from 'lucide-react';
import type { BackendState } from '../../useBackend';
import { count, money } from '../../format';
import { useInsights } from '../insights/useInsights';
import { EarningsTimeline } from '../insights/EarningsTimeline';
import styles from './fleet.module.css';

export function FleetEarnings({
  backend,
  onEarnings,
}: {
  backend: BackendState;
  onEarnings: () => void;
}) {
  const { data, error } = useInsights(backend.state!);
  const week = backend.cloud?.week_micro_usd;
  const complete = backend.cloud?.earnings_complete !== false;
  const since = backend.cloud?.earnings_since
    ? new Date(backend.cloud.earnings_since * 1000).toLocaleString()
    : undefined;
  const pace = week && /^\d+$/.test(week) ? money(((BigInt(week) * 365n) / 7n).toString(), 0) : '—';
  return (
    <section className={styles.earnings} aria-label="Fleet earnings">
      <div className={styles.earningsMetrics}>
        <div>
          <span>Earned all time</span>
          <strong>{money(backend.cloud?.lifetime_micro_usd)}</strong>
        </div>
        <div>
          <span title={!complete && since ? `Recorded history since ${since}` : undefined}>
            {complete ? 'Past 7 days' : 'Recent earnings'}
          </span>
          <b>{money(week)}</b>
        </div>
        <div>
          {complete ? (
            <>
              <span title="Based on the past 7 days">Annualized pace</span>
              <b>
                {pace}
                <small>/yr</small>
              </b>
            </>
          ) : (
            <>
              <span>Settled payments</span>
              <b>{count(backend.cloud?.settled_records)}</b>
            </>
          )}
        </div>
      </div>
      <div className={styles.chartHeading}>
        <span>Daily earnings · 7 days</span>
        <button className="text-link" onClick={onEarnings}>
          View earnings <ArrowUpRight size={13} />
        </button>
      </div>
      {data ? (
        <EarningsTimeline days={data.days} metric="earnings" partial={!data.history_complete} />
      ) : (
        <p className={styles.emptyChart}>
          {backend.state!.linked ? (error ? 'Unavailable' : 'Loading…') : 'Account not linked'}
        </p>
      )}
      {data && error && (
        <p role="status" className={styles.caption}>
          Last known
        </p>
      )}
    </section>
  );
}

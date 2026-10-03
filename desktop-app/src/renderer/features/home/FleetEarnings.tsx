import { ArrowUpRight } from 'lucide-react';
import type { BackendState } from '../../useBackend';
import { money } from '../../format';
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
  const pace = week && /^\d+$/.test(week) ? money(((BigInt(week) * 365n) / 7n).toString(), 0) : '—';
  return (
    <section className={styles.earnings} aria-label="Fleet earnings">
      <div className={styles.earningsMetrics}>
        <div>
          <span>Earned all time</span>
          <strong>{money(backend.cloud?.lifetime_micro_usd)}</strong>
        </div>
        <div>
          <span>Past 7 days</span>
          <b>{money(week)}</b>
        </div>
        <div>
          <span>Annualized pace</span>
          <b>
            {pace}
            <small>/yr</small>
          </b>
        </div>
      </div>
      <div className={styles.chartHeading}>
        <span>Daily earnings · 7 calendar days</span>
        <button className="text-link" onClick={onEarnings}>
          View earnings <ArrowUpRight size={13} />
        </button>
      </div>
      {data ? (
        <EarningsTimeline days={data.days} metric="earnings" />
      ) : (
        <p className={styles.emptyChart}>
          {backend.state!.linked
            ? error || 'Loading earnings history…'
            : 'Link this Mac to view earnings history.'}
        </p>
      )}
      {data && error && (
        <p role="status" className={styles.caption}>
          {error} Showing the last observation.
        </p>
      )}
      <p className={styles.caption}>
        Annualized from the past 7 days. A pace, not guaranteed income.
      </p>
    </section>
  );
}

import { ArrowUpRight } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import { count } from '../../format';
import { contribution } from './contribution';
import styles from './home.module.css';

export function ContributionMetrics({
  activity,
  explore,
}: {
  activity: Snapshot['activity'];
  explore: () => void;
}) {
  const totals = contribution(activity);
  return (
    <section className={styles.contribution} aria-label="Session contribution">
      <div className={styles.shared}>
        <span>{totals.label}</span>
        <strong title={totals.note}>{totals.tokens}</strong>
        <div className={styles.tokenBreakdown} aria-label="Token breakdown">
          <span>
            Input <b>{totals.input}</b>
          </span>
          <span title="Included in input">
            Cached <b>{totals.cached}</b>
          </span>
          <span>
            Output <b>{totals.output}</b>
          </span>
          <span title="Included in output">
            Reasoning <b>{totals.reasoning}</b>
          </span>
        </div>
        <small>
          {count(activity.requests)} requests served{' '}
          {totals.pending && (
            <span title="Awaiting complete input and output usage">
              · {totals.pending} pending{' '}
            </span>
          )}
          <button onClick={explore}>
            Explore Stats <ArrowUpRight size={12} />
          </button>
        </small>
      </div>
      <div className={styles.generated}>
        <strong title={totals.earnings === '—' ? 'Session earnings unavailable' : undefined}>
          {totals.earnings}
        </strong>
        <span>Generated this session</span>
      </div>
    </section>
  );
}

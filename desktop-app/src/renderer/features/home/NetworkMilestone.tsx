import type { NetworkData } from '../../../shared/contracts';
import { compact, count } from '../../format';
import { milestoneProgress, networkStatus, networkTokens } from './milestones';
import styles from './milestone.module.css';

const CELLS = 24;
const STATUS_LABEL = {
  connecting: 'Connecting',
  live: 'Live',
  stale: 'Reconnecting',
  unavailable: 'Unavailable',
};

export function NetworkMilestone({ network }: { network?: NetworkData }) {
  const status = networkStatus(network);
  const total = networkTokens(network);
  const milestone = total === undefined ? undefined : milestoneProgress(total);
  const lit = milestone ? Math.round(milestone.progress * CELLS) : 0;
  return (
    <section className={styles.strip} aria-label="Collective network progress">
      <div className={styles.total}>
        <strong>{total === undefined ? '—' : compact(total)}</strong>
        <span>Network tokens</span>
      </div>
      {total !== undefined && (
        <dl className={styles.facts}>
          {network?.last_24h_tokens && (
            <div>
              <dt>Last 24 hours</dt>
              <dd>+{compact(network.last_24h_tokens)}</dd>
            </div>
          )}
          <div>
            <dt>Macs connected</dt>
            <dd>{count(network?.total_macs)}</dd>
          </div>
        </dl>
      )}
      <div className={styles.goal}>
        <div className={styles.goalLabel} title="Proposed network milestone">
          <span>{milestone ? `Next milestone ${compact(milestone.next)}` : 'Next milestone'}</span>
        </div>
        <div
          className={styles.cells}
          role="progressbar"
          aria-label="Network tokens toward the next proposed milestone"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={milestone ? Math.round(milestone.progress * 100) : undefined}
          aria-valuetext={
            milestone
              ? `${compact(total)} of a proposed ${compact(milestone.next)} tokens`
              : 'Network statistics unavailable'
          }
        >
          {Array.from({ length: CELLS }, (_, i) => (
            <i key={i} data-on={i < lit || undefined} />
          ))}
        </div>
      </div>
      <span className={styles.status} data-status={status}>
        <i aria-hidden="true" />
        {STATUS_LABEL[status]}
      </span>
    </section>
  );
}

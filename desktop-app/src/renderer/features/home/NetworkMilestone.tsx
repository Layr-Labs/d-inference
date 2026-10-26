import type { NetworkData } from '../../../shared/contracts';
import { compact, count } from '../../format';
import { milestoneProgress, networkStatus, networkTokens } from './milestones';
import styles from './milestone.module.css';

const CELLS = 24;
// A total just short of a milestone rounds down, so it never reads as reached
// ("1B of a proposed 1B").
const towardMilestone = (value: number) =>
  // roundingMode is supported by Electron's Chromium and Node, but not yet in this TS lib.
  Intl.NumberFormat('en', {
    notation: 'compact',
    maximumFractionDigits: 1,
    roundingMode: 'floor',
  } as Intl.NumberFormatOptions).format(value);
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
  // Progress is always short of the next milestone, so it never fills the strip or reads 100%.
  const lit = milestone ? Math.min(CELLS - 1, Math.round(milestone.progress * CELLS)) : 0;
  return (
    <section className={styles.strip} aria-label="Collective network progress">
      <div className={styles.total}>
        <strong title={total === undefined ? undefined : `${count(total)} tokens`}>
          {total === undefined ? '—' : towardMilestone(total)}
        </strong>
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
          aria-valuenow={milestone ? Math.min(99, Math.round(milestone.progress * 100)) : undefined}
          aria-valuetext={
            milestone
              ? `${towardMilestone(total!)} of a proposed ${compact(milestone.next)} tokens`
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

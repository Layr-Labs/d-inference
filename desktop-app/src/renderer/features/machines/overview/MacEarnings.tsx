import type { ReactNode } from 'react';
import { money } from '../../../format';
import styles from './overview.module.css';

export function MacEarnings({
  label,
  lifetime,
  day,
  week,
  children,
}: {
  label: string;
  lifetime?: string;
  day?: string;
  week?: string;
  children?: ReactNode;
}) {
  return (
    <section className={styles.earnings} aria-label={label}>
      <div className={styles.earningsMetrics}>
        <div>
          <span>Earned all time</span>
          <strong>{money(lifetime)}</strong>
        </div>
        <div>
          <span>Last 24 hours</span>
          <b>{money(day)}</b>
        </div>
        <div>
          <span>Usage earnings · 7 days</span>
          <b>{money(week)}</b>
        </div>
      </div>
      {children && <p className={styles.caption}>{children}</p>}
    </section>
  );
}

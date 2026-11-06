import { RequestCurve } from './RequestCurve';
import { TokenBars } from './TokenBars';
import type { TrafficPoint } from './data';
import styles from './stats.module.css';

export type TrafficMetric = 'requests' | 'tokens';

export function TrafficChart({
  points,
  metric,
  onMetric,
  scope,
}: {
  points: TrafficPoint[];
  metric: TrafficMetric;
  onMetric: (value: TrafficMetric) => void;
  scope: string;
}) {
  return (
    <section className={styles.traffic}>
      <div className={styles.sectionHead}>
        <div>
          <h2>Traffic</h2>
          <span>{scope}</span>
        </div>
        <div className={styles.segmented}>
          {(['requests', 'tokens'] as const).map((value) => (
            <button key={value} aria-pressed={metric === value} onClick={() => onMetric(value)}>
              {value === 'requests' ? 'Requests' : 'Tokens served'}
            </button>
          ))}
        </div>
      </div>
      {!points.length ? (
        <p className={styles.footnote}>Traffic appears as this Mac serves requests.</p>
      ) : metric === 'requests' ? (
        <RequestCurve points={points} />
      ) : (
        <TokenBars points={points} />
      )}
    </section>
  );
}

import { useId, useState } from 'react';
import { compact } from '../../format';
import { curve, type TrafficPoint } from './data';
import styles from './stats.module.css';
export function TrafficChart({
  points,
  metric,
  onMetric,
  scope,
}: {
  points: TrafficPoint[];
  metric: 'requests' | 'tokens';
  onMetric: (value: 'requests' | 'tokens') => void;
  scope: string;
}) {
  const id = useId().replace(/:/g, ''),
    [selected, setSelected] = useState<number | null>(null);
  const max = Math.max(1, ...points.map((point) => point[metric]));
  const plot = points.map((point, index) => ({
    x: points.length > 1 ? (index / (points.length - 1)) * 800 : 400,
    y: 160 - (point[metric] / max) * 140,
  }));
  const path = curve(plot),
    point = selected === null ? undefined : points[selected];
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
              {value === 'requests' ? 'Requests' : 'Output tokens'}
            </button>
          ))}
        </div>
      </div>
      {points.length ? (
        <>
          <div className={styles.chartReadout}>
            <strong>
              {compact(point ? point[metric] : points.reduce((sum, p) => sum + p[metric], 0))}
            </strong>
            <span>
              {point
                ? new Date(point.at * 1000).toLocaleTimeString([], {
                    hour: '2-digit',
                    minute: '2-digit',
                  })
                : 'Across this view'}{' '}
              · {metric}
            </span>
          </div>
          <div className={styles.plot}>
            <span className={styles.axisMax}>{compact(max)}</span>
            <svg
              viewBox="0 0 800 180"
              preserveAspectRatio="none"
              role="img"
              aria-label={`${metric} over time`}
            >
              <defs>
                <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor="var(--accent-brand)" stopOpacity=".3" />
                  <stop offset="100%" stopColor="var(--accent-brand)" stopOpacity="0" />
                </linearGradient>
              </defs>
              {[20, 90, 160].map((y) => (
                <line
                  key={y}
                  x1="0"
                  x2="800"
                  y1={y}
                  y2={y}
                  stroke="var(--line)"
                  strokeDasharray="3 5"
                />
              ))}
              <path
                d={`${path} L ${plot.at(-1)!.x},180 L ${plot[0].x},180 Z`}
                fill={`url(#${id})`}
              />
              <path
                d={path}
                fill="none"
                stroke="var(--accent-brand)"
                strokeWidth="2.5"
                vectorEffect="non-scaling-stroke"
              />
              {selected !== null && plot[selected] && (
                <circle
                  cx={plot[selected].x}
                  cy={plot[selected].y}
                  r="4"
                  fill="var(--accent-brand)"
                />
              )}
            </svg>
            <div className={styles.hitPoints}>
              {points.map((p, i) => (
                <button
                  key={p.at}
                  aria-label={`${new Date(p.at * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}: ${compact(p[metric])} ${metric}`}
                  onFocus={() => setSelected(i)}
                  onMouseEnter={() => setSelected(i)}
                  onClick={() => setSelected(i)}
                />
              ))}
            </div>
          </div>
          <div className={styles.chartAxis}>
            <span>
              {new Date(points[0].at * 1000).toLocaleTimeString([], {
                hour: '2-digit',
                minute: '2-digit',
              })}
            </span>
            <span>
              {new Date(points.at(-1)!.at * 1000).toLocaleTimeString([], {
                hour: '2-digit',
                minute: '2-digit',
              })}
            </span>
          </div>
        </>
      ) : (
        <p className={styles.footnote}>Traffic appears as this Mac serves requests.</p>
      )}
    </section>
  );
}

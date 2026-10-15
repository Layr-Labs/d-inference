import { useId, useState } from 'react';
import { compact, timeOfDay } from '../../format';
import { curve, type TrafficPoint } from './data';
import styles from './stats.module.css';

export function RequestCurve({ points }: { points: TrafficPoint[] }) {
  const id = useId().replace(/:/g, ''),
    [selected, setSelected] = useState<number | null>(null);
  const max = Math.max(1, ...points.map((point) => point.requests));
  const plot = points.map((point, index) => ({
    x: points.length > 1 ? (index / (points.length - 1)) * 800 : 400,
    y: 160 - (point.requests / max) * 140,
  }));
  const path = curve(plot),
    point = selected === null ? undefined : points[selected];
  return (
    <>
      <div className={styles.chartReadout}>
        <strong>
          {compact(point ? point.requests : points.reduce((sum, p) => sum + p.requests, 0))}
        </strong>
        <span>{point ? timeOfDay(point.at) : 'Across this view'} · requests</span>
      </div>
      <div className={styles.plot}>
        <span className={styles.axisMax}>{compact(max)}</span>
        <svg
          viewBox="0 0 800 180"
          preserveAspectRatio="none"
          role="img"
          aria-label="requests over time"
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
          <path d={`${path} L ${plot.at(-1)!.x},180 L ${plot[0].x},180 Z`} fill={`url(#${id})`} />
          <path
            d={path}
            fill="none"
            stroke="var(--accent-brand)"
            strokeWidth="2.5"
            vectorEffect="non-scaling-stroke"
          />
          {selected !== null && plot[selected] && (
            <circle cx={plot[selected].x} cy={plot[selected].y} r="4" fill="var(--accent-brand)" />
          )}
        </svg>
        <div className={styles.hitPoints}>
          {points.map((p, i) => (
            <button
              key={p.at}
              aria-label={`${timeOfDay(p.at)}: ${compact(p.requests)} requests`}
              onFocus={() => setSelected(i)}
              onMouseEnter={() => setSelected(i)}
              onClick={() => setSelected(i)}
            />
          ))}
        </div>
      </div>
      <div className={styles.chartAxis}>
        <span>{timeOfDay(points[0].at)}</span>
        <span>{timeOfDay(points.at(-1)!.at)}</span>
      </div>
    </>
  );
}

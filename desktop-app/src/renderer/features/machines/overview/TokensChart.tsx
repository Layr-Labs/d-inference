import { useId, useRef, useState, type KeyboardEvent } from 'react';
import { compact, count } from '../../../format';
import { HOUR, HOURS, type HourBucket } from './hourlyTokens';
import styles from './overview.module.css';
import chart from './tokensChart.module.css';

const hourLabel = (at: number) => new Date(at * 1000).toLocaleTimeString([], { hour: 'numeric' });
const amount = (value: number, unit: string) => `${count(value)} ${unit}${value === 1 ? '' : 's'}`;
const keyTargets = (index: number): Record<string, number> => ({
  ArrowLeft: index - 1,
  ArrowRight: index + 1,
  Home: 0,
  End: HOURS - 1,
});

function describe(bucket: HourBucket, now: number, until: string) {
  const end = Math.min(now, bucket.start + HOUR);
  const range = `${hourLabel(bucket.start)} – ${end < bucket.start + HOUR ? until.toLowerCase() : hourLabel(end)}`;
  if (bucket.tokens === null) return { range, value: 'No observations' };
  const span = end - bucket.start;
  const partial =
    span - bucket.observed >= 120
      ? ` · observed ${Math.round(bucket.observed / 60)} of ${Math.round(span / 60)} min`
      : '';
  return {
    range,
    value: `${amount(bucket.tokens, 'token')}${bucket.requests === null ? '' : ` · ${amount(bucket.requests, 'request')}`}${partial}`,
  };
}

// `until` names the end of the window: "Now" for a live Mac, the last observation otherwise.
// `dense` trades the explanatory caption and bar height for vertical space.
export function TokensChart({
  buckets,
  now,
  until = 'Now',
  dense = false,
}: {
  buckets: HourBucket[];
  now: number;
  until?: string;
  dense?: boolean;
}) {
  const [selectedStart, setSelectedStart] = useState<number>();
  const titleID = useId();
  const bars = useRef<(HTMLButtonElement | null)[]>([]);
  const found = buckets.findIndex((bucket) => bucket.start === selectedStart);
  const selected = found < 0 ? HOURS - 1 : found;
  const observed = buckets.filter((bucket) => bucket.tokens !== null);
  const tokens = observed.reduce((sum, bucket) => sum + (bucket.tokens ?? 0), 0);
  const counted = observed.filter((bucket) => bucket.requests !== null);
  const requests = counted.reduce((sum, bucket) => sum + (bucket.requests ?? 0), 0);
  const max = Math.max(1, ...observed.map((bucket) => bucket.tokens ?? 0));
  const select = (index: number) => setSelectedStart(buckets[index].start);
  const keydown = (event: KeyboardEvent, index: number) => {
    const target = keyTargets(index)[event.key];
    if (target === undefined) return;
    event.preventDefault();
    const next = Math.min(HOURS - 1, Math.max(0, target));
    select(next);
    bars.current[next]?.focus();
  };
  const detail = describe(buckets[selected], now, until);
  return (
    <section className={styles.section} aria-labelledby={titleID} data-compact={dense}>
      <div className={styles.heading}>
        <div>
          <h2 id={titleID}>Tokens shared</h2>
          <p>Past 24 hours · hourly</p>
        </div>
        <span>
          {observed.length
            ? `${compact(tokens)} token${tokens === 1 ? '' : 's'}${counted.length ? ` · ${compact(requests)} request${requests === 1 ? '' : 's'}` : ''}`
            : 'No observations yet'}
        </span>
      </div>
      <div className={chart.chart} data-compact={dense}>
        <div className={chart.scale} aria-hidden="true">
          <span>{compact(max)}</span>
          <span>{compact(max / 2)}</span>
          <span>0</span>
        </div>
        <div className={chart.bars} role="group" aria-label="Tokens shared per hour">
          {buckets.map((bucket, index) => {
            const { range, value } = describe(bucket, now, until);
            return (
              <button
                key={bucket.start}
                ref={(element) => {
                  bars.current[index] = element;
                }}
                type="button"
                className={chart.bar}
                tabIndex={index === selected ? 0 : -1}
                aria-pressed={index === selected}
                aria-label={`${range}: ${value}`}
                data-empty={bucket.tokens === null}
                data-partial={index === HOURS - 1}
                onClick={() => select(index)}
                onFocus={() => select(index)}
                onMouseEnter={() => select(index)}
                onKeyDown={(event) => keydown(event, index)}
              >
                <span
                  style={
                    bucket.tokens === null
                      ? undefined
                      : {
                          height: `${Math.max(bucket.tokens > 0 ? 2 : 0, (bucket.tokens / max) * 100)}%`,
                        }
                  }
                />
              </button>
            );
          })}
        </div>
        <div className={chart.axis} aria-hidden="true">
          {[0, 6, 12, 18].map((index) => (
            <span key={index}>{hourLabel(buckets[index].start)}</span>
          ))}
          <span>{until}</span>
        </div>
      </div>
      <p className={chart.detail} aria-hidden="true">
        <strong>{detail.range}</strong>
        <span>{detail.value}</span>
      </p>
      {!dense && (
        <p className={styles.caption}>
          Output tokens generated on this Mac each hour. Blank hours have no observations, because
          the provider wasn’t running or the runtime wasn’t reporting; they aren’t counted as zero.
        </p>
      )}
    </section>
  );
}

import { useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { compact, timeOfDay } from '../../format';
import type { TrafficPoint } from './data';
import { describeTokenBar, reportsPromptTokens, tokenBars, tokenSeries } from './tokenSeries';
import styles from './stats.module.css';
import bars from './tokenBars.module.css';

export function TokenBars({ points }: { points: TrafficPoint[] }) {
  const data = useMemo(() => tokenBars(points), [points]);
  const [selected, setSelected] = useState<number | null>(null);
  const refs = useRef<(HTMLButtonElement | null)[]>([]);
  const prompt = reportsPromptTokens(data);
  const series = prompt ? tokenSeries : tokenSeries.filter((entry) => entry.key === 'output');
  const max = Math.max(1, ...data.map((bar) => bar.total));
  const bar = selected === null ? undefined : data[selected];
  const focus = selected ?? data.length - 1;
  const keydown = (event: KeyboardEvent, index: number) => {
    const target = { ArrowLeft: index - 1, ArrowRight: index + 1, Home: 0, End: data.length - 1 }[
      event.key
    ];
    if (target === undefined) return;
    event.preventDefault();
    const next = Math.min(data.length - 1, Math.max(0, target));
    setSelected(next);
    refs.current[next]?.focus();
  };
  return (
    <>
      <div className={bars.top}>
        <div className={styles.chartReadout}>
          <strong>{compact(bar ? bar.total : data.reduce((sum, b) => sum + b.total, 0))}</strong>
          <span>
            {bar ? `${timeOfDay(bar.at)} · ${describeTokenBar(bar)}` : 'Across this view'}
          </span>
        </div>
        <ul className={bars.legend} aria-label="Chart legend">
          {series.map((entry) => (
            <li key={entry.key}>
              <i data-series={entry.key} aria-hidden="true" />
              {entry.label}
            </li>
          ))}
        </ul>
      </div>
      <div className={styles.plot}>
        <span className={styles.axisMax}>{compact(max)}</span>
        <div className={bars.bars} role="group" aria-label="Tokens served per interval">
          {data.map((entry, index) => {
            const label = `${timeOfDay(entry.at)}: ${describeTokenBar(entry)}`;
            return (
              <button
                key={entry.at}
                ref={(element) => {
                  refs.current[index] = element;
                }}
                type="button"
                className={bars.bar}
                title={label}
                aria-label={label}
                aria-pressed={index === selected}
                tabIndex={index === focus ? 0 : -1}
                onClick={() => setSelected(index)}
                onFocus={() => setSelected(index)}
                onMouseEnter={() => setSelected(index)}
                onKeyDown={(event) => keydown(event, index)}
              >
                <span className={bars.stack} style={{ height: `${(entry.total / max) * 100}%` }}>
                  {series.map(({ key }) => {
                    const value = entry[key] ?? 0;
                    return value > 0 ? (
                      <i key={key} data-series={key} style={{ flexGrow: value }} />
                    ) : null;
                  })}
                </span>
              </button>
            );
          })}
        </div>
      </div>
      <div className={styles.chartAxis}>
        <span>{timeOfDay(data[0].at)}</span>
        <span>{timeOfDay(data.at(-1)!.at)}</span>
      </div>
      {!prompt && (
        <p className={styles.footnote}>
          Input and cached input counts are not reported by this runtime yet.
        </p>
      )}
    </>
  );
}

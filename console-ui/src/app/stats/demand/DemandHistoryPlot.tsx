import { useId, useRef, useState } from "react";
import { formatCompactNumber } from "../format";
import { bucketLabel, bucketTick, metricValue, type DemandMetric } from "./history";
import { percent, type ModelDemand } from "./types";

const WIDTH = 900;
const HEIGHT = 190;

export function DemandHistoryPlot({ model, metric, bucketSeconds }: { model: ModelDemand; metric: DemandMetric; bucketSeconds: number }) {
  const [selected, setSelected] = useState<number | null>(null);
  const graphic = useRef<SVGSVGElement>(null);
  const id = useId();
  const series = model.time_series;
  const max = metric === "completion_rate" ? 100 : Math.max(1, ...series.map(b => b.counts ? metricValue(b.counts, metric) : 0));
  const step = WIDTH / Math.max(1, series.length);
  const x = (index: number) => (index + .5) * step;
  const y = (value: number) => HEIGHT * (1 - value / max);
  const bucket = selected === null ? null : series.at(selected);
  const counts = bucket?.counts;
  const ticks = [0, Math.floor(series.length / 2), series.length - 1];
  const units = metric === "completion_rate" ? "%" : "";
  function selectAt(clientX: number) {
    const rect = graphic.current?.getBoundingClientRect();
    if (rect?.width) setSelected(Math.max(0, Math.min(series.length - 1, Math.floor((clientX - rect.left) / rect.width * series.length))));
  }
  return <div>
    <div className="min-h-20 text-xs leading-5 text-text-secondary" role="status" aria-live="polite" aria-atomic="true">
      {bucket ? <>
        <p className="font-medium text-text-primary">{bucketLabel(bucket.timestamp, bucketSeconds)}</p>
        {counts ? <p className="mt-1 flex flex-wrap gap-x-5 gap-y-1 tabular-nums"><span>{counts.requests.toLocaleString()} received</span><span>{counts.completed.toLocaleString()} completed · {percent(counts.completed, counts.requests)}</span><span>{counts.capacity_rejected.toLocaleString()} capacity rejected</span><span>{counts.latency_rejected.toLocaleString()} latency limited</span><span>{counts.timed_out.toLocaleString()} timed out</span><span>{counts.failed.toLocaleString()} service errors</span>{metric === "http_429" && <span>{counts.http_429.toLocaleString()} HTTP 429</span>}</p>
          : <p className="mt-1">Interval not published: no observations or below the privacy threshold. This is not a measured zero.</p>}
      </> : <p>Hover, tap, or use the arrow keys to inspect exact interval counts.</p>}
    </div>
    <div role="group" aria-label={`${model.model} demand history chart`} aria-describedby={`${id}-help`} tabIndex={0}
      onFocus={() => setSelected(current => current ?? 0)} onBlur={() => setSelected(null)}
      onPointerMove={event => selectAt(event.clientX)} onPointerDown={event => selectAt(event.clientX)} onPointerLeave={() => setSelected(null)}
      onKeyDown={event => {
        if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
        event.preventDefault();
        if (event.key === "Home") setSelected(0);
        else if (event.key === "End") setSelected(series.length - 1);
        else setSelected(current => Math.max(0, Math.min(series.length - 1, (current ?? 0) + (event.key === "ArrowRight" ? 1 : -1))));
      }} className="relative h-60 rounded focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent-brand">
      <div className="pointer-events-none absolute bottom-7 left-0 top-2 w-11 text-right text-[11px] tabular-nums text-text-tertiary" aria-hidden="true">
        {[0, .5, 1].map(ratio => <span key={ratio} className="absolute right-0 -translate-y-1/2" style={{ top: `${100 * (1 - ratio)}%` }}>{formatCompactNumber(max * ratio)}{units}</span>)}
      </div>
      <div className="absolute bottom-7 left-14 right-1 top-2">
        <svg ref={graphic} viewBox={`0 0 ${WIDTH} ${HEIGHT}`} preserveAspectRatio="none" className="h-full w-full" aria-hidden="true">
          <defs><pattern id={`${id}-gap`} width="8" height="8" patternUnits="userSpaceOnUse"><path d="M0 8L8 0" stroke="var(--text-tertiary)" strokeOpacity=".12" strokeWidth="1" /></pattern></defs>
          {[0, .5, 1].map(ratio => <line key={ratio} x1="0" x2={WIDTH} y1={y(max * ratio)} y2={y(max * ratio)} stroke="var(--border-dim)" strokeDasharray="3 5" vectorEffect="non-scaling-stroke" />)}
          {series.map((b, index) => {
            const left = x(index) - step * .36;
            const width = step * .72;
            if (!b.counts) return <rect key={b.timestamp} x={left} y="0" width={width} height={HEIGHT} fill={`url(#${id}-gap)`} />;
            const c = b.counts;
            const value = metricValue(c, metric);
            if (metric === "requests") {
              const other = c.requests - c.completed - c.capacity_rejected;
              return <g key={b.timestamp} opacity={selected === null || selected === index ? 1 : .6}>
                <rect x={left} y={y(c.requests)} width={width} height={HEIGHT * other / max} fill="var(--text-tertiary)" opacity=".5" />
                <rect x={left} y={y(c.completed + c.capacity_rejected)} width={width} height={HEIGHT * c.capacity_rejected / max} fill="var(--accent-amber)" />
                <rect x={left} y={y(c.completed)} width={width} height={HEIGHT * c.completed / max} fill="var(--accent-brand)" />
              </g>;
            }
            return <rect key={b.timestamp} x={left} y={y(value)} width={width} height={HEIGHT * value / max} fill={metric === "capacity_rejected" ? "var(--accent-amber)" : "var(--accent-brand)"} opacity={selected === null || selected === index ? 1 : .6} />;
          })}
          {selected !== null && <line x1={x(selected)} x2={x(selected)} y1="0" y2={HEIGHT} stroke="var(--text-secondary)" strokeDasharray="3 3" vectorEffect="non-scaling-stroke" />}
        </svg>
      </div>
      <div className="absolute bottom-0 left-14 right-1 h-5 text-[11px] text-text-tertiary" aria-hidden="true">
        {ticks.map((index, position) => <span key={index} className={`absolute whitespace-nowrap ${position === 1 ? "hidden -translate-x-1/2 sm:block" : ""} ${position === 2 ? "-translate-x-full" : ""}`} style={{ left: `${100 * x(index) / WIDTH}%` }}>{bucketTick(series.at(index)!.timestamp, bucketSeconds)}</span>)}
      </div>
    </div>
    <p id={`${id}-help`} className="sr-only">Left and right arrows inspect intervals. Home selects the first and End selects the last. Hatched intervals are not published and are not zero values.</p>
  </div>;
}

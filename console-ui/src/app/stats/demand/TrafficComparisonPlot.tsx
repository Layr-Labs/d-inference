import { useId, useMemo, useRef, useState } from "react";
import { formatCompactNumber } from "../format";
import { bucketLabel, bucketTick } from "./history";
import { buildTrafficComparison, trafficShare } from "./traffic";
import type { ModelDemandResponse } from "./types";

const WIDTH = 900;
const HEIGHT = 190;

export function TrafficComparisonPlot({ data, names, onModelChange }: { data: ModelDemandResponse; names: Map<string, string>; onModelChange: (id: string) => void }) {
  const { groups, intervals } = useMemo(() => buildTrafficComparison(data), [data]);
  const [selected, setSelected] = useState<number | null>(null);
  const graphic = useRef<SVGSVGElement>(null);
  const id = useId();
  const total = groups.reduce((sum, group) => sum + group.requests, 0);
  const max = Math.max(1, ...intervals.map(bucket => bucket.total ?? 0));
  const step = WIDTH / Math.max(1, intervals.length);
  const x = (index: number) => (index + .5) * step;
  const y = (value: number) => HEIGHT * (1 - value / max);
  const active = selected === null ? null : intervals[selected];
  const groupName = (index: number) => groups[index].id === "" ? `Other models (${groups[index].models.length})` : names.get(groups[index].id) || groups[index].id;
  function selectAt(clientX: number) {
    const rect = graphic.current?.getBoundingClientRect();
    if (rect?.width) setSelected(Math.max(0, Math.min(intervals.length - 1, Math.floor((clientX - rect.left) / rect.width * intervals.length))));
  }
  return <>
    <div className="min-h-16 text-xs leading-5 text-text-secondary" role="status" aria-live="polite" aria-atomic="true">
      {active ? <>
        <p className="font-medium text-text-primary">{bucketLabel(active.timestamp, data.bucket_seconds)}</p>
        <p className="mt-1">{active.total === null ? "Interval not published. This is not a measured zero." : `${active.total.toLocaleString()} published requests · ${active.publishedModels} of ${data.models.length} listed models have published observations.`}</p>
      </> : <p>Each color is a model. Hover, tap, or use the arrow keys to inspect an interval.</p>}
    </div>
    <div role="group" aria-label="Published requests by model over time" aria-describedby={`${id}-help`} tabIndex={0}
      onFocus={() => setSelected(current => current ?? 0)} onBlur={() => setSelected(null)}
      onPointerMove={event => selectAt(event.clientX)} onPointerDown={event => selectAt(event.clientX)}
      onPointerLeave={event => { if (event.pointerType !== "touch") setSelected(null); }}
      onKeyDown={event => {
        if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
        event.preventDefault();
        if (event.key === "Home") setSelected(0);
        else if (event.key === "End") setSelected(intervals.length - 1);
        else setSelected(current => Math.max(0, Math.min(intervals.length - 1, (current ?? 0) + (event.key === "ArrowRight" ? 1 : -1))));
      }} className="relative h-60 rounded focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent-brand">
      <div className="pointer-events-none absolute bottom-7 left-0 top-2 w-11 text-right text-[11px] tabular-nums text-text-tertiary" aria-hidden="true">{[0, .5, 1].map(ratio => <span key={ratio} className="absolute right-0 -translate-y-1/2" style={{ top: `${100 * (1 - ratio)}%` }}>{formatCompactNumber(max * ratio)}</span>)}</div>
      <div className="absolute bottom-7 left-14 right-1 top-2">
        <svg ref={graphic} viewBox={`0 0 ${WIDTH} ${HEIGHT}`} preserveAspectRatio="none" className="h-full w-full" aria-hidden="true">
          <defs><pattern id={`${id}-gap`} width="8" height="8" patternUnits="userSpaceOnUse"><path d="M0 8L8 0" stroke="var(--text-tertiary)" strokeOpacity=".18" /></pattern></defs>
          {[0, .5, 1].map(ratio => <line key={ratio} x1="0" x2={WIDTH} y1={y(max * ratio)} y2={y(max * ratio)} stroke="var(--border-dim)" strokeDasharray="3 5" vectorEffect="non-scaling-stroke" />)}
          {intervals.map((bucket, index) => {
            const left = x(index) - step * .36;
            const width = step * .72;
            if (bucket.total === null) return <rect key={bucket.timestamp} x={left} y="0" width={width} height={HEIGHT} fill={`url(#${id}-gap)`} />;
            let height = 0;
            return <g key={bucket.timestamp} opacity={selected === null || selected === index ? 1 : .55}>
              {bucket.values.map((value, group) => {
                if (value.requests === null) return null;
                height += value.requests;
                return <rect key={groups[group].id} x={left} y={y(height)} width={width} height={HEIGHT * value.requests / max} fill={groups[group].color} />;
              })}
              {bucket.publishedModels < data.models.length && <line x1={left} x2={left + width} y1={Math.max(1, y(bucket.total) - 3)} y2={Math.max(1, y(bucket.total) - 3)} stroke="var(--text-primary)" strokeDasharray="2 3" vectorEffect="non-scaling-stroke" />}
            </g>;
          })}
          {selected !== null && <line x1={x(selected)} x2={x(selected)} y1="0" y2={HEIGHT} stroke="var(--text-secondary)" strokeDasharray="3 3" vectorEffect="non-scaling-stroke" />}
        </svg>
      </div>
      <div className="absolute bottom-0 left-14 right-1 h-5 text-[11px] text-text-tertiary" aria-hidden="true">{[0, Math.floor(intervals.length / 2), intervals.length - 1].map((index, position) => <span key={index} className={`absolute whitespace-nowrap ${position === 1 ? "hidden -translate-x-1/2 sm:block" : ""} ${position === 2 ? "-translate-x-full" : ""}`} style={{ left: `${100 * x(index) / WIDTH}%` }}>{bucketTick(intervals[index].timestamp, data.bucket_seconds)}</span>)}</div>
    </div>
    <ul aria-label="Model traffic legend" className="mt-4 grid gap-x-6 gap-y-2 sm:grid-cols-2">
      {groups.map((group, index) => {
        const value = active?.values[index];
        const count = active ? value?.requests : group.requests;
        const label = count === null || count === undefined ? "Not published" : count.toLocaleString();
        return <li key={group.id} className="flex min-w-0 items-start gap-2 text-xs leading-5"><span className="mt-1 h-2.5 w-2.5 shrink-0 rounded-sm" style={{ backgroundColor: group.color }} /><span className="min-w-0 flex-1">{group.id === "" ? <span className="text-text-secondary">{groupName(index)}</span> : <button type="button" onClick={() => onModelChange(group.id)} className="text-left text-text-secondary underline-offset-4 hover:text-text-primary hover:underline">{groupName(index)}</button>}<span className="ml-2 tabular-nums text-text-primary">{label}{!active && ` · ${trafficShare(group.requests, total)}`}</span>{value && value.publishedModels > 0 && value.publishedModels < value.listedModels && <span className="ml-2 text-text-tertiary">({value.publishedModels}/{value.listedModels} models published)</span>}</span></li>;
      })}
    </ul>
    <p id={`${id}-help`} className="mt-4 text-xs leading-5 text-text-tertiary">Shares use published requests only. Hatching means no listed model published in that interval; a dashed cap means only some listed models published. Neither indicates zero traffic. Four leading models are shown individually; the rest are grouped.</p>
  </>;
}

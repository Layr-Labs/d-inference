"use client";

import { useId, useRef, useState } from "react";
import { formatCompactNumber } from "../format";
import { formatTrafficTimestamp } from "../traffic-series";
import type { TimeSeriesBucket, TrafficRange } from "../types";
import { PLOT, plotScale, plotValues, type TrafficMetric, type TrafficView } from "./chart-math";

export function TrafficPlot({ data, metric, view, range }: { data: TimeSeriesBucket[]; metric: TrafficMetric; view: TrafficView; range: TrafficRange }) {
  const [hoverIndex, setHoverIndex] = useState<number | null>(null);
  const graphic = useRef<SVGSVGElement>(null);
  const id = useId();
  const points = plotValues(data, metric, view);
  const max = plotScale(points.map((point) => point.value));
  const step = PLOT.width / Math.max(points.length, 1);
  const x = (index: number) => (index + 0.5) * step;
  const y = (value: number) => PLOT.height * (1 - value / max);
  const line = points.map((point, index) => `${index ? "L" : "M"}${x(index)} ${y(point.value)}`).join(" ");
  const activeIndex = hoverIndex === null ? null : Math.min(points.length - 1, hoverIndex);
  const active = activeIndex === null ? null : points.at(activeIndex);
  const ticks = [0, Math.floor((points.length - 1) / 2), points.length - 1]
    .filter((index, position, all) => index >= 0 && all.indexOf(index) === position);

  function selectAt(clientX: number) {
    const rect = graphic.current?.getBoundingClientRect();
    if (!rect || rect.width <= 0 || !points.length) return;
    const index = Math.floor(((clientX - rect.left) / rect.width) * points.length);
    setHoverIndex(Math.max(0, Math.min(points.length - 1, index)));
  }

  return (
    <div>
      <div role="status" aria-live="polite" aria-atomic="true" className="mb-3 flex min-h-6 flex-wrap items-center justify-between gap-2 text-xs text-text-secondary">
        <p>
          {active ? <>
            {formatTrafficTimestamp(active.timestamp, range)}
            {view === "cumulative" && <span className="sr-only">, cumulative total</span>}
            <span className="ml-2 font-medium tabular-nums text-text-primary">{active.value.toLocaleString()} {metric}</span>
          </> : "Select a point to inspect activity"}
        </p>
        {metric === "tokens" && <div className="flex gap-4">
          <span className="flex items-center gap-1.5"><i aria-hidden="true" className="h-2 w-2 rounded-sm bg-accent-brand" />Input{active ? ` ${formatCompactNumber(active.input)}` : ""}</span>
          <span className="flex items-center gap-1.5"><i aria-hidden="true" className="h-2 w-2 rounded-sm bg-blue" />Output{active ? ` ${formatCompactNumber(active.output)}` : ""}</span>
        </div>}
      </div>
      <div
        role="group"
        aria-label={`${metric === "requests" ? "Requests" : "Tokens"} traffic chart`}
        aria-describedby={`${id}-help`}
        tabIndex={0}
        className="relative h-[210px] rounded-lg outline-offset-4 sm:h-[260px]"
        onPointerMove={(event) => selectAt(event.clientX)}
        onPointerLeave={(event) => { if (event.currentTarget !== document.activeElement) setHoverIndex(null); }}
        onClick={(event) => selectAt(event.clientX)}
        onFocus={() => setHoverIndex(points.length - 1)}
        onBlur={() => setHoverIndex(null)}
        onKeyDown={(event) => {
          if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
          event.preventDefault();
          if (event.key === "Home") setHoverIndex(0);
          else if (event.key === "End") setHoverIndex(points.length - 1);
          else setHoverIndex((index) => Math.max(0, Math.min(points.length - 1, (index ?? points.length - 1) + (event.key === "ArrowLeft" ? -1 : 1))));
        }}
      >
        {/* Axis text stays in CSS pixels; only the data geometry stretches. */}
        <div className="pointer-events-none absolute bottom-8 left-0 top-2 w-10 text-right text-[11px] tabular-nums text-text-tertiary" aria-hidden="true">
          {[0, .5, 1].map((ratio) => (
            <span key={ratio} className="absolute right-0 -translate-y-1/2" style={{ top: `${(1 - ratio) * 100}%` }}>
              {formatCompactNumber(max * ratio)}
            </span>
          ))}
        </div>
        <div className="absolute bottom-8 left-12 right-1 top-2">
          <svg ref={graphic} viewBox={`0 0 ${PLOT.width} ${PLOT.height}`} className="h-full w-full overflow-visible" preserveAspectRatio="none" aria-hidden="true">
            <defs>
              <linearGradient id={id} x1="0" x2="0" y1="0" y2="1">
                <stop offset="0%" stopColor="var(--accent-brand)" stopOpacity=".14" />
                <stop offset="100%" stopColor="var(--accent-brand)" stopOpacity="0" />
              </linearGradient>
            </defs>
            {[0, .5, 1].map((ratio) => (
              <line key={ratio} x1="0" x2={PLOT.width} y1={y(max * ratio)} y2={y(max * ratio)} stroke="var(--border-dim)" strokeDasharray={ratio ? "3 5" : undefined} vectorEffect="non-scaling-stroke" />
            ))}
            {metric === "requests" && points.length > 0 && <>
              <path d={`${line} L${x(points.length - 1)} ${PLOT.height} L${x(0)} ${PLOT.height} Z`} fill={`url(#${id})`} />
              <path d={line} fill="none" stroke="var(--accent-brand)" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
            </>}
            {metric === "tokens" && points.map((point, index) => (
              <g key={point.timestamp} opacity={activeIndex === null || activeIndex === index ? 1 : .5}>
                <rect x={x(index) - step * .34} y={y(point.value)} width={step * .68} height={point.input / max * PLOT.height} fill="var(--accent-brand)" rx="1.5" />
                <rect x={x(index) - step * .34} y={y(point.output)} width={step * .68} height={point.output / max * PLOT.height} fill="var(--blue)" rx="1.5" />
              </g>
            ))}
            {active && activeIndex !== null && (
              <line x1={x(activeIndex)} x2={x(activeIndex)} y1="0" y2={PLOT.height} stroke="var(--text-tertiary)" strokeDasharray="3 4" vectorEffect="non-scaling-stroke" />
            )}
          </svg>
          {active && activeIndex !== null && metric === "requests" && (
            <span aria-hidden="true" className="pointer-events-none absolute h-2.5 w-2.5 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-bg-white bg-accent-brand" style={{ left: `${x(activeIndex) / PLOT.width * 100}%`, top: `${y(active.value) / PLOT.height * 100}%` }} />
          )}
        </div>
        <div className="pointer-events-none absolute bottom-0 left-12 right-1 h-5 text-[11px] text-text-tertiary" aria-hidden="true">
          {ticks.map((index, position) => {
            let alignment = "-translate-x-1/2";
            if (position === 0) alignment = "";
            else if (position === ticks.length - 1) alignment = "-translate-x-full";
            const isMiddle = position > 0 && position < ticks.length - 1;
            return (
              <span key={index} className={`absolute whitespace-nowrap ${alignment} ${isMiddle ? "hidden sm:inline" : ""}`} style={{ left: `${x(index) / PLOT.width * 100}%` }}>
                {formatTrafficTimestamp(points.at(index)!.timestamp, range)}
              </span>
            );
          })}
        </div>
      </div>
      <p id={`${id}-help`} className="sr-only">Use the left and right arrow keys to inspect each bucket. Home selects the first bucket and End selects the latest.</p>
    </div>
  );
}

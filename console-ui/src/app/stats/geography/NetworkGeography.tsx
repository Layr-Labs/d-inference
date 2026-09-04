"use client";

import { useMemo, useState } from "react";
import { ArrowUpRight, ChevronDown, MapPin, Move, ShieldCheck } from "lucide-react";
import { WorldDotMatrix, ZoomableMapViewport } from "@/components/stats/network-map";
import type { PlatformStats } from "../platform-types";
import { GeographyMarkers } from "./GeographyMarkers";
import { buildGeographyData, formatGeoCount, type GeographyMode } from "./geography-data";

export function NetworkGeography({ stats }: { stats: PlatformStats }) {
  const [mode, setMode] = useState<GeographyMode>("providers");
  const [exploring, setExploring] = useState(false);
  const data = useMemo(() => buildGeographyData(stats, mode), [stats, mode]);
  const leaders = data.regions.slice(0, 5);
  const leaderMaximum = leaders[0]?.value || 1;
  const mapScope = data.mapScope === "city" ? "city locations" : "regional locations";
  const mapLocationLabel = `${data.omittedPlaces > 0 ? "Largest " : ""}${data.markers.length} ${mapScope}`;

  return (
    <section aria-labelledby="network-geography-title" className="overflow-hidden rounded-2xl border border-border-dim bg-bg-white">
      <div className="flex flex-col justify-between gap-4 px-5 pt-5 sm:flex-row sm:items-center sm:px-7 sm:pt-6">
        <div>
          <h2 id="network-geography-title" className="text-base font-semibold tracking-[-0.02em] text-text-primary">Network geography</h2>
          <p className="mt-1 text-sm text-text-secondary">
            {mode === "providers" ? "Where the network is connected." : "Where requests originate."}
          </p>
        </div>
        <div className="inline-flex w-fit items-center rounded-lg bg-bg-secondary p-1" role="group" aria-label="Map view">
          {(["providers", "requests"] as const).map((option) => (
            <button
              key={option}
              type="button"
              aria-pressed={option === mode}
              onClick={() => { setMode(option); setExploring(false); }}
              className={`min-h-9 rounded-md px-4 text-[13px] font-medium transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand ${option === mode ? "bg-bg-white text-text-primary shadow-sm" : "text-text-secondary hover:text-text-primary"}`}
            >
              {option === "providers" ? "Providers" : "Requests"}
            </button>
          ))}
        </div>
      </div>

      <div className="grid min-w-0 items-center lg:grid-cols-[minmax(0,1fr)_244px] xl:grid-cols-[minmax(0,1fr)_260px]">
        <div className="relative min-w-0 px-2 pb-3 pt-6 sm:px-4 lg:py-4">
          <ZoomableMapViewport
            key={mode}
            interactive={exploring && data.markers.length > 0}
            hint="Drag to pan. Scroll to zoom."
            className="relative aspect-[2/1] min-w-0 overflow-hidden rounded-xl"
            style={{ backgroundColor: "var(--bg-white)" }}
          >
            {(context) => (
              <>
                <WorldDotMatrix className="absolute inset-0 h-full w-full" dotRadius={1.45} spacing={7} graticule={false} />
                <GeographyMarkers markers={data.markers} mode={mode} context={context} onExplore={() => setExploring(true)} />
                {data.markers.length === 0 && (
                  <div className="absolute inset-0 flex items-center justify-center px-6">
                    <div className="max-w-xs rounded-xl border border-border-dim bg-bg-white/95 px-5 py-4 text-center">
                      <MapPin size={18} className="mx-auto mb-2 text-text-tertiary" />
                      <p className="text-sm font-medium text-text-primary">No public locations yet</p>
                      <p className="mt-1 text-xs leading-relaxed text-text-secondary">{mode === "providers" ? "Locations appear when connected providers meet the privacy threshold." : "Locations appear as requests meet the privacy threshold."}</p>
                    </div>
                  </div>
                )}
              </>
            )}
          </ZoomableMapViewport>
          <div className="mt-1 flex min-h-9 items-center justify-between gap-3 px-3 sm:px-4">
            <p className="text-xs text-text-tertiary">
              {data.markers.length > 0 ? mapLocationLabel : "Approximate locations"}
            </p>
            {data.markers.length > 0 && (
              <button
                type="button"
                aria-pressed={exploring}
                onClick={() => setExploring(!exploring)}
                className="inline-flex min-h-9 shrink-0 items-center gap-2 rounded-md px-2 text-xs font-medium text-text-secondary transition-colors hover:bg-bg-secondary hover:text-text-primary focus-visible:outline-2 focus-visible:outline-accent-brand"
              >
                {exploring ? "Done exploring" : "Explore map"}
                {exploring ? <Move size={13} /> : <ArrowUpRight size={14} />}
              </button>
            )}
          </div>
        </div>

        <div className="mx-5 border-t border-border-dim pb-6 pt-5 sm:mx-7 lg:my-7 lg:ml-0 lg:border-l lg:border-t-0 lg:py-0 lg:pl-6">
          <p className="text-xs text-text-secondary">{data.period}</p>
          <div className="mt-1 flex items-baseline gap-2.5">
            <span className="text-[34px] leading-tight font-medium tracking-[-0.055em] text-text-primary tabular-nums">{formatGeoCount(data.total)}</span>
            <span className="text-[13px] text-text-secondary">{data.hasRegionTotals ? "located" : "published"} {mode}</span>
          </div>
          <p className="mt-1 text-xs text-text-tertiary">Across {data.countries.toLocaleString()} {data.countries === 1 ? "country" : "countries"}</p>
          <div className="mt-6 flex justify-between text-xs text-text-secondary">
            <h3>Top {data.hasRegionTotals ? "regions" : "cities"}</h3>
            <span>{mode === "providers" ? "Providers" : "Requests"}</span>
          </div>
          {leaders.length > 0 ? (
            <ol className="mt-3 space-y-3.5">
              {leaders.map((place) => (
                <li key={place.key}>
                  <div className="flex items-baseline justify-between gap-4 text-[13px]">
                    <span className="truncate text-text-primary" title={`${place.label}, ${place.country}`}>
                      {place.label}{place.label !== place.country && place.countryCode ? `, ${place.countryCode}` : ""}
                    </span>
                    <span className="shrink-0 font-medium tabular-nums text-text-primary">{formatGeoCount(place.value)}</span>
                  </div>
                  <div className="mt-1.5 h-[3px] overflow-hidden rounded-full bg-bg-secondary" aria-hidden="true">
                    <div className="h-full rounded-full bg-accent-brand/55 transition-[width] duration-300 motion-reduce:transition-none" style={{ width: `${(place.value / leaderMaximum) * 100}%` }} />
                  </div>
                </li>
              ))}
            </ol>
          ) : <p className="mt-4 text-sm text-text-tertiary">No regional data available.</p>}
        </div>
      </div>

      <details className="group border-t border-border-dim px-5 py-3.5 text-xs text-text-secondary sm:px-7">
        <summary className="flex list-none items-start gap-3 leading-relaxed [&::-webkit-details-marker]:hidden">
          <ShieldCheck size={14} className="shrink-0 text-text-tertiary" />
          <span className="min-w-0 flex-1">Approximate locations. City groups need {data.privacyMinimum}+ {mode}.</span>
          <span className="hidden shrink-0 text-text-tertiary underline decoration-border-dim underline-offset-4 sm:inline">How this works</span><ChevronDown size={14} className="mt-0.5 shrink-0 text-text-tertiary transition-transform group-open:rotate-180" />
        </summary>
        <div className="mt-3 max-w-3xl space-y-2 pl-[26px] leading-relaxed">
          <p>{mode === "providers" ? "Provider locations reflect connected machines, including machines that may not currently accept requests." : `Request origins cover ${data.period.toLowerCase()}. They do not identify the provider that served a request.`} Map markers group nearby published locations when zoomed out.</p>
          <p>{data.unknown.toLocaleString()} {mode} without a resolved location. {data.suppressed.toLocaleString()} {mode} below the city privacy threshold{data.hasRegionTotals ? "; included in regional totals" : ""}.</p>
          {data.omittedPlaces > 0 && <p>The map shows the {data.markers.length} largest published locations. Regional totals include all published locations.</p>}
        </div>
      </details>
    </section>
  );
}

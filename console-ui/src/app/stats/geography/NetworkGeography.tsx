"use client";

import { useMemo, useState } from "react";
import { MapPin } from "lucide-react";
import type { PlatformStats } from "../platform-types";
import { GeographyContent } from "./GeographyContent";
import { GeographyNotice } from "./GeographyNotice";
import { buildGeographyData, type GeographyMode } from "./geography-data";

export function NetworkGeography({ stats }: { stats: PlatformStats }) {
  const [mode, setMode] = useState<GeographyMode>("providers");
  const [exploring, setExploring] = useState(false);
  const data = useMemo(() => buildGeographyData(stats, mode), [stats, mode]);
  const locationsUnavailable = stats.request_locations_status === "unavailable";
  const flowsUnavailable = stats.request_flows_status === "unavailable";
  const unavailable = mode === "requests" && locationsUnavailable;

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

      <GeographyNotice locationsUnavailable={locationsUnavailable} flowsUnavailable={flowsUnavailable} />
      {unavailable ? (
        <div className="flex min-h-64 flex-col items-center justify-center px-6 py-12 text-center">
          <MapPin size={24} className="mb-3 text-text-tertiary" aria-hidden="true" />
          <p className="text-sm font-medium text-text-primary">Request map unavailable</p>
          <p className="mt-2 max-w-sm text-sm text-text-secondary">Location totals will appear when geography data recovers.</p>
        </div>
      ) : (
        <GeographyContent data={data} exploring={exploring} onExploringChange={setExploring} />
      )}
    </section>
  );
}

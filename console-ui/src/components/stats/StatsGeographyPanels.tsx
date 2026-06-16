"use client";

import { useState } from "react";
import { statsCapacityGrid } from "./styles";

export interface RequestLocationBucketView {
  key: string;
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  requests: number;
  prompt_tokens: number;
  completion_tokens: number;
  providers: number;
}

interface StatsRequestGeographyLeaderboardProps {
  cityBuckets: RequestLocationBucketView[];
  regionBuckets: RequestLocationBucketView[];
  maxCityRequests: number;
  maxRegionRequests: number;
  formatPlace: (bucket: RequestLocationBucketView) => string;
  formatNumber: (n: number) => string;
}

export function StatsRequestGeographyLeaderboard({
  cityBuckets,
  regionBuckets,
  maxCityRequests,
  maxRegionRequests,
  formatPlace,
  formatNumber,
}: StatsRequestGeographyLeaderboardProps) {
  const [scope, setScope] = useState<"city" | "region">("city");
  const buckets = scope === "city" ? cityBuckets : regionBuckets;
  const maxRequests = scope === "city" ? maxCityRequests : maxRegionRequests;
  const emptyMessage =
    scope === "city"
      ? "No city-level demand buckets yet."
      : "No demand regions resolved yet.";

  return (
    <div className="flex min-h-full flex-col overflow-hidden rounded-[0.35rem] border border-border-dim bg-bg-secondary shadow-sm">
      <div className="flex items-center justify-between gap-3 border-b border-border-dim bg-bg-primary px-3.5 py-2.5">
        <p className="font-mono text-[0.58rem] tracking-[0.16em] uppercase text-text-tertiary">
          Top demand
        </p>
        <div
          className="inline-flex gap-0.5 rounded border border-border-dim bg-bg-secondary p-0.5"
          role="tablist"
          aria-label="Demand scope"
        >
          {(["city", "region"] as const).map((value) => {
            const active = scope === value;
            return (
              <button
                key={value}
                type="button"
                role="tab"
                aria-selected={active}
                className={`min-h-6.5 rounded px-2.5 font-mono text-[0.62rem] tracking-wide uppercase transition-colors ${
                  active
                    ? "bg-accent-brand-dim text-accent-brand"
                    : "text-text-tertiary hover:text-text-primary"
                }`}
                onClick={() => setScope(value)}
              >
                {value === "city" ? "Cities" : "Regions"}
              </button>
            );
          })}
        </div>
      </div>

      {buckets.length === 0 ? (
        <p className="px-3.5 py-5 text-[0.82rem] text-text-tertiary">{emptyMessage}</p>
      ) : (
        <ol className="m-0 list-none flex-1 p-0.5">
          {buckets.map((bucket, index) => {
            const tokens = bucket.prompt_tokens + bucket.completion_tokens;
            const barPct = maxRequests > 0
              ? Math.max(6, (bucket.requests / maxRequests) * 100)
              : 0;
            const rankLabel = (index + 1).toString().padStart(2, "0");

            return (
              <li
                key={bucket.key}
                className="grid grid-cols-[1.6rem_minmax(0,1fr)] items-start gap-2 border-b border-border-dim px-3.5 py-2 last:border-b-0"
              >
                <span className="pt-0.5 font-mono text-[0.64rem] font-bold tracking-wide text-accent-brand" aria-hidden="true">
                  {rankLabel}
                </span>
                <div className="min-w-0">
                  <div className="flex items-baseline justify-between gap-2.5">
                    <p className="min-w-0 truncate text-[0.8rem] font-semibold text-text-primary" title={formatPlace(bucket)}>
                      {formatPlace(bucket)}
                    </p>
                    <p className="shrink-0 font-mono text-[0.82rem] font-bold tracking-tight text-text-primary whitespace-nowrap">
                      {formatNumber(bucket.requests)}
                      <span className="ml-1 text-[0.56rem] font-medium tracking-widest uppercase text-text-tertiary">
                        req
                      </span>
                    </p>
                  </div>
                  <div className="mt-1.5 h-0.5 overflow-hidden rounded-full bg-bg-elevated" aria-hidden="true">
                    <span
                      className="block h-full rounded-full bg-linear-to-r from-accent-brand to-accent-green transition-[width] duration-500"
                      style={{ width: `${barPct}%` }}
                    />
                  </div>
                  <p className="mt-1 truncate font-mono text-[0.62rem] text-text-secondary">
                    {formatNumber(tokens)} tokens
                    <span className="mx-1 text-text-tertiary">·</span>
                    {formatNumber(bucket.prompt_tokens)} in
                    <span className="mx-1 text-text-tertiary">/</span>
                    {formatNumber(bucket.completion_tokens)} out
                    {bucket.providers > 0 && (
                      <>
                        <span className="mx-1 text-text-tertiary">·</span>
                        {bucket.providers} nodes
                      </>
                    )}
                  </p>
                </div>
              </li>
            );
          })}
        </ol>
      )}
    </div>
  );
}

export interface ProviderLocationBucketView {
  key: string;
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  providers: number;
  hardware_attested: number;
  gpu_cores: number;
  memory_gb: number;
}

export function StatsProviderCapacityTable({
  buckets,
  formatPlace,
  formatNumber,
  emptyMessage,
}: {
  buckets: ProviderLocationBucketView[];
  formatPlace: (bucket: ProviderLocationBucketView) => string;
  formatNumber: (n: number) => string;
  emptyMessage: string;
}) {
  if (buckets.length === 0) {
    return <p className="text-sm text-text-tertiary">{emptyMessage}</p>;
  }

  return (
    <div className="overflow-hidden rounded-[0.35rem] border border-border-dim bg-bg-primary shadow-sm">
      <div className={`${statsCapacityGrid} border-b border-border-dim bg-bg-secondary font-mono text-[0.56rem] tracking-[0.14em] uppercase text-text-tertiary`} aria-hidden="true">
        <span>Location</span>
        <span className="text-right">Nodes</span>
        <span className="text-right">Attested</span>
        <span className="text-right">GPU</span>
        <span className="text-right">RAM</span>
      </div>
      {buckets.map((bucket) => {
        const attestedPct = bucket.providers > 0
          ? Math.round((bucket.hardware_attested / bucket.providers) * 100)
          : 0;
        return (
          <div
            key={bucket.key}
            className={`${statsCapacityGrid} border-b border-border-dim font-mono text-[0.72rem] last:border-b-0 hover:bg-accent-brand-dim/35`}
          >
            <span className="min-w-0 truncate font-sans text-[0.8rem] font-semibold text-text-primary" title={formatPlace(bucket)}>
              {formatPlace(bucket)}
            </span>
            <span className="text-right font-semibold text-text-primary">{bucket.providers}</span>
            <span className="text-right font-semibold text-text-primary">{attestedPct}%</span>
            <span className="text-right font-semibold text-text-primary">{bucket.gpu_cores}</span>
            <span className="text-right text-[0.68rem] font-semibold whitespace-nowrap text-text-primary">
              {formatNumber(bucket.memory_gb)} GB
            </span>
          </div>
        );
      })}
    </div>
  );
}

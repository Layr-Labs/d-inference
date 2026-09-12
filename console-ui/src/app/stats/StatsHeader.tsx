"use client";

import { useEffect, useState } from "react";
import { Clock3, RefreshCw } from "lucide-react";

export function StatsHeader({ snapshotAt, fetchedAt, hasSnapshot, refreshing, error, onRefresh }: {
  snapshotAt: string | null; fetchedAt: string | null; hasSnapshot: boolean;
  refreshing: boolean; error: string | null; onRefresh: () => void;
}) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  const timestamp = snapshotAt || fetchedAt;
  const age = timestamp ? Math.max(0, Math.floor((now - Date.parse(timestamp)) / 1000)) : null;
  const sourceStale = snapshotAt !== null && age !== null && age >= 30;
  const elapsed = age !== null && age < 60 ? `${age}s` : `${Math.floor((age ?? 0) / 60)}m`;
  let freshness = hasSnapshot ? "Snapshot time unavailable" : "Loading network data";
  if (timestamp) freshness = `${snapshotAt ? "Snapshot" : "Fetched"} ${elapsed} ago`;
  if (sourceStale) freshness += " (stale)";
  if (error && !timestamp) freshness = "Snapshot unavailable";

  return (
    <header className="flex flex-wrap items-end justify-between gap-5 pb-7 pt-8 sm:pt-10">
      <div>
        <h1 className="font-logo text-[42px] font-normal leading-tight tracking-[-0.035em] text-ink sm:text-5xl">The Darkbloom network</h1>
        <p className="mt-3 max-w-xl text-sm leading-relaxed text-text-secondary">Explore the Macs, models, and activity behind private inference.</p>
      </div>
      <div className="flex items-center gap-4">
        <div className="text-right">
          <p className={`flex items-center justify-end gap-1.5 text-xs ${error || sourceStale ? "text-accent-amber" : "text-text-secondary"}`} title={timestamp ? `${snapshotAt ? "Source snapshot" : "Fetched from coordinator"}: ${new Date(timestamp).toLocaleString()}` : undefined}><Clock3 size={13} />{freshness}</p>
          <p className="mt-1 text-[11px] text-text-tertiary">Refreshes every 30 seconds</p>
        </div>
        <button type="button" onClick={onRefresh} disabled={refreshing} aria-label="Refresh network stats" title="Check for the latest cached snapshot" className="flex h-10 w-10 items-center justify-center rounded-lg border border-border-dim bg-bg-white text-text-secondary transition-colors hover:bg-bg-secondary disabled:cursor-wait disabled:opacity-50"><RefreshCw size={16} className={refreshing ? "motion-safe:animate-spin" : ""} /></button>
      </div>
    </header>
  );
}

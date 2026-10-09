"use client";

// Top bar of the dashboard: a "Fleet" heading with a live-data pulse, a
// locally-ticking "updated Ns ago" freshness counter (turns amber if the last
// poll failed so the Live label never lies), a manual Refresh, and a fleet
// update chip when any machine is below the minimum version.

import { useEffect, useState } from "react";
import { ArrowUpCircle, RefreshCw } from "lucide-react";

export function DashboardHeader({
  total,
  online,
  latestVersion,
  refreshing,
  onRefresh,
  lastUpdatedAt,
  pollFailed,
  updateAvailable,
}: {
  total: number;
  online: number;
  latestVersion: string;
  refreshing: boolean;
  onRefresh: () => void;
  lastUpdatedAt: number | null;
  pollFailed: boolean;
  updateAvailable: boolean;
}) {
  // Tick the "updated Ns ago" counter once a second. Time is read inside the
  // interval (never during render) so the component stays pure.
  const [agoSec, setAgoSec] = useState<number | null>(null);
  useEffect(() => {
    const compute = () =>
      setAgoSec(lastUpdatedAt ? Math.max(0, Math.floor((Date.now() - lastUpdatedAt) / 1000)) : null);
    compute();
    const id = setInterval(compute, 1000);
    return () => clearInterval(id);
  }, [lastUpdatedAt]);

  return (
    <div className="flex items-start sm:items-center justify-between gap-3 flex-wrap">
      <div>
        <h2 className="text-xl font-bold text-text-primary">Fleet</h2>
        <p className="text-xs font-mono text-text-tertiary mt-0.5">
          {online}/{total} machine{total === 1 ? "" : "s"} online
          {latestVersion ? ` · v${latestVersion}` : ""}
        </p>
      </div>

      <div className="flex items-center gap-3">
        {updateAvailable && (
          <span className="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-accent-amber/10 text-accent-amber text-[11px] font-medium">
            <ArrowUpCircle size={12} /> Update available
          </span>
        )}
        <div className="flex items-center gap-1.5">
          <span className="relative flex h-2 w-2">
            {!pollFailed && (
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-accent-green opacity-60" />
            )}
            <span className={`relative inline-flex rounded-full h-2 w-2 ${pollFailed ? "bg-accent-amber" : "bg-accent-green"}`} />
          </span>
          <span className="text-xs text-text-tertiary hidden sm:inline">
            {pollFailed ? "Reconnecting" : "Live"}
          </span>
          {agoSec !== null && (
            <span className={`text-[11px] font-mono hidden md:inline ${pollFailed ? "text-accent-amber" : "text-text-tertiary"}`}>
              · updated {agoSec}s ago
            </span>
          )}
        </div>
        <button
          onClick={onRefresh}
          disabled={refreshing}
          className="focus-ring rounded-md inline-flex items-center gap-1.5 text-sm text-text-tertiary hover:text-text-primary disabled:opacity-50 transition-colors"
        >
          <RefreshCw size={14} className={refreshing ? "animate-spin" : ""} /> Refresh
        </button>
      </div>
    </div>
  );
}

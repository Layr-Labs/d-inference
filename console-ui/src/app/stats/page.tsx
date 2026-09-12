"use client";

import { useState } from "react";
import { AlertCircle, ArrowUpRight } from "lucide-react";
import Link from "next/link";
import { TopBar } from "@/components/TopBar";
import { useNetworkStats } from "./useNetworkStats";
import { StatsHeader } from "./StatsHeader";
import { StatsSkeleton } from "./StatsSkeleton";
import { NetworkSummary, NetworkResources } from "./NetworkSummary";
import { NetworkGeography } from "./geography/NetworkGeography";
import { TrafficPanel } from "./traffic/TrafficPanel";
import { ModelCapacityLandscape } from "./models/ModelCapacityLandscape";
import { HardwareComposition } from "./hardware/HardwareComposition";
import { ProviderDashboard } from "./ProviderDashboard";

export default function StatsPage() {
  const network = useNetworkStats();
  const [showDirectory, setShowDirectory] = useState(false);
  const { stats, snapshotAt, error, refreshing, refresh } = network;
  return (
    <div className="flex h-full min-h-0 flex-col">
      <TopBar title="Network stats" />
      <div className="relative min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto w-full max-w-[1320px] px-5 sm:px-9 lg:px-12">
          <StatsHeader fetchedAt={network.fetchedAt} hasSnapshot={!!stats} snapshotAt={snapshotAt} refreshing={refreshing} error={error} onRefresh={refresh} />
          {network.isMock && <p className="mt-5 rounded-lg bg-accent-amber-dim px-4 py-3 text-sm text-text-primary">Demo geography: locations and some provider fields are simulated.</p>}
          {error && <div role="alert" className="mt-5 flex flex-wrap items-center gap-3 rounded-xl border border-accent-amber/25 bg-accent-amber-dim px-4 py-3 text-sm text-text-primary"><AlertCircle size={17} className="shrink-0 text-accent-amber"/><p className="flex-1">{error} {stats ? "Showing the last available snapshot." : "Try again to load network activity."}</p><button type="button" onClick={refresh} disabled={refreshing} className="rounded px-1 py-2 font-medium text-accent-brand disabled:opacity-50">Try again</button></div>}
          {!stats ? !error && <StatsSkeleton /> : <div className="pb-10">
            <>
              <NetworkSummary stats={stats} totals24h={network.totals24h} />
              <div className="space-y-9 pb-9">
                <NetworkGeography stats={stats} />
                <TrafficPanel refreshToken={network.fetchedAt} />
                <ModelCapacityLandscape stats={stats} catalogData={network.catalogData} capacityModels={network.capacityModels} />
                <HardwareComposition stats={stats} />
              </div>
            </>
            <details className="border-t border-border-dim py-5" onToggle={(event) => setShowDirectory(event.currentTarget.open)}>
              <summary className="cursor-pointer rounded text-sm font-medium text-text-primary">Explore all {stats.providers.length.toLocaleString()} providers <span className="ml-2 text-xs font-normal text-text-tertiary">Search machines and inspect their details</span></summary>
              {showDirectory && <div className="pt-5"><ProviderDashboard providers={stats.providers} /></div>}
            </details>
            <NetworkResources stats={stats} />
            <footer className="flex flex-wrap items-center justify-between gap-4 border-t border-border-dim py-6 text-xs text-text-tertiary"><p>Refreshes every 30 seconds while visible. Older snapshots remain available during refresh failures.</p><Link href="/models" className="inline-flex items-center gap-1.5 text-text-secondary hover:text-accent-brand">Explore models <ArrowUpRight size={13}/></Link></footer>
          </div>}
        </div>
      </div>
    </div>
  );
}

"use client";

import { RefreshCw } from "lucide-react";
import { statsReveal } from "./styles";

type StatsTab = "overview" | "leaderboard";

interface StatsMastheadProps {
  activeTab: StatsTab;
  onTabChange: (tab: StatsTab) => void;
  onRefresh: () => void;
  refreshing?: boolean;
}

const TABS: Array<{ value: StatsTab; label: string }> = [
  { value: "overview", label: "Overview" },
  { value: "leaderboard", label: "Leaderboard" },
];

export function StatsMasthead({ activeTab, onTabChange, onRefresh, refreshing = false }: StatsMastheadProps) {
  return (
    <header className={`flex flex-col gap-5 ${statsReveal}`}>
      <div className="relative grid items-end gap-6 border-b-2 border-border-dim pb-5 sm:grid-cols-[1fr_auto] sm:gap-x-8">
        <div
          className="pointer-events-none absolute bottom-[-2px] left-0 h-0.5 w-[min(42%,280px)] bg-linear-to-r from-accent-brand to-accent-green"
          aria-hidden="true"
        />
        <div className="min-w-0">
          <p className="mb-2 font-mono text-[0.62rem] tracking-[0.24em] uppercase text-accent-green">
            Darkbloom network
          </p>
          <h1 className="font-logo text-[clamp(2.35rem,6vw,4rem)] leading-[0.92] tracking-[-0.035em] text-text-primary">
            Signal <em className="text-accent-brand">Observatory</em>
          </h1>
          <p className="mt-3 max-w-xl text-sm leading-snug text-text-secondary">
            Live readout of decentralized inference — capacity, demand, and trust.
          </p>
        </div>
        <div className="flex items-center gap-2.5">
          <div className="inline-flex items-center gap-2 rounded-full border border-accent-green/35 bg-accent-green-dim px-4 py-2 font-mono text-[0.62rem] tracking-[0.16em] uppercase text-accent-green">
            <span className="stats-live-dot size-1.5 rounded-full bg-accent-green" aria-hidden="true" />
            Live
          </div>
          <button
            type="button"
            onClick={onRefresh}
            disabled={refreshing}
            className="flex size-9 items-center justify-center rounded-[0.65rem] border border-border-dim bg-bg-primary text-text-tertiary transition-[border-color,color,background,transform] hover:rotate-[-24deg] hover:border-accent-brand/40 hover:bg-bg-hover hover:text-accent-brand disabled:pointer-events-none disabled:opacity-60"
            aria-label="Refresh stats"
            aria-busy={refreshing}
          >
            <RefreshCw size={14} className={refreshing ? "animate-spin" : undefined} />
          </button>
        </div>
      </div>

      <div className="flex gap-1 border-b border-border-dim" role="tablist" aria-label="Stats views">
        {TABS.map((tab) => {
          const active = activeTab === tab.value;
          return (
            <button
              key={tab.value}
              type="button"
              role="tab"
              aria-selected={active}
              onClick={() => onTabChange(tab.value)}
              className={`relative min-h-10 px-4 pb-2.5 font-mono text-[0.72rem] font-medium tracking-widest uppercase transition-colors ${
                active ? "text-accent-brand" : "text-text-tertiary hover:text-text-primary"
              }`}
            >
              {tab.label}
              {active && (
                <span
                  className="absolute right-2.5 bottom-[-1px] left-2.5 h-0.5 bg-linear-to-r from-accent-brand to-accent-green"
                  aria-hidden="true"
                />
              )}
            </button>
          );
        })}
      </div>
    </header>
  );
}

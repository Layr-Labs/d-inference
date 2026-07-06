"use client";

import { Gauge, Clock, Hash } from "lucide-react";

/** Time-to-first-token in ms or s, em-dash when absent. */
function formatTtft(ttft?: number): string {
  if (!ttft) return "\u2014";
  return ttft < 1000 ? `${Math.round(ttft)}ms` : `${(ttft / 1000).toFixed(2)}s`;
}

export function StreamMetrics({
  tps,
  ttft,
  tokenCount,
  streaming,
}: {
  tps?: number;
  ttft?: number;
  tokenCount?: number;
  streaming?: boolean;
}) {
  if (!tps && !ttft) return null;

  return (
    <div
      className={`flex items-center gap-2 sm:gap-3 mt-3 py-2 px-2 sm:px-3 rounded-lg text-xs font-mono border-2 flex-wrap ${
        streaming
          ? "bg-blue-light/30 border-blue shadow-sm"
          : "bg-bg-secondary border-border-dim"
      }`}
    >
      <span
        className={`flex items-center gap-1 ${
          streaming ? "text-blue" : "text-text-secondary"
        }`}
      >
        <Gauge size={12} />
        <span className="tabular-nums font-semibold">
          {tps ? tps.toFixed(1) : "\u2014"}
        </span>
        <span className="text-text-tertiary">tok/s</span>
      </span>

      <span className="text-border-subtle">|</span>

      <span
        className={`flex items-center gap-1 ${
          streaming ? "text-gold" : "text-text-secondary"
        }`}
      >
        <Clock size={12} />
        <span className="tabular-nums font-semibold">
          {formatTtft(ttft)}
        </span>
        <span className="text-text-tertiary">TTFT</span>
      </span>

      <span className="text-border-subtle">|</span>

      <span className="flex items-center gap-1 text-text-secondary">
        <Hash size={12} />
        <span className="tabular-nums font-semibold">
          {tokenCount || 0}
        </span>
        <span className="text-text-tertiary">tokens</span>
      </span>

      {streaming && (
        <span className="ml-auto flex items-center gap-1.5 text-blue">
          <span className="w-1.5 h-1.5 rounded-full bg-blue animate-pulse" />
          <span className="text-xs font-semibold">live</span>
        </span>
      )}
    </div>
  );
}

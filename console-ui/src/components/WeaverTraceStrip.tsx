"use client";

import type { WeaverCandidate, WeaverTrace } from "@/lib/api";

function diamondClass(candidate: WeaverCandidate, selectedCandidate?: string) {
  if (candidate.status === "failed") {
    return "border-accent-red bg-accent-red text-white";
  }
  if (candidate.id === selectedCandidate || candidate.status === "selected") {
    return "border-gold bg-gold text-white";
  }
  if (selectedCandidate && candidate.status === "done") {
    return "border-border-subtle bg-bg-tertiary text-text-tertiary opacity-60";
  }
  if (candidate.status === "done") {
    return "border-teal bg-teal text-white";
  }
  if (candidate.status === "streaming") {
    return "border-teal bg-transparent text-teal animate-pulse";
  }
  return "border-border-subtle bg-bg-tertiary text-text-tertiary opacity-60";
}

export function WeaverTraceStrip({
  weaver,
  onOpen,
}: {
  weaver: WeaverTrace;
  onOpen: (candidateId?: string) => void;
}) {
  const done = weaver.candidates.filter((c) => c.status === "done" || c.status === "selected").length;
  const failed = weaver.candidates.filter((c) => c.status === "failed").length;

  return (
    <div className="mb-3 flex flex-wrap items-center gap-2 rounded-lg border-2 border-border-dim bg-bg-secondary/60 px-3 py-2">
      <button
        type="button"
        onClick={() => onOpen()}
        className="text-left text-xs font-mono font-semibold uppercase tracking-wide text-text-secondary hover:text-coral"
      >
        {weaver.mode === "deep_plus" ? "Deep+" : "Deep"} · {weaver.status}
      </button>

      <div className="flex items-center gap-2">
        {weaver.candidates.map((candidate) => (
          <button
            key={candidate.id}
            type="button"
            aria-label={`${candidate.label} ${candidate.status}`}
            title={`${candidate.label}: ${candidate.status}`}
            onClick={() => onOpen(candidate.id)}
            className={`h-4 w-4 rotate-45 border-2 transition-all ${diamondClass(candidate, weaver.selectedCandidate)}`}
          />
        ))}
      </div>

      <span className="ml-auto text-xs font-mono text-text-tertiary">
        {done}/{weaver.candidateCount} done{failed ? ` · ${failed} failed` : ""}
      </span>
    </div>
  );
}

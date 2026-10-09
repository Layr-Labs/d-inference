"use client";

// Page-level non-data states: signed-out gate, first-load spinner, and the
// hard-error card. Kept presentational so the orchestrator stays thin.

import { Loader2, RefreshCw } from "lucide-react";

export function LoadingState() {
  return (
    <div className="flex items-center justify-center h-64">
      <Loader2 size={24} className="animate-spin text-accent-brand" />
    </div>
  );
}

export function ErrorState({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <div className="rounded-xl bg-bg-secondary shadow-sm p-6">
      <p className="text-accent-red text-sm font-medium">Failed to load your fleet</p>
      <p className="text-text-secondary text-sm mt-1 break-words">{message}</p>
      <button
        onClick={onRetry}
        className="focus-ring rounded-md mt-4 inline-flex items-center gap-1.5 text-sm text-accent-brand hover:underline"
      >
        <RefreshCw size={14} /> Retry
      </button>
    </div>
  );
}

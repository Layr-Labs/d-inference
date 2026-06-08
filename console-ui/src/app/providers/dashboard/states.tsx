"use client";

// Page-level non-data states: signed-out gate, first-load spinner, and the
// hard-error card. Kept presentational so the orchestrator stays thin.

import { Loader2, Mail, RefreshCw } from "lucide-react";

export function SignInGate({ onLogin }: { onLogin: () => void }) {
  return (
    <div className="rounded-xl bg-bg-secondary shadow-sm p-6">
      <h2 className="text-xl font-bold text-text-primary mb-2">Provider Dashboard</h2>
      <p className="text-sm text-text-secondary mb-5 max-w-2xl">
        Sign in to view your linked provider machines, live health, routing status, and earnings.
      </p>
      <button
        onClick={onLogin}
        className="focus-ring inline-flex items-center gap-2 px-6 py-2.5 rounded-lg bg-coral text-white font-medium text-sm hover:opacity-90 transition-opacity"
      >
        <Mail size={14} />
        Sign In
      </button>
    </div>
  );
}

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

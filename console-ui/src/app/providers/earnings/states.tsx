"use client";

// Non-happy-path states: loading skeleton, error + retry, signed-out wall.

import { LogIn, RefreshCw } from "lucide-react";
import { trackEvent } from "@/lib/google-analytics";

function SkeletonBlock({ className }: { className: string }) {
  return <div className={`animate-pulse rounded-xl bg-bg-tertiary ${className}`} />;
}

/** Layout-matching skeleton shown while the first fetch is in flight. */
export function LoadingSkeleton() {
  return (
    <div className="max-w-5xl mx-auto p-6 space-y-6" aria-busy="true">
      <div className="space-y-2">
        <SkeletonBlock className="h-6 w-48" />
        <SkeletonBlock className="h-4 w-64" />
      </div>
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <SkeletonBlock className="h-[220px] lg:col-span-2" />
        <SkeletonBlock className="h-[220px]" />
      </div>
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <SkeletonBlock className="h-64 lg:col-span-2" />
        <SkeletonBlock className="h-64" />
      </div>
      <SkeletonBlock className="h-72" />
    </div>
  );
}

/** Fetch failure. Auth failures get their own copy instead of a raw HTTP 401. */
export function ErrorState({
  error,
  unauthorized,
  onRetry,
}: {
  error: string;
  unauthorized: boolean;
  onRetry: () => void;
}) {
  return (
    <div className="max-w-4xl mx-auto p-6">
      <div className="rounded-xl bg-bg-secondary shadow-sm p-8 text-center">
        <p className="text-sm text-text-primary mb-1">
          {unauthorized
            ? "Your session has expired or is missing."
            : "Failed to load earnings."}
        </p>
        <p className="text-xs text-text-tertiary mb-4">
          {unauthorized ? "Sign in again to view your earnings." : error}
        </p>
        <button
          onClick={onRetry}
          className="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-bg-tertiary text-text-primary text-sm font-medium hover:bg-bg-hover transition-all"
        >
          <RefreshCw size={14} />
          Retry
        </button>
      </div>
    </div>
  );
}

/** Sign-in wall for unauthenticated visitors. */
export function SignedOutState({
  ready,
  onLogin,
}: {
  ready: boolean;
  onLogin: () => void;
}) {
  return (
    <div className="max-w-4xl mx-auto p-6">
      <div className="text-center py-16">
        <LogIn size={32} className="mx-auto mb-3 text-text-tertiary opacity-50" />
        <p className="text-sm text-text-tertiary mb-4">
          Sign in to view your provider earnings.
        </p>
        <button
          onClick={() => {
            trackEvent("login_cta_clicked", {
              source: "provider_earnings_empty_state",
            });
            onLogin();
          }}
          disabled={!ready}
          className="px-4 py-2 rounded-lg bg-coral text-white text-sm font-medium hover:opacity-90 transition-all disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {ready ? "Sign In" : "Loading..."}
        </button>
      </div>
    </div>
  );
}

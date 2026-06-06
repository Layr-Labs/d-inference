"use client";

import { DbError } from "@/components/DbError";

// Route-level error boundary. Server Component data-fetch failures (e.g. the
// read replica being unreachable or a query timing out) propagate here instead
// of crashing the route. AppShell (in the layout) stays mounted.
export default function RouteError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div className="space-y-3">
      <DbError digest={error.digest} />
      <button
        onClick={reset}
        className="rounded border border-[var(--border)] px-3 py-1.5 text-sm text-[var(--text-dim)] hover:bg-[var(--bg-hover)] hover:text-[var(--text)]"
      >
        Retry
      </button>
    </div>
  );
}

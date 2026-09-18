import Link from "next/link";
import { AlertCircle, Search, RefreshCw } from "lucide-react";

export function CatalogLoading() {
  return (
    <div role="status" aria-label="Loading models" className="space-y-6 py-7">
      {[0, 1, 2, 3].map((row) => (
        <div key={row} className="flex items-center justify-between gap-6 border-b border-border-dim pb-6 motion-safe:animate-pulse">
          <div className="w-1/2 space-y-3"><div className="h-5 w-3/4 rounded bg-bg-secondary" /><div className="h-3 w-1/2 rounded bg-bg-secondary" /></div>
          <div className="h-5 w-14 rounded bg-bg-secondary" />
          <div className="h-9 w-20 rounded-lg bg-bg-secondary" />
        </div>
      ))}
      <span className="sr-only">Loading the model catalog.</span>
    </div>
  );
}

export function CatalogEmpty({ kind, onReset, onRetry }: { kind: "error" | "empty" | "filtered"; onReset: () => void; onRetry: () => void }) {
  const isFiltered = kind === "filtered";
  const copy = new Map([
    ["error", { title: "The model catalog couldn’t load", description: "Check your connection and try again." }],
    ["empty", { title: "No models are listed yet", description: "Refresh the catalog or check your connection settings." }],
    ["filtered", { title: "No models match your search", description: "Try another model name or clear the capability filter." }],
  ]).get(kind)!;

  return (
    <div className="flex flex-col items-center px-5 py-20 text-center" role={kind === "error" ? "alert" : "status"}>
      <div className="mb-5 flex size-12 items-center justify-center rounded-2xl bg-bg-secondary text-text-secondary">
        {kind === "error" ? <AlertCircle size={22} /> : <Search size={22} />}
      </div>
      <h3 className="text-lg font-medium leading-snug text-text-primary">{copy.title}</h3>
      <p className="mt-2 max-w-sm text-sm leading-relaxed text-text-secondary">{copy.description}</p>
      <div className="mt-6 flex flex-wrap items-center justify-center gap-4">
        <button onClick={isFiltered ? onReset : onRetry} className="focus-ring inline-flex min-h-10 items-center gap-2 rounded-lg bg-coral px-4 text-sm font-medium text-white dark:text-bg-primary">
          {!isFiltered && <RefreshCw size={14} />}
          {isFiltered ? "Clear filters" : "Try again"}
        </button>
        {!isFiltered && <Link href="/settings" className="text-sm text-text-secondary underline underline-offset-4">Connection settings</Link>}
      </div>
    </div>
  );
}

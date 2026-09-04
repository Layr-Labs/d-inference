"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowUpRight, RefreshCw } from "lucide-react";
import { useStore } from "@/lib/store";
import type { Model } from "@/lib/api";
import { CatalogToolbar } from "./CatalogToolbar";
import { CatalogResults } from "./CatalogResults";
import { buildCatalogPrices, filterModels, type ModelFilter, type ModelSort } from "./catalog";
import { useModelCatalog } from "./useModelCatalog";

export function ModelCatalog() {
  const { models, pricing, loading, modelsError, pricingError, refresh } = useModelCatalog();
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<ModelFilter>("all");
  const [sort, setSort] = useState<ModelSort>("name");
  const router = useRouter();
  const prices = useMemo(() => buildCatalogPrices(pricing), [pricing]);
  const visibleModels = useMemo(() => filterModels(models, query, filter, sort, prices), [models, query, filter, sort, prices]);

  function resetFilters() {
    setQuery("");
    setFilter("all");
  }

  function startChat(model: Model) {
    const store = useStore.getState();
    store.setModels(models);
    store.setSelectedModel(model.id);
    store.createChat();
    router.push("/");
  }

  return (
    <div className="mx-auto w-full max-w-[1240px] px-5 py-8 sm:px-9 sm:py-11 lg:px-12">
      <div className="mb-9 flex flex-col items-start justify-between gap-5 sm:flex-row sm:items-center">
        <div>
          <h1 className="font-logo text-4xl font-normal tracking-tight text-ink sm:text-5xl" style={{ fontFamily: "var(--font-logo)" }}>Model library</h1>
          <p className="mt-3 max-w-xl text-sm leading-relaxed text-text-secondary">Compare capabilities and token prices, then start a new chat.</p>
        </div>
        <Link href="/api-console" className="focus-ring inline-flex min-h-10 shrink-0 items-center gap-2 rounded-lg border border-border-dim bg-bg-white px-4 text-sm text-text-primary transition-colors hover:bg-bg-secondary">
          Use the API <ArrowUpRight size={15} aria-hidden="true" />
        </Link>
      </div>

      <CatalogToolbar query={query} filter={filter} sort={sort} onQueryChange={setQuery} onFilterChange={setFilter} onSortChange={setSort} />

      <div className="mt-7 flex items-center justify-between gap-3 border-b border-border-dim pb-4">
        <p aria-live="polite" className="text-sm text-text-secondary">
          {!loading && <><span className="font-medium text-text-primary">{visibleModels.length}</span> {visibleModels.length === 1 ? "model" : "models"}{visibleModels.length !== models.length ? ` of ${models.length}` : ""}</>}
          {loading && "Loading catalog"}
        </p>
        <button onClick={refresh} disabled={loading} className="focus-ring inline-flex min-h-9 items-center gap-2 rounded-lg px-2 text-xs text-text-secondary transition-colors hover:bg-bg-secondary disabled:cursor-wait disabled:opacity-50">
          <RefreshCw size={13} aria-hidden="true" className={loading ? "motion-safe:animate-spin" : ""} />
          Refresh
        </button>
      </div>

      {!loading && ((modelsError && models.length > 0) || pricingError) && (
        <div role="status" className="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-lg bg-bg-secondary px-4 py-3 text-sm text-text-secondary">
          <p>{modelsError ? "Catalog refresh failed. Showing the last loaded models." : "Prices couldn’t load. Model details are still available."}</p>
          <button onClick={refresh} className="focus-ring min-h-8 shrink-0 rounded px-1 font-medium text-coral">Try again</button>
        </div>
      )}

      <CatalogResults models={visibleModels} hasCatalog={models.length > 0} loading={loading} failed={modelsError} prices={prices} onReset={resetFilters} onRetry={refresh} onChat={startChat} />
    </div>
  );
}

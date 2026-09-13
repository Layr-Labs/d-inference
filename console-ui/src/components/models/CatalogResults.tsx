import type { Model } from "@/lib/api";
import { CatalogEmpty, CatalogLoading } from "./CatalogState";
import { ModelRow } from "./ModelRow";
import type { CatalogPrices } from "./catalog";

interface Props {
  models: Model[];
  hasCatalog: boolean;
  loading: boolean;
  failed: boolean;
  prices: CatalogPrices;
  onReset: () => void;
  onRetry: () => void;
  onChat: (model: Model) => void;
}

export function CatalogResults({ models, hasCatalog, loading, failed, prices, onReset, onRetry, onChat }: Props) {
  if (loading && !hasCatalog) return <CatalogLoading />;
  if (models.length === 0) {
    let kind: "filtered" | "error" | "empty" = "empty";
    if (failed) kind = "error";
    if (hasCatalog) kind = "filtered";
    return <CatalogEmpty kind={kind} onReset={onReset} onRetry={onRetry} />;
  }

  return (
    <div>
      <div aria-hidden="true" className="hidden grid-cols-[minmax(0,1fr)_90px_95px_95px_88px] gap-x-5 border-b border-border-dim px-1 py-4 text-xs text-text-secondary xl:grid">
        <span>Model</span><span>Context</span><span>Input / 1M</span><span>Output / 1M</span><span />
      </div>
      <ul aria-label="Models" aria-busy={loading}>
        {models.map((model) => <ModelRow key={model.id} model={model} price={prices.get(model.id)} onChat={onChat} />)}
      </ul>
      <p className="mt-5 text-xs leading-relaxed text-text-secondary">Prices in USD per 1 million tokens. A dash means the value is not listed. Select a model name for details.</p>
    </div>
  );
}

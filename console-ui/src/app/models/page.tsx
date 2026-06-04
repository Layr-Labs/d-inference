"use client";

import { useEffect, useState } from "react";
import { TopBar } from "@/components/TopBar";
import { fetchModels, fetchPricing, type Model, type PricingResponse } from "@/lib/api";
import {
  Cpu,
  Shield,
  ShieldCheck,
  HardDrive,
  Users,
  Loader2,
  TrendingDown,
} from "lucide-react";

// Optional display-only market references. The catalog rows always come from
// the coordinator; entries here only enable a comparison when IDs match.
const baselinePricing: Record<string, { output: number; baseline: string; unit?: string }> = {
  // Typical hosted-API list output prices (micro-USD per 1M tokens). Darkbloom
  // targets ~50% of these, so the comparison reads "50% lower" once platform
  // pricing is set. Update if those baseline rates change.
  "gemma-4-26b": { output: 330_000, baseline: "typical APIs" },
  "gpt-oss-20b": { output: 140_000, baseline: "typical APIs" },
};

// Build a unified pricing lookup from the coordinator's response
function buildPricingLookup(pricing: PricingResponse | null): Record<string, { input: number; output: number; unit?: string }> {
  if (!pricing) return {};
  const lookup: Record<string, { input: number; output: number; unit?: string }> = {};
  for (const p of pricing.prices) {
    lookup[p.model] = { input: p.input_price, output: p.output_price };
  }
  return lookup;
}

function microUsdToDisplay(microUsd: number): string {
  const dollars = microUsd / 1_000_000;
  if (dollars < 0.01) return `$${dollars.toFixed(4)}`;
  return `$${dollars.toFixed(3)}`;
}

function savingsPercent(eigen: number, openRouter: number): number {
  if (openRouter === 0) return 0;
  return Math.round((1 - eigen / openRouter) * 100);
}

function formatBytes(bytes: number): string {
  if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(1)} GB`;
  if (bytes >= 1e6) return `${(bytes / 1e6).toFixed(0)} MB`;
  return `${bytes} B`;
}

function formatContextLength(tokens?: number): string {
  if (!tokens || tokens <= 0) return "";
  if (tokens >= 1000) return `${Math.round(tokens / 1000)}K`;
  return `${tokens}`;
}

function TrustIndicator({ level }: { level?: string }) {
  if (level === "hardware") {
    return (
      <div className="flex items-center gap-1 text-accent-green">
        <ShieldCheck size={12} />
        <span className="text-xs font-mono uppercase tracking-wider">
          Hardware
        </span>
      </div>
    );
  }
  return (
    <div className="flex items-center gap-1 text-text-tertiary">
      <Shield size={12} />
      <span className="text-xs font-mono uppercase tracking-wider">
        None
      </span>
    </div>
  );
}

export default function ModelsPage() {
  const [models, setModels] = useState<Model[]>([]);
  const [pricing, setPricing] = useState<PricingResponse | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    Promise.all([
      fetchModels().catch(() => [] as Model[]),
      fetchPricing().catch(() => null),
    ]).then(([m, p]) => {
      setModels(m);
      setPricing(p);
      setLoading(false);
    });
  }, []);

  const eigenPricing = buildPricingLookup(pricing);
  const modelNames = Object.fromEntries(
    models.map((model) => [model.id, model.display_name || model.id.split("/").pop() || model.id])
  );
  const comparisonRows = models
    .map((model) => ({ id: model.id, eigen: eigenPricing[model.id], baseline: baselinePricing[model.id] }))
    .filter((row): row is { id: string; eigen: { input: number; output: number; unit?: string }; baseline: { output: number; baseline: string; unit?: string } } => Boolean(row.eigen && row.baseline));

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Models" />

      <div className="flex-1 overflow-y-auto">
        <div className="max-w-5xl mx-auto px-3 sm:px-6 py-6 sm:py-8">
          <div className="mb-6">
            <h2 className="text-2xl font-semibold text-ink mb-1">
              Available Models
            </h2>
            <p className="text-sm text-text-tertiary">
              Models served by hardware-attested providers on the Darkbloom network.
            </p>
          </div>

          {loading ? (
            <div className="flex items-center justify-center py-20 text-text-tertiary">
              <Loader2 size={20} className="animate-spin mr-2" />
              Loading models...
            </div>
          ) : models.length === 0 ? (
            <div className="text-center py-20">
              <Cpu
                size={32}
                className="text-text-tertiary mx-auto mb-3 opacity-50"
              />
              <p className="text-sm text-text-tertiary">
                No models available. Check your coordinator connection in
                Settings.
              </p>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {models.map((model) => {
                const name = model.id.split("/").pop() || model.id;
                const org = model.id.includes("/")
                  ? model.id.split("/")[0]
                  : undefined;

                return (
                  <div
                    key={model.id}
                    className="group rounded-xl bg-bg-white border border-border-dim p-5 hover:shadow-sm transition-all"
                  >
                    {/* Header */}
                    <div className="flex items-start justify-between mb-3">
                      <div className="flex items-center gap-2">
                        <div className="w-8 h-8 rounded-lg bg-coral-light border-2 border-coral flex items-center justify-center">
                          <Cpu size={14} className="text-coral" />
                        </div>
                        <div>
                          <h3 className="text-sm font-medium text-text-primary leading-tight">
                            {name}
                          </h3>
                          {org && (
                            <p className="text-xs font-mono text-text-tertiary">
                              {org}
                            </p>
                          )}
                        </div>
                      </div>
                      <TrustIndicator level={model.trust_level} />
                    </div>

                    {/* Metadata pills */}
                    <div className="flex flex-wrap gap-1.5 mb-4">
                      {model.model_type && (
                        <span className="px-2 py-0.5 rounded bg-bg-elevated text-xs font-mono text-text-tertiary shadow-sm">
                          {model.model_type}
                        </span>
                      )}
                      {model.quantization && (
                        <span className="px-2 py-0.5 rounded bg-accent-green-dim/30 text-xs font-mono text-accent-green border border-accent-green/20">
                          {model.quantization}
                        </span>
                      )}
                      {model.size_bytes && (
                        <span className="px-2 py-0.5 rounded bg-bg-elevated text-xs font-mono text-text-tertiary shadow-sm">
                          {formatBytes(model.size_bytes)}
                        </span>
                      )}
                      {(model.context_length ?? model.max_context_length) ? (
                        <span className="px-2 py-0.5 rounded bg-bg-elevated text-xs font-mono text-text-tertiary shadow-sm">
                          {formatContextLength(model.context_length ?? model.max_context_length)} ctx
                        </span>
                      ) : null}
                    </div>

                    {/* Pricing */}
                    {eigenPricing[model.id] && (
                      <div className="mb-3">
                        <div className="flex items-center gap-2 text-xs">
                          <span className="text-text-tertiary">
                            {eigenPricing[model.id].input > 0
                              ? `${microUsdToDisplay(eigenPricing[model.id].input)} / ${microUsdToDisplay(eigenPricing[model.id].output)}`
                              : microUsdToDisplay(eigenPricing[model.id].output)}
                          </span>
                          <span className="text-text-tertiary opacity-50">
                            {eigenPricing[model.id].unit ?? "per 1M tokens"}
                          </span>
                        </div>
                        {baselinePricing[model.id] && (
                          <div className="flex items-center gap-1.5 mt-1">
                            <TrendingDown size={10} className="text-accent-green" />
                            <span className="text-xs font-medium text-accent-green">
                              {savingsPercent(eigenPricing[model.id].output, baselinePricing[model.id].output)}% cheaper
                            </span>
                            <span className="text-xs text-text-tertiary opacity-50">vs {baselinePricing[model.id].baseline}</span>
                          </div>
                        )}
                      </div>
                    )}

                    {/* Footer */}
                    <div className="flex items-center justify-between pt-3 border-t border-border-dim">
                      <div className="flex items-center gap-1 text-text-tertiary">
                        <Users size={11} />
                        <span className="text-xs font-mono">
                          {model.provider_count ?? 0} provider
                          {(model.provider_count ?? 0) !== 1 ? "s" : ""}
                        </span>
                      </div>
                      {model.attested && (
                        <div className="flex items-center gap-1">
                          <HardDrive size={10} className="text-accent-green" />
                          <span className="text-xs font-mono text-accent-green">
                            Attested
                          </span>
                        </div>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          )}

          {/* Pricing comparison table */}
          <div className="mt-12 mb-8">
            <div className="mb-4">
              <h2 className="text-2xl font-semibold text-ink mb-1">
                Pricing vs Baseline
              </h2>
              <p className="text-sm text-text-tertiary">
                Darkbloom runs on idle Apple Silicon hardware, benchmarked against common market pricing.
              </p>
            </div>

            <div className="rounded-xl bg-bg-white border border-border-dim overflow-hidden shadow-md">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border-dim">
                    <th className="text-left px-4 py-3 text-xs font-medium text-text-tertiary uppercase tracking-wider">Model</th>
                    <th>Darkbloom</th>
                    <th className="text-right px-4 py-3 text-xs font-medium text-text-tertiary uppercase tracking-wider">Baseline</th>
                    <th className="text-right px-4 py-3 text-xs font-medium text-text-tertiary uppercase tracking-wider">Savings</th>
                  </tr>
                </thead>
                <tbody>
                  {comparisonRows.map(({ id, eigen, baseline }) => {
                      const savings = savingsPercent(eigen.output, baseline.output);
                      const unit = eigen.unit ?? "per 1M tokens";
                      return (
                        <tr key={id} className="border-b border-border-dim/50 hover:bg-bg-tertiary transition-colors">
                          <td className="px-4 py-3">
                            <span className="font-medium text-text-primary">{modelNames[id] ?? id}</span>
                            <span className="ml-2 text-xs text-text-tertiary">{unit}</span>
                          </td>
                          <td className="px-4 py-3 text-right font-mono text-text-secondary">
                            {eigen.input > 0
                              ? `${microUsdToDisplay(eigen.input)} / ${microUsdToDisplay(eigen.output)}`
                              : microUsdToDisplay(eigen.output)}
                          </td>
                          <td className="px-4 py-3 text-right font-mono text-text-tertiary">
                            <span className="line-through opacity-60">
                              {microUsdToDisplay(baseline.output)}
                            </span>
                            <span className="block text-xs opacity-50">{baseline.baseline}</span>
                          </td>
                          <td className="px-4 py-3 text-right">
                            <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-accent-green-dim/30 text-accent-green text-xs font-medium">
                              <TrendingDown size={10} />
                              {savings}%
                            </span>
                          </td>
                        </tr>
                      );
                    })}
                </tbody>
              </table>
              <div className="px-4 py-2 text-xs text-text-tertiary bg-bg-tertiary/50">
                Baseline prices reflect typical hosted-API list rates as of April 2026.
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

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

// Competitor pricing for comparison — static since these are external
const competitorPricing: Record<string, { output: number; name: string; competitor: string; unit?: string }> = {
  "qwen3.5-27b-claude-opus-8bit": { output: 1_560_000, name: "Qwen3.5 27B Claude Opus", competitor: "OpenRouter" },
  "mlx-community/Trinity-Mini-8bit": { output: 150_000, name: "Trinity Mini", competitor: "OpenRouter" },
  "mlx-community/gemma-4-26b-a4b-it-8bit": { output: 400_000, name: "Gemma 4 26B", competitor: "OpenRouter" },
  "mlx-community/Qwen3.5-122B-A10B-8bit": { output: 2_080_000, name: "Qwen3.5 122B", competitor: "OpenRouter" },
  "mlx-community/MiniMax-M2.5-8bit": { output: 1_000_000, name: "MiniMax M2.5", competitor: "OpenRouter" },
  "CohereLabs/cohere-transcribe-03-2026": { output: 2_000, name: "Cohere Transcribe", competitor: "AssemblyAI", unit: "per audio-min" },
};

// Build a unified pricing lookup from the coordinator's response
function buildPricingLookup(pricing: PricingResponse | null): Record<string, { input: number; output: number; unit?: string }> {
  if (!pricing) return {};
  const lookup: Record<string, { input: number; output: number; unit?: string }> = {};
  for (const p of pricing.prices) {
    lookup[p.model] = { input: p.input_price, output: p.output_price };
  }
  for (const p of pricing.transcription_prices) {
    lookup[p.model] = { input: 0, output: p.price_per_minute, unit: "per audio-min" };
  }
  // Image generation is paused for maintenance — don't surface image prices.
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
                        {competitorPricing[model.id] && (
                          <div className="flex items-center gap-1.5 mt-1">
                            <TrendingDown size={10} className="text-accent-green" />
                            <span className="text-xs font-medium text-accent-green">
                              {savingsPercent(eigenPricing[model.id].output, competitorPricing[model.id].output)}% cheaper
                            </span>
                            <span className="text-xs text-text-tertiary opacity-50">vs {competitorPricing[model.id].competitor}</span>
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
                Pricing vs Competitors
              </h2>
              <p className="text-sm text-text-tertiary">
                Darkbloom runs on idle Apple Silicon hardware — 50% cheaper than centralized providers.
              </p>
            </div>

            <div className="rounded-xl bg-bg-white border border-border-dim overflow-hidden shadow-md">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border-dim">
                    <th className="text-left px-4 py-3 text-xs font-medium text-text-tertiary uppercase tracking-wider">Model</th>
                    <th>Darkbloom</th>
                    <th className="text-right px-4 py-3 text-xs font-medium text-text-tertiary uppercase tracking-wider">Competitor</th>
                    <th className="text-right px-4 py-3 text-xs font-medium text-text-tertiary uppercase tracking-wider">Savings</th>
                  </tr>
                </thead>
                <tbody>
                  {Object.entries(eigenPricing)
                    .filter(([id]) => competitorPricing[id])
                    .map(([id, eigen]) => {
                      const comp = competitorPricing[id];
                      const savings = savingsPercent(eigen.output, comp.output);
                      const unit = eigen.unit ?? "per 1M tokens";
                      return (
                        <tr key={id} className="border-b border-border-dim/50 hover:bg-bg-tertiary transition-colors">
                          <td className="px-4 py-3">
                            <span className="font-medium text-text-primary">{comp.name}</span>
                            <span className="ml-2 text-xs text-text-tertiary">{unit}</span>
                          </td>
                          <td className="px-4 py-3 text-right font-mono text-text-secondary">
                            {eigen.input > 0
                              ? `${microUsdToDisplay(eigen.input)} / ${microUsdToDisplay(eigen.output)}`
                              : microUsdToDisplay(eigen.output)}
                          </td>
                          <td className="px-4 py-3 text-right font-mono text-text-tertiary">
                            <span className="line-through opacity-60">
                              {microUsdToDisplay(comp.output)}
                            </span>
                            <span className="block text-xs opacity-50">{comp.competitor}</span>
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
                Competitor prices from OpenRouter and AssemblyAI as of April 2026. Image generation is paused for maintenance.
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

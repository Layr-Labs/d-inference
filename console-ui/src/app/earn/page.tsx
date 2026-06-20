"use client";

import { useEffect, useState, useMemo } from "react";
import { TopBar } from "@/components/TopBar";
import { useAuth } from "@/hooks/useAuth";
import { trackEvent } from "@/lib/google-analytics";
import { fetchModels, fetchPricing, type Model } from "@/lib/api";
import { BaseRewardsPanel } from "@/components/earn/BaseRewardsPanel";
import {
  MAC_CONFIGS,
  MAC_TYPES,
  type CatalogModel,
  buildCatalogModels,
  calculateModelEarnings,
  calculatePortfolioEarnings,
  getComparisons,
  fmtUSD,
  fmtUSDWhole,
  SINGLE_STREAM_EFFICIENCY,
  CONTINUOUS_BATCH_FACTOR,
  ASSUMED_UTILIZATION,
  PROMPT_TO_COMPLETION_RATIO,
} from "./calc";
import Link from "next/link";
import {
  Cpu,
  DollarSign,
  TrendingUp,
  Coffee,
  Wifi,
  ParkingCircle,
  Info,
  Crown,
  Shield,
  ArrowRight,
  Mail,
  Terminal,
} from "lucide-react";

/* ─── Fixed assumptions ─── */
// 80% utilization + always-on, with continuous batching at a quality-preserving
// 4×. We deliberately don't expose utilization or hours to the user — this is
// the realistic "busy machine" figure the calculator estimates, and the
// base-reward floor is added on top.
const ALWAYS_ON_HOURS = 24;

function comparisonIcon(text: string) {
  if (text.includes("Spotify") || text.includes("Netflix"))
    return <TrendingUp size={14} className="text-accent-green shrink-0" />;
  if (text.includes("latte")) return <Coffee size={14} className="text-accent-amber shrink-0" />;
  if (text.includes("internet")) return <Wifi size={14} className="text-accent-brand shrink-0" />;
  if (text.includes("parking"))
    return <ParkingCircle size={14} className="text-accent-amber shrink-0" />;
  return <DollarSign size={14} className="text-accent-green shrink-0" />;
}

/* ─── Selector pill button ─── */

function PillButton({
  label,
  selected,
  onClick,
}: {
  label: string;
  selected: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className={`px-4 py-2.5 rounded-lg text-sm font-medium transition-all ${
        selected
          ? "bg-accent-brand text-white shadow-sm"
          : "bg-bg-tertiary text-text-secondary hover:bg-bg-hover hover:text-text-primary"
      }`}
    >
      {label}
    </button>
  );
}

/* ─── Page component ─── */

export default function EarnPage() {
  const { ready, authenticated, login } = useAuth();

  // Default: MacBook Pro -> M4 Max -> 48GB
  const [selectedMacType, setSelectedMacType] = useState("MacBook Pro");
  const [selectedChip, setSelectedChip] = useState("M4 Max");
  const [selectedRAM, setSelectedRAM] = useState(48);
  const [elecCost, setElecCost] = useState("0.15");
  const [selectedModelIds, setSelectedModelIds] = useState<string[]>([]);
  const [catalogModels, setCatalogModels] = useState<CatalogModel[]>([]);

  const elecCostNum = parseFloat(elecCost) || 0;

  useEffect(() => {
    Promise.all([
      fetchModels().catch(() => [] as Model[]),
      fetchPricing().catch(() => null),
    ]).then(([models, pricing]) => {
      setCatalogModels(buildCatalogModels(models, pricing));
    });
  }, []);

  // Derive available chips for selected mac type
  const availableChips = useMemo(() => {
    const chips: string[] = [];
    for (const c of MAC_CONFIGS) {
      if (c.macType === selectedMacType && !chips.includes(c.chip)) {
        chips.push(c.chip);
      }
    }
    return chips;
  }, [selectedMacType]);

  // If current chip isn't available for this mac type, auto-select the last one
  const effectiveChip = availableChips.includes(selectedChip)
    ? selectedChip
    : availableChips[availableChips.length - 1];

  // Get the config for the selected mac type + chip
  const selectedConfig = useMemo(
    () => MAC_CONFIGS.find((c) => c.macType === selectedMacType && c.chip === effectiveChip),
    [selectedMacType, effectiveChip]
  );

  // Available RAM options
  const availableRAM = selectedConfig?.ramOptions ?? [];

  // If current RAM isn't available, auto-select the largest
  const effectiveRAM = availableRAM.includes(selectedRAM)
    ? selectedRAM
    : availableRAM[availableRAM.length - 1] ?? 8;

  // Calculate USAGE earnings for ALL eligible models (for ranking)
  const rankedModels = useMemo(() => {
    if (!selectedConfig) return [];
    const eligible = catalogModels.filter((m) => m.minRAMGB <= effectiveRAM);
    const results = eligible.map((m) =>
      calculateModelEarnings(m, selectedConfig, ALWAYS_ON_HOURS, elecCostNum)
    );
    results.sort((a, b) => b.monthlyNet - a.monthlyNet);
    return results;
  }, [selectedConfig, effectiveRAM, elecCostNum, catalogModels]);

  // Determine the best model id
  const bestModelId = rankedModels.length > 0 ? rankedModels[0].modelId : null;

  const eligibleModelIds = useMemo(
    () => new Set(rankedModels.map((m) => m.modelId)),
    [rankedModels]
  );

  const effectiveModelIds = useMemo(() => {
    const validSelected = selectedModelIds.filter((id) => eligibleModelIds.has(id));
    return validSelected.length > 0 ? validSelected : bestModelId ? [bestModelId] : [];
  }, [bestModelId, eligibleModelIds, selectedModelIds]);

  const selectedCatalogModels = useMemo(
    () =>
      effectiveModelIds
        .map((id) => catalogModels.find((m) => m.id === id))
        .filter((m): m is CatalogModel => Boolean(m)),
    [effectiveModelIds, catalogModels]
  );

  const selectedModelSizeGB = selectedCatalogModels.reduce(
    (sum, model) => sum + model.modelSizeGB,
    0
  );

  // Get the selected portfolio earnings — selected models split the active hours.
  const result = useMemo(() => {
    if (!selectedConfig || selectedCatalogModels.length === 0) return null;
    return calculatePortfolioEarnings(
      selectedCatalogModels,
      selectedConfig,
      effectiveRAM,
      ALWAYS_ON_HOURS,
      elecCostNum
    );
  }, [selectedConfig, selectedCatalogModels, effectiveRAM, elecCostNum]);

  const comparisons = useMemo(
    () => (result ? getComparisons(result.monthlyNet) : []),
    [result]
  );

  // Handlers that cascade selections — reset model choice on hardware change
  const handleMacTypeSelect = (macType: string) => {
    setSelectedMacType(macType);
    setSelectedModelIds([]);
  };

  const handleChipSelect = (chip: string) => {
    setSelectedChip(chip);
    setSelectedModelIds([]);
  };

  const handleRAMSelect = (ram: number) => {
    setSelectedRAM(ram);
    setSelectedModelIds([]);
  };

  if (!selectedConfig) return null;

  const toggleModel = (modelId: string) => {
    const model = catalogModels.find((m) => m.id === modelId);
    if (!model) return;
    setSelectedModelIds((current) => {
      const validCurrent = current.filter((id) => eligibleModelIds.has(id));
      if (validCurrent.length === 0) {
        return [modelId];
      }
      const base = validCurrent;
      if (base.includes(modelId)) {
        const next = base.filter((id) => id !== modelId);
        return next.length > 0 ? next : base;
      }
      const currentSize = base.reduce((sum, id) => {
        const selected = catalogModels.find((m) => m.id === id);
        return sum + (selected?.modelSizeGB ?? 0);
      }, 0);
      if (currentSize + model.modelSizeGB > effectiveRAM) return [modelId];
      return [...base, modelId];
    });
  };

  let modelSelectorHint = "Auto-selected: most profitable model. Select more models if they fit in memory.";
  if (catalogModels.length === 0) {
    modelSelectorHint = "Loading live model catalog, or no priced models are currently available.";
  } else if (rankedModels.length === 0) {
    modelSelectorHint = "No compatible catalog model for this memory configuration";
  } else if (selectedModelIds.length > 0) {
    modelSelectorHint =
      "Selected models share active inference hours, so usage earnings are not double-counted.";
  }

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Earnings Calculator" />

      <div className="flex-1 overflow-y-auto">
        <div className="max-w-4xl mx-auto px-3 sm:px-6 py-6 sm:py-8">
          {/* Header */}
          <div className="mb-8">
            <h2 className="text-lg font-semibold text-text-primary mb-1">
              Provider Earnings Calculator
            </h2>
            <p className="text-sm text-text-tertiary">
              Estimate how much your Apple Silicon Mac can earn serving inference
              on the Darkbloom network — usage earnings plus the base-reward floor.
            </p>
          </div>

          {/* Setup Provider CTA */}
          <div className="rounded-xl bg-bg-secondary p-6 mb-6">
            {!authenticated ? (
              <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
                <div className="flex items-start gap-3">
                  <div className="w-10 h-10 rounded-lg bg-accent-brand/10 flex items-center justify-center shrink-0">
                    <Terminal size={20} className="text-accent-brand" />
                  </div>
                  <div>
                    <h3 className="text-sm font-semibold text-text-primary mb-0.5">
                      Ready to start earning?
                    </h3>
                    <p className="text-sm text-text-secondary">
                      Sign in to set up your provider node and start earning from your Mac.
                    </p>
                  </div>
                </div>
                <button
                  onClick={() => {
                    trackEvent("login_cta_clicked", {
                      source: "earn_page_setup_provider_cta",
                    });
                    login();
                  }}
                  disabled={!ready}
                  className="inline-flex items-center justify-center gap-2 px-6 py-2.5 rounded-lg
                             bg-coral text-white font-medium text-sm
                             hover:opacity-90
                             disabled:opacity-40 disabled:cursor-not-allowed
                             transition-all shrink-0"
                >
                  <Mail size={14} />
                  {!ready ? "Loading..." : "Sign In"}
                </button>
              </div>
            ) : (
              <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
                <div className="flex items-start gap-3">
                  <div className="w-10 h-10 rounded-lg bg-accent-green/10 flex items-center justify-center shrink-0">
                    <Cpu size={20} className="text-accent-green" />
                  </div>
                  <div>
                    <h3 className="text-sm font-semibold text-text-primary mb-0.5">
                      Turn your Mac into a provider
                    </h3>
                    <p className="text-sm text-text-secondary">
                      Set up your Apple Silicon Mac to serve inference and earn from the Darkbloom network.
                    </p>
                  </div>
                </div>
                <Link
                  href="/providers/setup"
                  onClick={() => {
                    trackEvent("provider_setup_clicked", {
                      source: "earn_page_setup_provider_cta",
                    });
                  }}
                  className="inline-flex items-center justify-center gap-2 px-6 py-2.5 rounded-lg
                             bg-accent-brand text-white font-medium text-sm
                             hover:bg-accent-brand-hover
                             transition-colors shrink-0"
                >
                  Setup Provider <ArrowRight size={14} />
                </Link>
              </div>
            )}
          </div>

          {/* Hardware selector */}
          <div className="rounded-xl bg-bg-secondary p-6 mb-6">
            <div className="flex items-center gap-2 mb-5">
              <Cpu size={14} className="text-text-tertiary" />
              <h3 className="text-sm font-medium text-text-primary">Select Your Hardware</h3>
            </div>

            {/* Step 1: Mac Type */}
            <div className="mb-5">
              <p className="text-xs font-medium text-text-tertiary uppercase tracking-wider mb-3">
                1. Mac Type
              </p>
              <div className="flex flex-wrap gap-2">
                {MAC_TYPES.map((mt) => (
                  <PillButton
                    key={mt}
                    label={mt}
                    selected={selectedMacType === mt}
                    onClick={() => handleMacTypeSelect(mt)}
                  />
                ))}
              </div>
            </div>

            {/* Step 2: Chip */}
            <div className="mb-5">
              <p className="text-xs font-medium text-text-tertiary uppercase tracking-wider mb-3">
                2. Chip
              </p>
              <div className="flex flex-wrap gap-2">
                {availableChips.map((chip) => (
                  <PillButton
                    key={chip}
                    label={chip}
                    selected={effectiveChip === chip}
                    onClick={() => handleChipSelect(chip)}
                  />
                ))}
              </div>
            </div>

            {/* Step 3: Memory */}
            <div className="mb-5">
              <p className="text-xs font-medium text-text-tertiary uppercase tracking-wider mb-3">
                3. Memory
              </p>
              <div className="flex flex-wrap gap-2">
                {availableRAM.map((ram) => (
                  <PillButton
                    key={ram}
                    label={`${ram} GB`}
                    selected={effectiveRAM === ram}
                    onClick={() => handleRAMSelect(ram)}
                  />
                ))}
              </div>
            </div>

            {/* Help tip */}
            <div className="flex items-start gap-2 px-3 py-2.5 rounded-lg bg-bg-tertiary">
              <Info size={14} className="text-text-tertiary shrink-0 mt-0.5" />
              <p className="text-xs text-text-tertiary">
                Not sure about your specs? Click{" "}
                <span className="font-medium text-text-secondary"> &gt; About This Mac</span>{" "}
                to check.
              </p>
            </div>

            {/* Selected hardware summary */}
            <div className="mt-4 flex flex-wrap gap-2">
              <span className="px-2.5 py-1 rounded bg-bg-elevated text-xs font-mono text-text-secondary">
                {selectedMacType}
              </span>
              <span className="px-2.5 py-1 rounded bg-bg-elevated text-xs font-mono text-text-secondary">
                {effectiveChip}
              </span>
              <span className="px-2.5 py-1 rounded bg-bg-elevated text-xs font-mono text-text-secondary">
                {effectiveRAM} GB
              </span>
              <span className="px-2.5 py-1 rounded bg-bg-elevated text-xs font-mono text-text-tertiary">
                {selectedConfig.bandwidthGBs} GB/s
              </span>
              <span className="px-2.5 py-1 rounded bg-bg-elevated text-xs font-mono text-text-tertiary">
                {selectedConfig.idleWatts}W idle → {selectedConfig.inferWatts}W infer
              </span>
            </div>
          </div>

          {/* Model selector */}
          <div className="rounded-xl bg-bg-secondary p-6 mb-6">
            <div className="flex items-center gap-2 mb-2">
              <Crown size={14} className="text-text-tertiary" />
              <h3 className="text-sm font-medium text-text-primary">Model</h3>
            </div>
            <p className="text-xs text-text-tertiary mb-4">
              {modelSelectorHint}
            </p>

            {selectedCatalogModels.length > 0 && (
              <div className="mb-3 flex flex-wrap gap-2">
                <span className="px-2.5 py-1 rounded bg-bg-tertiary text-xs font-mono text-text-secondary">
                  {selectedCatalogModels.length} model{selectedCatalogModels.length === 1 ? "" : "s"} selected
                </span>
                <span className="px-2.5 py-1 rounded bg-bg-tertiary text-xs font-mono text-text-tertiary">
                  {selectedModelSizeGB} GB weights / {effectiveRAM} GB RAM
                </span>
              </div>
            )}

            <div className="rounded-lg border border-border-dim overflow-hidden">
              {rankedModels.map((m, i) => {
                const isSelected = effectiveModelIds.includes(m.modelId);
                const isBest = m.modelId === bestModelId;
                const catalogEntry = catalogModels.find((c) => c.id === m.modelId);
                const isUnprofitable = m.monthlyNet < 0;
                const canAdd =
                  selectedModelIds.length === 0 ||
                  isSelected ||
                  selectedModelSizeGB + (catalogEntry?.modelSizeGB ?? 0) <= effectiveRAM;
                return (
                  <div key={m.modelId} className={i > 0 ? "border-t border-border-dim" : ""}>
                    <button
                      onClick={() => toggleModel(m.modelId)}
                      className={`w-full flex items-center gap-3 px-4 py-3 text-left transition-colors ${
                        isSelected
                          ? "bg-accent-brand/10 border-l-2 border-l-accent-brand"
                          : "hover:bg-bg-tertiary border-l-2 border-l-transparent"
                      }`}
                      title={
                        !canAdd
                          ? "Not enough memory to add this model; clicking will switch to it instead"
                          : undefined
                      }
                    >
                      {/* Checkbox indicator */}
                      <div
                        className={`w-4 h-4 rounded border-2 flex items-center justify-center shrink-0 ${
                          isSelected
                            ? "border-accent-brand"
                            : "border-text-tertiary/40"
                        }`}
                      >
                        {isSelected && (
                          <div className="w-2 h-2 rounded-sm bg-accent-brand" />
                        )}
                      </div>

                      {/* Model name */}
                      <span className={`text-sm font-medium flex-1 min-w-0 truncate ${
                        isUnprofitable ? "text-text-tertiary line-through" : isSelected ? "text-text-primary" : "text-text-secondary"
                      }`}>
                        {m.modelName}
                      </span>

                      {/* Monthly usage net */}
                      <span className={`text-sm font-mono tabular-nums whitespace-nowrap ${
                        m.monthlyNet >= 0 ? "text-accent-green" : "text-accent-red"
                      }`}>
                        {fmtUSD(m.monthlyNet)}/mo usage
                      </span>

                      {isBest && m.monthlyNet > 0 && (
                        <span className="px-2 py-0.5 rounded text-xs font-medium bg-accent-green/10 text-accent-green border border-accent-green/20 whitespace-nowrap">
                          Best model
                        </span>
                      )}
                    </button>
                    {/* Demand note shown when selected */}
                    {isSelected && catalogEntry?.demandNote && (
                      <div className="px-4 pb-3 pl-11">
                        <div className="flex items-start gap-1.5 text-xs text-text-tertiary">
                          <Info size={11} className="shrink-0 mt-0.5" />
                          <span>{catalogEntry.demandNote}{isUnprofitable ? " This model's usage revenue is below its electricity cost on your hardware — the base reward still applies." : ""}</span>
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>

            {rankedModels.length === 0 && (
              <div className="text-center py-6 text-sm text-text-tertiary">
                {catalogModels.length === 0
                  ? "No live priced models available yet"
                  : `No models fit in ${effectiveRAM} GB RAM`}
              </div>
            )}
          </div>

          {result ? (
            <>
              {/* Electricity cost (utilization & hours are fixed at 100% / always-on) */}
              <div className="rounded-xl bg-bg-secondary p-5 mb-6">
                <label className="block text-xs font-medium text-text-tertiary uppercase tracking-wider mb-3">
                  <DollarSign size={12} className="inline mr-1.5 -mt-0.5" />
                  Electricity Cost
                </label>
                <div className="flex items-baseline gap-2">
                  <span className="text-text-secondary text-sm">$</span>
                  <input
                    type="number"
                    step="0.01"
                    min="0"
                    value={elecCost}
                    onChange={(e) => setElecCost(e.target.value)}
                    className="w-24 bg-bg-tertiary rounded-lg px-3 py-2 text-sm font-mono text-text-primary focus:outline-none focus:ring-2 focus:ring-accent-brand/50"
                  />
                  <span className="text-text-tertiary text-sm">/kWh</span>
                </div>
                <p className="text-xs text-text-tertiary mt-2">
                  US avg: $0.15 | EU avg: $0.25 | CA avg: $0.22
                </p>
              </div>

              {/* Results */}
              <div className="rounded-xl bg-bg-secondary p-6 mb-6">
                <div className="flex items-center gap-2 mb-5">
                  <div className="w-8 h-8 rounded-lg bg-accent-green/10 border border-accent-green/20 flex items-center justify-center">
                    <TrendingUp size={14} className="text-accent-green" />
                  </div>
                  <div>
                    <h3 className="text-sm font-medium text-text-primary">
                      Estimated Earnings
                    </h3>
                    <p className="text-xs text-text-tertiary">
                      Serving{" "}
                      <span className="font-mono text-text-secondary">
                        {result.modelName}
                      </span>{" "}
                      (always-on, {Math.round(ASSUMED_UTILIZATION * 100)}% utilization)
                    </p>
                    {result.selectedModelCount > 1 && (
                      <p className="text-xs text-text-tertiary mt-1">
                        Active time is split across selected models to avoid double-counting bandwidth and compute.
                      </p>
                    )}
                  </div>
                </div>

                {/* Utilization & batching assumption note */}
                <div className="flex items-start gap-2 px-3 py-2.5 rounded-lg bg-bg-tertiary mb-5">
                  <Info size={14} className="text-text-tertiary shrink-0 mt-0.5" />
                  <p className="text-xs text-text-tertiary">
                    Usage assumes <span className="text-text-secondary font-medium">{Math.round(ASSUMED_UTILIZATION * 100)}% utilization</span>{" "}
                    with continuous batching ({CONTINUOUS_BATCH_FACTOR}× concurrent requests at full speed).
                    Real demand varies by model and time of day — the base reward covers you while the
                    network is quiet, and usage scales up as it fills.
                  </p>
                </div>

                {/* Big number */}
                <div className="text-center py-6 border-b border-border-dim mb-6">
                  <p className="text-xs uppercase tracking-wider text-text-tertiary mb-1">
                    Monthly net earnings
                  </p>
                  <p className="text-4xl font-bold font-mono text-accent-green">
                    {fmtUSDWhole(result.monthlyNet)}
                  </p>
                  <p className="text-sm text-text-tertiary mt-1">
                    {fmtUSDWhole(result.annualNet)} / year
                  </p>
                </div>

                {/* Usage + floor breakdown */}
                <div className="grid grid-cols-3 gap-3 mb-6">
                  <div className="rounded-lg bg-bg-tertiary p-3 text-center">
                    <p className="text-xs text-text-tertiary mb-1">Usage (inference)</p>
                    <p className="text-lg font-mono text-text-primary">{fmtUSD(result.monthlyUsageNet)}</p>
                    <p className="text-[10px] text-text-tertiary mt-0.5">revenue − electricity</p>
                  </div>
                  <div className="rounded-lg bg-accent-brand/5 border border-accent-brand/20 p-3 text-center">
                    <p className="text-xs text-text-tertiary mb-1 flex items-center justify-center gap-1">
                      <Shield size={11} className="text-accent-brand" /> Base reward
                    </p>
                    <p className="text-lg font-mono text-accent-brand">+ {fmtUSD(result.monthlyFloor)}</p>
                    <p className="text-[10px] text-text-tertiary mt-0.5">{effectiveRAM}GB tier × uptime</p>
                  </div>
                  <div className="rounded-lg bg-accent-green/5 border border-accent-green/20 p-3 text-center">
                    <p className="text-xs text-text-tertiary mb-1">Total / mo</p>
                    <p className="text-lg font-mono text-accent-green">{fmtUSD(result.monthlyNet)}</p>
                    <p className="text-[10px] text-text-tertiary mt-0.5">usage + base reward</p>
                  </div>
                </div>

                {/* Detail grid */}
                <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                  <div>
                    <p className="text-xs text-text-tertiary mb-0.5">
                      Decode speed
                    </p>
                    <p className="text-sm font-mono text-text-primary">
                      {result.decodeTokPerSec.toFixed(1)} tok/s
                    </p>
                  </div>
                  <div>
                    <p className="text-xs text-text-tertiary mb-0.5">
                      Monthly usage revenue
                    </p>
                    <p className="text-sm font-mono text-text-primary">
                      {fmtUSD(result.monthlyRevenue)}
                    </p>
                  </div>
                  <div>
                    <p className="text-xs text-text-tertiary mb-0.5">
                      Monthly electricity
                    </p>
                    <p className="text-sm font-mono text-accent-red">
                      -{fmtUSD(result.monthlyElec)}
                    </p>
                  </div>
                  <div>
                    <p className="text-xs text-text-tertiary mb-0.5">
                      Electricity % of revenue
                    </p>
                    <p className="text-sm font-mono text-text-primary">
                      {result.elecPercent.toFixed(1)}%
                    </p>
                  </div>
                  <div>
                    <p className="text-xs text-text-tertiary mb-0.5">
                      Usage revenue per hour
                    </p>
                    <p className="text-sm font-mono text-text-primary">
                      {fmtUSD(result.revenuePerHour, 4)}
                    </p>
                  </div>
                  <div>
                    <p className="text-xs text-text-tertiary mb-0.5">
                      Electricity per hour
                    </p>
                    <p className="text-sm font-mono text-text-secondary">
                      {fmtUSD(result.elecPerHour, 4)}
                    </p>
                  </div>
                  <div>
                    <p className="text-xs text-text-tertiary mb-0.5">
                      Base reward / mo
                    </p>
                    <p className="text-sm font-mono text-accent-brand">
                      {fmtUSD(result.monthlyFloor)}
                    </p>
                  </div>
                  <div>
                    <p className="text-xs text-text-tertiary mb-0.5 flex items-center gap-1">
                      Provider share
                      <span className="relative group">
                        <Info size={12} className="text-text-tertiary cursor-help" />
                        <span className="absolute bottom-full left-1/2 -translate-x-1/2 mb-1 w-48 px-2 py-1 text-[10px] text-text-secondary bg-bg-tertiary border border-border-primary rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none z-10">
                          You keep 100% of usage revenue and the base reward. Payouts are currently processed manually.
                        </span>
                      </span>
                    </p>
                    <p className="text-sm font-mono text-text-primary">100%</p>
                  </div>
                </div>
              </div>

              {/* Base rewards explainer */}
              <BaseRewardsPanel highlightGB={effectiveRAM} />

              {/* Calculation breakdown */}
              <div className="rounded-xl bg-bg-secondary p-6 mb-6">
                <h3 className="text-sm font-medium text-text-primary mb-3">
                  How this is calculated
                </h3>
                <div className="text-xs text-text-tertiary font-mono space-y-1 bg-bg-tertiary rounded-lg p-4 overflow-x-auto">
                  {result.selectedModels[0] && (
                    <>
                      <p>
                        single_stream = ({selectedConfig.bandwidthGBs} GB/s / {result.selectedModels[0].activeParamsGB} GB) * {SINGLE_STREAM_EFFICIENCY} ={" "}
                        {((selectedConfig.bandwidthGBs / result.selectedModels[0].activeParamsGB) * SINGLE_STREAM_EFFICIENCY).toFixed(1)} tok/s
                      </p>
                      <p>
                        decode_tok/s = single_stream * {CONTINUOUS_BATCH_FACTOR}x batch * {Math.round(ASSUMED_UTILIZATION * 100)}% util ={" "}
                        {result.selectedModels[0].decodeTokPerSec.toFixed(1)} tok/s
                      </p>
                      <p>
                        usage_rev/hr = decode_tok/hr * out_price + (decode_tok/hr * {PROMPT_TO_COMPLETION_RATIO} prompt) * in_price ={" "}
                        {fmtUSD(result.revenuePerHour, 4)}
                      </p>
                      <p>
                        electricity/hr = ({result.selectedModels[0].marginalWatts}W / 1000) * ${elecCostNum.toFixed(2)}/kWh * {Math.round(ASSUMED_UTILIZATION * 100)}% ={" "}
                        {fmtUSD(result.elecPerHour, 4)}
                      </p>
                      <p>
                        monthly_usage = ({fmtUSD(result.revenuePerHour, 4)} - {fmtUSD(result.elecPerHour, 4)}) * 24 hrs/day * 30 ={" "}
                        {fmtUSD(result.monthlyUsageNet)}
                      </p>
                      <p>
                        base_reward = {effectiveRAM}GB tier * 100% uptime = {fmtUSD(result.monthlyFloor)}/mo
                      </p>
                      <p className="text-text-secondary">
                        monthly_total = {fmtUSD(result.monthlyUsageNet)} usage + {fmtUSD(result.monthlyFloor)} base reward ={" "}
                        {fmtUSD(result.monthlyNet)}
                      </p>
                    </>
                  )}
                </div>
              </div>

              {/* Comparisons */}
              {comparisons.length > 0 && (
                <div className="rounded-xl bg-bg-secondary p-6 mb-8">
                  <h3 className="text-sm font-medium text-text-primary mb-3">
                    Your Mac earns more than...
                  </h3>
                  <div className="space-y-2">
                    {comparisons.map((c) => (
                      <div
                        key={c}
                        className="flex items-center gap-3 px-3 py-2 rounded-lg bg-bg-tertiary text-sm text-text-secondary"
                      >
                        {comparisonIcon(c)}
                        <span>{c}</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </>
          ) : (
            <div className="rounded-xl bg-bg-secondary p-6 mb-6">
              <div className="flex items-start gap-3">
                <div className="w-8 h-8 rounded-lg bg-accent-amber/10 border border-accent-amber/20 flex items-center justify-center shrink-0">
                  <Info size={14} className="text-accent-amber" />
                </div>
                <div>
                  <h3 className="text-sm font-medium text-text-primary mb-1">
                    No compatible model for this hardware
                  </h3>
                  <p className="text-sm text-text-tertiary">
                    No live catalog model fits in {effectiveRAM} GB of unified memory. Choose a Mac with more memory to estimate provider earnings.
                  </p>
                </div>
              </div>
            </div>
          )}

          {/* Disclaimer */}
          <div className="rounded-xl bg-bg-secondary p-5 mb-8">
            <p className="text-xs text-text-tertiary mb-2">
              <span className="font-medium text-text-secondary">These are estimates only.</span> Usage earnings assume {Math.round(ASSUMED_UTILIZATION * 100)}% utilization with continuous batching ({CONTINUOUS_BATCH_FACTOR}× concurrent requests); actual usage depends on network demand, model popularity, your provider reputation, and how many other providers serve the same model. The live network currently runs well below this.
            </p>
            <p className="text-xs text-text-tertiary mb-2">
              <span className="font-medium text-text-secondary">Base rewards</span> are paid on top of usage to attested machines that stay online ≥90% of the month, up to a fixed monthly budget — they are not a guarantee and taper off as the network grows.
            </p>
            <p className="text-xs text-text-tertiary">
              When your Mac is idle (no requests), it draws minimal power — the electricity cost shown only applies during active inference. You keep 100% of both usage revenue and base rewards.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}

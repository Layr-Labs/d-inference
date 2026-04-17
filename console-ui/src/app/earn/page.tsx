"use client";

import { useState, useMemo } from "react";
import { TopBar } from "@/components/TopBar";
import { useAuth } from "@/hooks/useAuth";
import Link from "next/link";
import {
  Cpu,
  Zap,
  DollarSign,
  TrendingUp,
  Coffee,
  Wifi,
  ParkingCircle,
  Info,
  Crown,
  ArrowRight,
  Mail,
  Terminal,
} from "lucide-react";

/* ─── Hardware database ─── */

interface MacConfig {
  macType: string;
  chip: string;
  ramOptions: number[];
  bandwidthGBs: number;
  idleWatts: number;   // power when model loaded, waiting for requests
  inferWatts: number;  // power during active token generation
}

const MAC_CONFIGS: MacConfig[] = [
  // --- MacBook Air ---
  { macType: "MacBook Air", chip: "M1",       ramOptions: [8, 16],                    bandwidthGBs: 68,  idleWatts: 8,  inferWatts: 12 },
  { macType: "MacBook Air", chip: "M2",       ramOptions: [8, 16, 24],               bandwidthGBs: 100, idleWatts: 8,  inferWatts: 12 },
  { macType: "MacBook Air", chip: "M3",       ramOptions: [8, 16, 24],               bandwidthGBs: 100, idleWatts: 8,  inferWatts: 12 },
  { macType: "MacBook Air", chip: "M4",       ramOptions: [16, 24, 32],              bandwidthGBs: 120, idleWatts: 8,  inferWatts: 12 },

  // --- MacBook Pro ---
  { macType: "MacBook Pro", chip: "M1 Pro",   ramOptions: [16, 32],                  bandwidthGBs: 200, idleWatts: 12, inferWatts: 30 },
  { macType: "MacBook Pro", chip: "M1 Max",   ramOptions: [32, 64],                  bandwidthGBs: 400, idleWatts: 15, inferWatts: 40 },
  { macType: "MacBook Pro", chip: "M2 Pro",   ramOptions: [16, 32],                  bandwidthGBs: 200, idleWatts: 12, inferWatts: 30 },
  { macType: "MacBook Pro", chip: "M2 Max",   ramOptions: [32, 64, 96],              bandwidthGBs: 400, idleWatts: 15, inferWatts: 40 },
  { macType: "MacBook Pro", chip: "M3",       ramOptions: [8, 16, 24],               bandwidthGBs: 100, idleWatts: 10, inferWatts: 20 },
  { macType: "MacBook Pro", chip: "M3 Pro",   ramOptions: [18, 36],                  bandwidthGBs: 150, idleWatts: 15, inferWatts: 35 },
  { macType: "MacBook Pro", chip: "M3 Max",   ramOptions: [36, 48, 64, 96, 128],     bandwidthGBs: 300, idleWatts: 20, inferWatts: 45 },
  { macType: "MacBook Pro", chip: "M4",       ramOptions: [16, 24, 32],              bandwidthGBs: 120, idleWatts: 10, inferWatts: 20 },
  { macType: "MacBook Pro", chip: "M4 Pro",   ramOptions: [24, 48],                  bandwidthGBs: 273, idleWatts: 12, inferWatts: 30 },
  { macType: "MacBook Pro", chip: "M4 Max",   ramOptions: [36, 48, 64, 128],         bandwidthGBs: 546, idleWatts: 20, inferWatts: 50 },
  { macType: "MacBook Pro", chip: "M5",       ramOptions: [16, 24, 32],              bandwidthGBs: 153, idleWatts: 10, inferWatts: 20 },
  { macType: "MacBook Pro", chip: "M5 Pro",   ramOptions: [24, 48],                  bandwidthGBs: 307, idleWatts: 12, inferWatts: 30 },
  { macType: "MacBook Pro", chip: "M5 Max",   ramOptions: [36, 48, 64, 128],         bandwidthGBs: 614, idleWatts: 20, inferWatts: 50 },

  // --- Mac Mini ---
  { macType: "Mac Mini", chip: "M1",          ramOptions: [8, 16],                   bandwidthGBs: 68,  idleWatts: 5,  inferWatts: 10 },
  { macType: "Mac Mini", chip: "M2",          ramOptions: [8, 16, 24],               bandwidthGBs: 100, idleWatts: 5,  inferWatts: 12 },
  { macType: "Mac Mini", chip: "M2 Pro",      ramOptions: [16, 32],                  bandwidthGBs: 200, idleWatts: 8,  inferWatts: 25 },
  { macType: "Mac Mini", chip: "M4",          ramOptions: [16, 24, 32],              bandwidthGBs: 120, idleWatts: 5,  inferWatts: 15 },
  { macType: "Mac Mini", chip: "M4 Pro",      ramOptions: [24, 48],                  bandwidthGBs: 273, idleWatts: 8,  inferWatts: 25 },

  // --- Mac Studio ---
  { macType: "Mac Studio", chip: "M1 Max",    ramOptions: [32, 64],                  bandwidthGBs: 400, idleWatts: 20, inferWatts: 60 },
  { macType: "Mac Studio", chip: "M1 Ultra",  ramOptions: [64, 128],                 bandwidthGBs: 800, idleWatts: 30, inferWatts: 90 },
  { macType: "Mac Studio", chip: "M2 Max",    ramOptions: [32, 64, 96],              bandwidthGBs: 400, idleWatts: 20, inferWatts: 60 },
  { macType: "Mac Studio", chip: "M2 Ultra",  ramOptions: [64, 128, 192],            bandwidthGBs: 800, idleWatts: 35, inferWatts: 100 },
  { macType: "Mac Studio", chip: "M3 Ultra",  ramOptions: [96, 256, 512],             bandwidthGBs: 819, idleWatts: 35, inferWatts: 110 },
  { macType: "Mac Studio", chip: "M4 Max",    ramOptions: [36, 48, 64, 128],         bandwidthGBs: 546, idleWatts: 25, inferWatts: 65 },
  { macType: "Mac Studio", chip: "M5 Max",    ramOptions: [36, 48, 64, 128],         bandwidthGBs: 614, idleWatts: 25, inferWatts: 65 },

  // --- Mac Pro ---
  { macType: "Mac Pro", chip: "M2 Ultra",     ramOptions: [64, 128, 192],            bandwidthGBs: 800, idleWatts: 40, inferWatts: 120 },
  { macType: "Mac Pro", chip: "M3 Ultra",     ramOptions: [96, 256, 512],             bandwidthGBs: 819, idleWatts: 40, inferWatts: 120 },
];

const MAC_TYPES = ["MacBook Air", "MacBook Pro", "Mac Mini", "Mac Studio", "Mac Pro"];

/* ─── Model catalog ─── */

interface CatalogModel {
  id: string;
  name: string;
  type: "text" | "image" | "transcription";
  minRAMGB: number;
  demandNote: string; // demand expectation shown as infotip
  // Text model params
  activeParamsGB?: number;
  modelSizeGB?: number;
  outputPriceMicro?: number;
  // Image model params
  baseImagesPerHour?: number;
  imagePriceMicro?: number;
  referenceBandwidth?: number;
  // Transcription params
  baseAudioMinPerHour?: number;
  pricePerMinMicro?: number;
}

const CATALOG_MODELS: CatalogModel[] = [
  { id: "cohere-transcribe", name: "Cohere Transcribe", type: "transcription", minRAMGB: 8, baseAudioMinPerHour: 1800, pricePerMinMicro: 1_000, demandNote: "Lower demand — most users need text inference. STT requests are bursty and less frequent." },
  { id: "flux-4b", name: "FLUX.2 Klein 4B", type: "image", minRAMGB: 16, baseImagesPerHour: 450, imagePriceMicro: 1_500, referenceBandwidth: 100, demandNote: "Paused for maintenance — image routing is disabled right now. Earnings projection shown for reference; no image requests are being served currently." },
  { id: "flux-9b", name: "FLUX.2 Klein 9B", type: "image", minRAMGB: 24, baseImagesPerHour: 300, imagePriceMicro: 2_500, referenceBandwidth: 150, demandNote: "Paused for maintenance — image routing is disabled right now. Earnings projection shown for reference; no image requests are being served currently." },
  { id: "qwen-27b", name: "Qwen3.5 27B Claude Opus", type: "text", minRAMGB: 36, activeParamsGB: 27, modelSizeGB: 27, outputPriceMicro: 780_000, demandNote: "High demand — text/chat inference is the primary workload on the network." },
  { id: "trinity-mini", name: "Trinity Mini", type: "text", minRAMGB: 48, activeParamsGB: 3, modelSizeGB: 26, outputPriceMicro: 75_000, demandNote: "High demand — fast MoE model popular for agentic and coding tasks." },
  { id: "gemma-4-26b", name: "Gemma 4 26B", type: "text", minRAMGB: 36, activeParamsGB: 4, modelSizeGB: 28, outputPriceMicro: 200_000, demandNote: "High demand — Google's latest MoE, strong quality at fast speed." },
  { id: "qwen-122b", name: "Qwen3.5 122B", type: "text", minRAMGB: 128, activeParamsGB: 10, modelSizeGB: 122, outputPriceMicro: 1_040_000, demandNote: "High demand — premium quality attracts users willing to pay more per token." },
  { id: "minimax-m2.5", name: "MiniMax M2.5", type: "text", minRAMGB: 256, activeParamsGB: 11, modelSizeGB: 243, outputPriceMicro: 500_000, demandNote: "High demand — SOTA coding model, attracts power users and enterprises." },
];

/* ─── Earnings calculation ─── */

interface ModelEarnings {
  modelId: string;
  modelName: string;
  modelType: "text" | "image" | "transcription";
  decodeTokPerSec: number | null;
  throughputLabel: string | null;
  revenuePerHour: number;
  elecPerHour: number;
  netPerHour: number;
  monthlyRevenue: number;
  monthlyElec: number;
  monthlyNet: number;
  annualNet: number;
  elecPercent: number;
  // Formula breakdown fields
  batchSize: number | null;
  batchEff: number | null;
  activeParamsGB: number | null;
  outputPriceMicro: number | null;
  scaledImagesPerHour: number | null;
  scaledAudioMinPerHour: number | null;
  marginalWatts: number;
  // Catalog reference for formula display
  catalogModel: CatalogModel;
}

function calculateModelEarnings(
  model: CatalogModel,
  config: MacConfig,
  ramGB: number,
  hoursPerDay: number,
  elecCostPerKWh: number
): ModelEarnings {
  let revenuePerHour: number;
  let decodeTokPerSec: number | null = null;
  let throughputLabel: string | null = null;
  let batchSize: number | null = null;
  let batchEff: number | null = null;
  let activeParamsGB: number | null = null;
  let outputPriceMicro: number | null = null;
  let scaledImagesPerHour: number | null = null;
  let scaledAudioMinPerHour: number | null = null;

  if (model.type === "text") {
    const freeRAM = ramGB - model.modelSizeGB!;
    batchSize = Math.max(1, Math.min(16, Math.floor(freeRAM / 2)));
    batchEff = batchSize <= 4 ? 0.80 : batchSize <= 8 ? 0.85 : 0.90;
    activeParamsGB = model.activeParamsGB!;
    outputPriceMicro = model.outputPriceMicro!;
    const singleTokPerSec = (config.bandwidthGBs / activeParamsGB) * 0.60;
    const batchedTokPerSec = singleTokPerSec * batchSize * batchEff;
    decodeTokPerSec = batchedTokPerSec;
    const tokPerHour = batchedTokPerSec * 3600;
    revenuePerHour = (tokPerHour / 1_000_000) * (outputPriceMicro / 1_000_000);
  } else if (model.type === "image") {
    const scaled = model.baseImagesPerHour! * (config.bandwidthGBs / model.referenceBandwidth!);
    scaledImagesPerHour = scaled;
    revenuePerHour = scaled * (model.imagePriceMicro! / 1_000_000);
    throughputLabel = `${Math.round(scaled).toLocaleString()} images/hr`;
  } else {
    const scaled = model.baseAudioMinPerHour! * (config.bandwidthGBs / 100);
    scaledAudioMinPerHour = scaled;
    revenuePerHour = scaled * (model.pricePerMinMicro! / 1_000_000);
    throughputLabel = `${Math.round(scaled).toLocaleString()} audio-min/hr`;
  }

  const marginalWatts = config.inferWatts - config.idleWatts;
  const elecPerHour = (marginalWatts / 1000) * elecCostPerKWh;
  const netPerHour = revenuePerHour - elecPerHour;

  const hoursPerMonth = hoursPerDay * 30;
  const monthlyRevenue = revenuePerHour * hoursPerMonth;
  const monthlyElec = elecPerHour * hoursPerMonth;
  const monthlyNet = netPerHour * hoursPerMonth;
  const annualNet = monthlyNet * 12;
  const elecPercent = monthlyRevenue > 0 ? (monthlyElec / monthlyRevenue) * 100 : 0;

  return {
    modelId: model.id,
    modelName: model.name,
    modelType: model.type,
    decodeTokPerSec,
    throughputLabel,
    revenuePerHour,
    elecPerHour,
    netPerHour,
    monthlyRevenue,
    monthlyElec,
    monthlyNet,
    annualNet,
    elecPercent,
    batchSize,
    batchEff,
    activeParamsGB,
    outputPriceMicro,
    scaledImagesPerHour,
    scaledAudioMinPerHour,
    marginalWatts,
    catalogModel: model,
  };
}

/* ─── Fun comparisons ─── */

function getComparisons(monthlyNet: number): string[] {
  const comparisons: string[] = [];
  if (monthlyNet > 2)
    comparisons.push(`${Math.floor(monthlyNet / 2)} Spotify Premium subscriptions`);
  if (monthlyNet > 5)
    comparisons.push(`${Math.floor(monthlyNet / 5)} lattes per month`);
  if (monthlyNet > 15)
    comparisons.push(`${Math.floor(monthlyNet / 15)} Netflix Standard plans`);
  if (monthlyNet > 50)
    comparisons.push(`a ${Math.floor(monthlyNet / 50)}-day parking meter`);
  if (monthlyNet > 70)
    comparisons.push(`${Math.floor(monthlyNet / 70)}x your home internet bill`);
  if (monthlyNet > 200)
    comparisons.push(
      `$${(monthlyNet * 12).toLocaleString(undefined, { maximumFractionDigits: 0 })}/yr — a nice side income`
    );
  return comparisons;
}

function comparisonIcon(text: string) {
  if (text.includes("Spotify") || text.includes("Netflix"))
    return <TrendingUp size={14} className="text-accent-green shrink-0" />;
  if (text.includes("latte"))
    return <Coffee size={14} className="text-accent-amber shrink-0" />;
  if (text.includes("internet"))
    return <Wifi size={14} className="text-accent-brand shrink-0" />;
  if (text.includes("parking"))
    return <ParkingCircle size={14} className="text-accent-amber shrink-0" />;
  return <DollarSign size={14} className="text-accent-green shrink-0" />;
}

/* ─── Format helpers ─── */

function fmtUSD(n: number, decimals = 2): string {
  if (n < 0) return "-$" + Math.abs(n).toFixed(decimals);
  return "$" + n.toFixed(decimals);
}

function fmtUSDWhole(n: number): string {
  if (n < 0)
    return "-$" + Math.abs(n).toLocaleString(undefined, { maximumFractionDigits: 0 });
  return "$" + n.toLocaleString(undefined, { maximumFractionDigits: 0 });
}

/* ─── Model type badge ─── */

function ModelTypeBadge({ type }: { type: "text" | "image" | "transcription" }) {
  const config = {
    text: { label: "text", bg: "bg-blue-500/10", text: "text-blue-400", border: "border-blue-500/20" },
    image: { label: "image", bg: "bg-purple-500/10", text: "text-purple-400", border: "border-purple-500/20" },
    transcription: { label: "stt", bg: "bg-orange-500/10", text: "text-orange-400", border: "border-orange-500/20" },
  }[type];

  return (
    <span className={`px-2 py-0.5 rounded text-xs font-mono ${config.bg} ${config.text} border ${config.border}`}>
      {config.label}
    </span>
  );
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
  const [inferenceHours, setInferenceHours] = useState(18);
  const [hoursManuallySet, setHoursManuallySet] = useState(false);
  const [elecCost, setElecCost] = useState("0.15");
  const [selectedModelId, setSelectedModelId] = useState<string | null>(null);

  const elecCostNum = parseFloat(elecCost) || 0;

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

  // Default inference hours per model type
  const defaultHoursForType = (type: string) =>
    type === "text" ? 18 : type === "image" ? 12 : 1;

  // Calculate earnings for ALL eligible models, each using its own default hours
  const rankedModels = useMemo(() => {
    if (!selectedConfig) return [];
    const eligible = CATALOG_MODELS.filter((m) => m.minRAMGB <= effectiveRAM);
    const results = eligible.map((m) =>
      calculateModelEarnings(m, selectedConfig, effectiveRAM, defaultHoursForType(m.type), elecCostNum)
    );
    results.sort((a, b) => b.monthlyNet - a.monthlyNet);
    return results;
  }, [selectedConfig, effectiveRAM, elecCostNum]);

  // Determine the best model id
  const bestModelId = rankedModels.length > 0 ? rankedModels[0].modelId : null;

  // Effective selected model: use manual selection if it's still in the list, otherwise auto-select best
  const effectiveModelId =
    selectedModelId && rankedModels.some((m) => m.modelId === selectedModelId)
      ? selectedModelId
      : bestModelId;

  // Get the selected model's earnings — recalculated with the slider's hours
  const selectedCatalogModel = CATALOG_MODELS.find((m) => m.id === effectiveModelId);
  const result = useMemo(() => {
    if (!selectedConfig || !selectedCatalogModel) return null;
    return calculateModelEarnings(selectedCatalogModel, selectedConfig, effectiveRAM, inferenceHours, elecCostNum);
  }, [selectedConfig, selectedCatalogModel, effectiveRAM, inferenceHours, elecCostNum]);

  // Auto-set inference hours based on model type (unless user manually adjusted)
  const selectedModelType = result?.modelType;
  const prevModelTypeRef = useState<string | null>(null);
  if (selectedModelType && selectedModelType !== prevModelTypeRef[0] && !hoursManuallySet) {
    prevModelTypeRef[1](selectedModelType);
    const defaultHours = defaultHoursForType(selectedModelType);
    if (inferenceHours !== defaultHours) {
      setInferenceHours(defaultHours);
    }
  }

  const comparisons = useMemo(
    () => (result ? getComparisons(result.monthlyNet) : []),
    [result]
  );

  // Handlers that cascade selections — reset model choice on hardware change
  const handleMacTypeSelect = (macType: string) => {
    setSelectedMacType(macType);
    setSelectedModelId(null);
    setHoursManuallySet(false);
  };

  const handleChipSelect = (chip: string) => {
    setSelectedChip(chip);
    setSelectedModelId(null);
    setHoursManuallySet(false);
  };

  const handleRAMSelect = (ram: number) => {
    setSelectedRAM(ram);
    setSelectedModelId(null);
    setHoursManuallySet(false);
  };

  if (!selectedConfig || !result) return null;

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
              on the Darkbloom network.
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
                  onClick={login}
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
              {selectedModelId === null
                ? "Auto-selected: most profitable for your hardware"
                : "Manually selected — change hardware to reset"}
            </p>

            <div className="rounded-lg border border-border-dim overflow-hidden">
              {rankedModels.map((m, i) => {
                const isSelected = m.modelId === effectiveModelId;
                const isBest = m.modelId === bestModelId;
                const catalogEntry = CATALOG_MODELS.find((c) => c.id === m.modelId);
                const isUnprofitable = m.monthlyNet < 0;
                return (
                  <div key={m.modelId} className={i > 0 ? "border-t border-border-dim" : ""}>
                    <button
                      onClick={() => setSelectedModelId(m.modelId)}
                      className={`w-full flex items-center gap-3 px-4 py-3 text-left transition-colors ${
                        isSelected
                          ? "bg-accent-brand/10 border-l-2 border-l-accent-brand"
                          : "hover:bg-bg-tertiary border-l-2 border-l-transparent"
                      }`}
                    >
                      {/* Radio indicator */}
                      <div
                        className={`w-4 h-4 rounded-full border-2 flex items-center justify-center shrink-0 ${
                          isSelected
                            ? "border-accent-brand"
                            : "border-text-tertiary/40"
                        }`}
                      >
                        {isSelected && (
                          <div className="w-2 h-2 rounded-full bg-accent-brand" />
                        )}
                      </div>

                      {/* Model name */}
                      <span className={`text-sm font-medium flex-1 min-w-0 truncate ${
                        isUnprofitable ? "text-text-tertiary line-through" : isSelected ? "text-text-primary" : "text-text-secondary"
                      }`}>
                        {m.modelName}
                      </span>

                      {/* Type badge */}
                      <ModelTypeBadge type={m.modelType} />

                      {/* Paused badge for image models — routing is paused for maintenance */}
                      {m.modelType === "image" && (
                        <span className="px-2 py-0.5 rounded text-xs font-medium bg-coral/10 text-coral border border-coral/20 whitespace-nowrap">
                          Paused
                        </span>
                      )}

                      {/* Monthly net */}
                      <span className={`text-sm font-mono tabular-nums whitespace-nowrap ${
                        m.monthlyNet >= 0 ? "text-accent-green" : "text-accent-red"
                      }`}>
                        {fmtUSD(m.monthlyNet)}/mo
                      </span>

                      {/* Best badge */}
                      {isBest && m.monthlyNet > 0 && m.modelType !== "image" && (
                        <span className="px-2 py-0.5 rounded text-xs font-medium bg-accent-green/10 text-accent-green border border-accent-green/20 whitespace-nowrap">
                          Best
                        </span>
                      )}
                    </button>
                    {/* Demand note shown when selected */}
                    {isSelected && catalogEntry?.demandNote && (
                      <div className="px-4 pb-3 pl-11">
                        <div className="flex items-start gap-1.5 text-xs text-text-tertiary">
                          <Info size={11} className="shrink-0 mt-0.5" />
                          <span>{catalogEntry.demandNote}{isUnprofitable ? " This model loses money on your hardware — electricity exceeds revenue." : ""}</span>
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>

            {rankedModels.length === 0 && (
              <div className="text-center py-6 text-sm text-text-tertiary">
                No models fit in {effectiveRAM} GB RAM
              </div>
            )}
          </div>

          {/* Inference Hours & Electricity */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
            {/* Inference hours slider */}
            <div className="rounded-xl bg-bg-secondary p-5">
              <label className="block text-xs font-medium text-text-tertiary uppercase tracking-wider mb-3">
                <Zap size={12} className="inline mr-1.5 -mt-0.5" />
                Inference Hours
              </label>
              <div className="flex items-baseline gap-2 mb-3">
                <span className="text-2xl font-bold font-mono text-text-primary">
                  {inferenceHours}
                </span>
                <span className="text-sm text-text-tertiary">
                  hours of active inference per day
                </span>
              </div>
              <input
                type="range"
                min={1}
                max={24}
                value={inferenceHours}
                onChange={(e) => {
                  setInferenceHours(parseInt(e.target.value));
                  setHoursManuallySet(true);
                }}
                className="w-full accent-accent-brand"
              />
              <div className="flex justify-between text-xs text-text-tertiary mt-1">
                <span>1 hr</span>
                <span>12 hrs</span>
                <span>24 hrs</span>
              </div>
            </div>

            {/* Electricity cost */}
            <div className="rounded-xl bg-bg-secondary p-5">
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
                  at {inferenceHours} hrs/day
                </p>
              </div>
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

            {/* Detail grid */}
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
              {(result.decodeTokPerSec !== null || result.throughputLabel !== null) && (
                <div>
                  <p className="text-xs text-text-tertiary mb-0.5">
                    {result.decodeTokPerSec !== null ? "Batched decode speed" : "Throughput"}
                  </p>
                  <p className="text-sm font-mono text-text-primary">
                    {result.decodeTokPerSec !== null
                      ? `${result.decodeTokPerSec.toFixed(1)} tok/s`
                      : result.throughputLabel}
                  </p>
                </div>
              )}
              <div>
                <p className="text-xs text-text-tertiary mb-0.5">
                  Monthly revenue
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
                  Revenue per hour
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
                  Net per hour
                </p>
                <p className="text-sm font-mono text-accent-green">
                  {fmtUSD(result.netPerHour, 4)}
                </p>
              </div>
              <div>
                <p className="text-xs text-text-tertiary mb-0.5 flex items-center gap-1">
                  Provider share
                  <span className="relative group">
                    <Info size={12} className="text-text-tertiary cursor-help" />
                    <span className="absolute bottom-full left-1/2 -translate-x-1/2 mb-1 w-48 px-2 py-1 text-[10px] text-text-secondary bg-bg-tertiary border border-border-primary rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none z-10">
                      Payouts are currently processed manually. Automatic payouts coming soon.
                    </span>
                  </span>
                </p>
                <p className="text-sm font-mono text-text-primary">100%</p>
              </div>
            </div>
          </div>

          {/* Calculation breakdown */}
          <div className="rounded-xl bg-bg-secondary p-6 mb-6">
            <h3 className="text-sm font-medium text-text-primary mb-3">
              How this is calculated
            </h3>
            <div className="text-xs text-text-tertiary font-mono space-y-1 bg-bg-tertiary rounded-lg p-4 overflow-x-auto">
              {result.modelType === "transcription" ? (
                <>
                  <p>
                    scaled_audio_min/hr = {result.catalogModel.baseAudioMinPerHour!.toLocaleString()} * ({selectedConfig.bandwidthGBs} GB/s / 100 GB/s) = {Math.round(result.scaledAudioMinPerHour!).toLocaleString()}
                  </p>
                  <p>
                    revenue/hr = {Math.round(result.scaledAudioMinPerHour!).toLocaleString()} min * $
                    {(result.catalogModel.pricePerMinMicro! / 1_000_000).toFixed(4)}
                    /min = {fmtUSD(result.revenuePerHour, 4)}
                  </p>
                  <p>
                    marginal_watts = {selectedConfig.inferWatts}W (inference) - {selectedConfig.idleWatts}W (idle) = {result.marginalWatts}W
                  </p>
                  <p>
                    elec/hr = ({result.marginalWatts}W / 1000) * ${elecCostNum.toFixed(2)}/kWh = {fmtUSD(result.elecPerHour, 4)}
                  </p>
                  <p>
                    net/hr = {fmtUSD(result.revenuePerHour, 4)} - {fmtUSD(result.elecPerHour, 4)} = {fmtUSD(result.netPerHour, 4)}
                  </p>
                  <p>
                    monthly = {fmtUSD(result.netPerHour, 4)} * {inferenceHours} hrs/day * 30 days = {fmtUSD(result.monthlyNet)}
                  </p>
                </>
              ) : result.modelType === "image" ? (
                <>
                  <p>
                    scaled_images/hr = {result.catalogModel.baseImagesPerHour!} * ({selectedConfig.bandwidthGBs} GB/s / {result.catalogModel.referenceBandwidth!} GB/s) = {Math.round(result.scaledImagesPerHour!)}
                  </p>
                  <p>
                    revenue/hr = {Math.round(result.scaledImagesPerHour!)} images/hr * $
                    {(result.catalogModel.imagePriceMicro! / 1_000_000).toFixed(4)}
                    /image = {fmtUSD(result.revenuePerHour, 4)}
                  </p>
                  <p>
                    marginal_watts = {selectedConfig.inferWatts}W (inference) - {selectedConfig.idleWatts}W (idle) = {result.marginalWatts}W
                  </p>
                  <p>
                    elec/hr = ({result.marginalWatts}W / 1000) * ${elecCostNum.toFixed(2)}/kWh = {fmtUSD(result.elecPerHour, 4)}
                  </p>
                  <p>
                    net/hr = {fmtUSD(result.revenuePerHour, 4)} - {fmtUSD(result.elecPerHour, 4)} = {fmtUSD(result.netPerHour, 4)}
                  </p>
                  <p>
                    monthly = {fmtUSD(result.netPerHour, 4)} * {inferenceHours} hrs/day * 30 days = {fmtUSD(result.monthlyNet)}
                  </p>
                </>
              ) : (
                <>
                  <p>
                    single_tok/s = ({selectedConfig.bandwidthGBs} GB/s / {result.activeParamsGB} GB) * 0.60 ={" "}
                    {((selectedConfig.bandwidthGBs / result.activeParamsGB!) * 0.6).toFixed(1)} tok/s
                  </p>
                  <p>
                    batched_tok/s ={" "}
                    {((selectedConfig.bandwidthGBs / result.activeParamsGB!) * 0.6).toFixed(1)} * {result.batchSize} * {result.batchEff} ={" "}
                    {result.decodeTokPerSec?.toFixed(1)} tok/s
                  </p>
                  <p>
                    tok/hr = {result.decodeTokPerSec?.toFixed(1)} * 3600 ={" "}
                    {((result.decodeTokPerSec ?? 0) * 3600).toLocaleString(undefined, { maximumFractionDigits: 0 })}
                  </p>
                  <p>
                    revenue/hr = ({((result.decodeTokPerSec ?? 0) * 3600).toLocaleString(undefined, { maximumFractionDigits: 0 })} / 1M) * $
                    {((result.outputPriceMicro ?? 0) / 1_000_000).toFixed(6)} = {fmtUSD(result.revenuePerHour, 4)}
                  </p>
                  <p>
                    marginal_watts = {selectedConfig.inferWatts}W (inference) - {selectedConfig.idleWatts}W (idle) = {result.marginalWatts}W
                  </p>
                  <p>
                    elec/hr = ({result.marginalWatts}W / 1000) * ${elecCostNum.toFixed(2)}/kWh = {fmtUSD(result.elecPerHour, 4)}
                  </p>
                  <p>
                    net/hr = {fmtUSD(result.revenuePerHour, 4)} - {fmtUSD(result.elecPerHour, 4)} = {fmtUSD(result.netPerHour, 4)}
                  </p>
                  <p>
                    monthly = {fmtUSD(result.netPerHour, 4)} * {inferenceHours} hrs/day * 30 days = {fmtUSD(result.monthlyNet)}
                  </p>
                </>
              )}
            </div>
          </div>

          {/* Comparisons */}
          {comparisons.length > 0 && (
            <div className="rounded-xl bg-bg-secondary p-6 mb-8">
              <h3 className="text-sm font-medium text-text-primary mb-3">
                Your Mac earns more idle than...
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

          {/* Disclaimer */}
          <div className="rounded-xl bg-bg-secondary p-5 mb-8">
            <p className="text-xs text-text-tertiary mb-2">
              <span className="font-medium text-text-secondary">These are estimates only.</span> We do not guarantee any specific utilization or earnings. Actual earnings depend on network demand, model popularity, your provider reputation score, and how many other providers are serving the same model.
            </p>
            <p className="text-xs text-text-tertiary mb-2">
              When your Mac is idle (no inference requests), it consumes minimal power — you don&apos;t lose significant money waiting for requests. The electricity costs shown only apply during active inference.
            </p>
            <p className="text-xs text-text-tertiary">
              Text models typically see the highest and most consistent demand. Image generation and transcription requests are bursty — high volume during peaks, quiet otherwise.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}

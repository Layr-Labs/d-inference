"use client";

import { useId, useState } from "react";
import { Check, ChevronDown, Copy, MessageSquare, ShieldCheck } from "lucide-react";
import type { Model } from "@/lib/api";
import { providerRequirementBadge, providerRequirementTitle } from "@/lib/provider-capabilities";
import { formatContext, formatPrice, modelContext, modelFeatures, modelName, type CatalogPrice } from "./catalog";

const FEATURE_LABELS = new Map([["images", "Image input"], ["tools", "Tool calling"], ["reasoning", "Reasoning"]]);

function ModelDetails({ model }: { model: Model }) {
  const [copyState, setCopyState] = useState<"idle" | "copied" | "failed">("idle");
  const requirement = providerRequirementBadge(model.required_provider_capabilities);
  const sizeGB = model.size_gb ?? (model.size_bytes ? model.size_bytes / 1e9 : undefined);
  const metadata = [
    { label: "Family", value: model.family },
    { label: "Architecture", value: model.architecture },
    { label: "Quantization", value: model.quantization },
    { label: "Reported providers", value: model.provider_count !== undefined ? model.provider_count.toLocaleString("en-US") : undefined },
    { label: "Attestation", value: model.attested ? "Attested" : undefined },
    { label: "Model size", value: sizeGB ? `${sizeGB.toLocaleString("en-US", { maximumFractionDigits: 1 })} GB` : undefined },
    { label: "Max output", value: model.max_output_length ? `${model.max_output_length.toLocaleString("en-US")} tokens` : undefined },
  ].filter((entry) => entry.value);

  async function copyID() {
    try {
      await navigator.clipboard.writeText(model.id);
      setCopyState("copied");
    } catch {
      setCopyState("failed");
    }
  }

  return (
    <div className="space-y-5 rounded-xl bg-bg-secondary/45 p-4 sm:p-5">
      {model.description && <p className="max-w-3xl text-sm leading-relaxed text-text-secondary">{model.description}</p>}
      <div>
        <div className="mb-2 flex items-center justify-between gap-3">
          <span className="text-xs text-text-secondary">Model ID for the API</span>
          <button onClick={() => void copyID()} className="focus-ring inline-flex min-h-8 items-center gap-1.5 rounded-md px-2 text-xs text-coral hover:bg-coral-light" aria-label={`Copy model ID for ${modelName(model)}`}>
            {copyState === "copied" ? <Check size={13} /> : <Copy size={13} />}
            {copyState === "copied" ? "Copied" : "Copy ID"}
          </button>
        </div>
        <code className="block select-all break-all text-xs leading-6 text-text-primary">{model.id}</code>
        {copyState === "failed" && <p role="status" className="mt-2 text-xs text-text-secondary">Select the model ID above to copy it.</p>}
      </div>
      {metadata.length > 0 && (
        <dl className="flex flex-wrap gap-x-8 gap-y-4 border-t border-border-dim pt-4">
          {metadata.map(({ label, value }) => (
            <div key={label}>
              <dt className="mb-1 text-xs text-text-secondary">{label}</dt>
              <dd className="text-sm text-text-primary">{value}</dd>
            </div>
          ))}
        </dl>
      )}
      {requirement && <p className="text-xs leading-relaxed text-text-secondary">{providerRequirementTitle(model.required_provider_capabilities)}.</p>}
    </div>
  );
}

export function ModelRow({ model, price, onChat }: { model: Model; price?: CatalogPrice; onChat: (model: Model) => void }) {
  const [expanded, setExpanded] = useState(false);
  const detailsID = useId();
  const context = modelContext(model);
  const features = modelFeatures(model);
  const requirement = providerRequirementBadge(model.required_provider_capabilities);
  const name = modelName(model);

  return (
    <li className="border-b border-border-dim last:border-0">
      <div className="grid grid-cols-[minmax(0,1fr)_auto] gap-x-5 gap-y-5 px-1 py-6 xl:grid-cols-[minmax(0,1fr)_90px_95px_95px_88px] xl:items-center">
        <div className="min-w-0">
          <button onClick={() => setExpanded((value) => !value)} aria-expanded={expanded} aria-controls={detailsID} className="focus-ring group max-w-full rounded-sm text-left">
            <span className="flex items-center gap-2 text-base font-medium leading-snug text-text-primary sm:text-lg">
              <span className="break-words">{name}</span>
              <ChevronDown size={15} aria-hidden="true" className={`shrink-0 text-text-tertiary transition-transform group-hover:text-coral ${expanded ? "rotate-180" : ""}`} />
            </span>
          </button>
          <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1.5 text-xs leading-relaxed text-text-secondary">
            {features.map((feature) => <span key={feature}>{FEATURE_LABELS.get(feature)}</span>)}
            {features.length === 0 && model.model_type && <span className="capitalize">{model.model_type}</span>}
            {model.trust_level === "hardware" && <span className="inline-flex items-center gap-1.5"><ShieldCheck size={13} className="text-coral" />Hardware attestation</span>}
          </div>
          {requirement && <p className="mt-2 text-xs text-text-secondary" title={providerRequirementTitle(model.required_provider_capabilities) ?? undefined}>{requirement}</p>}
        </div>

        <div className="col-span-2 row-start-2 grid grid-cols-3 gap-4 xl:col-span-3 xl:col-start-2 xl:row-start-1 xl:grid-cols-[90px_95px_95px] xl:gap-5">
          <div title={context ? `${context.toLocaleString("en-US")} tokens` : "Context length not listed"}>
            <p className="mb-1.5 text-xs text-text-secondary xl:hidden">Context</p>
            <p className="text-sm tabular-nums text-text-primary">{formatContext(context)}</p>
          </div>
          <div title={price ? "USD per 1 million input tokens" : "Input price not listed"}>
            <p className="mb-1.5 text-xs text-text-secondary xl:hidden">Input / 1M</p>
            <p className="text-sm tabular-nums text-text-primary">{formatPrice(price?.input)}</p>
          </div>
          <div title={price ? "USD per 1 million output tokens" : "Output price not listed"}>
            <p className="mb-1.5 text-xs text-text-secondary xl:hidden">Output / 1M</p>
            <p className="text-sm tabular-nums text-text-primary">{formatPrice(price?.output)}</p>
          </div>
        </div>

        <button onClick={() => onChat(model)} aria-label={`Start a new chat with ${name}`} className="focus-ring col-start-2 row-start-1 inline-flex min-h-10 items-center justify-center gap-2 self-start rounded-lg border border-border-dim px-3 text-sm font-medium text-coral transition-colors hover:border-coral/25 hover:bg-coral-light xl:col-start-5 xl:self-center">
          <MessageSquare size={14} aria-hidden="true" />
          Chat
        </button>
      </div>
      <div id={detailsID} hidden={!expanded} className="pb-5">{expanded && <ModelDetails model={model} />}</div>
    </li>
  );
}

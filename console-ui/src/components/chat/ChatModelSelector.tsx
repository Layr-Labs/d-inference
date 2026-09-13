"use client";

import { useEffect, useId, useRef, useState } from "react";
import { Check, ChevronDown, Search, SlidersHorizontal } from "lucide-react";
import { useStore } from "@/lib/store";
import { modelSupportsImages } from "@/lib/image-upload";
import { trackEvent } from "@/lib/google-analytics";

export function ChatModelSelector() {
  const models = useStore((s) => s.models);
  const selectedModel = useStore((s) => s.selectedModel);
  const setSelectedModel = useStore((s) => s.setSelectedModel);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const containerRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const popupId = useId();
  const titleId = useId();
  const selected = models.find((model) => model.id === selectedModel);
  const displayName = selected?.display_name || selectedModel.split("/").pop() || "Choose a model";
  const filtered = models.filter((model) => `${model.display_name ?? ""} ${model.id}`.toLowerCase().includes(query.toLowerCase()));

  useEffect(() => {
    if (!open) return;
    searchRef.current?.focus();
    const onPointerDown = (event: PointerEvent) => {
      if (!containerRef.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    return () => document.removeEventListener("pointerdown", onPointerDown);
  }, [open]);

  const close = () => {
    setOpen(false);
    triggerRef.current?.focus();
  };

  return (
    <div ref={containerRef} className="relative min-w-0">
      <button
        ref={triggerRef}
        type="button"
        aria-expanded={open}
        aria-haspopup="dialog"
        aria-controls={open ? popupId : undefined}
        aria-label={`Choose model: ${displayName}`}
        onClick={() => { setQuery(""); setOpen(!open); }}
        className="flex min-h-9 max-w-full items-center gap-2 rounded-lg px-2.5 text-xs font-medium text-text-secondary transition-colors hover:bg-bg-secondary hover:text-text-primary"
      >
        <SlidersHorizontal size={14} className="shrink-0" />
        <span className="max-w-[140px] truncate sm:max-w-[240px]">{displayName}</span>
        <ChevronDown size={13} className={`shrink-0 transition-transform ${open ? "rotate-180" : ""}`} />
      </button>
      {open && (
        <div
          id={popupId}
          role="dialog"
          aria-labelledby={titleId}
          onKeyDown={(event) => {
            if (event.key === "Escape") { event.preventDefault(); close(); }
            if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
            event.preventDefault();
            const options = Array.from(containerRef.current?.querySelectorAll<HTMLButtonElement>("[data-model-option]") ?? []);
            const index = options.indexOf(document.activeElement as HTMLButtonElement);
            const next = event.key === "ArrowDown" ? index + 1 : index - 1;
            if (next < 0) searchRef.current?.focus();
            else options[Math.min(next, options.length - 1)]?.focus();
          }}
          className="absolute bottom-full left-0 z-50 mb-3 w-[min(360px,calc(100vw-3rem))] overflow-hidden rounded-2xl border border-border-dim bg-bg-white shadow-xl"
        >
          <div className="px-4 pt-4 pb-3">
            <p id={titleId} className="mb-3 text-sm font-medium text-text-primary">Choose a model</p>
            <div className="flex items-center gap-2 rounded-lg bg-bg-secondary px-3">
              <Search size={14} className="text-text-tertiary" />
              <input ref={searchRef} value={query} onChange={(event) => setQuery(event.target.value)} aria-label="Search models" placeholder="Search models" className="min-w-0 flex-1 bg-transparent py-2.5 text-sm text-text-primary outline-none placeholder:text-text-tertiary" />
            </div>
          </div>
          <div className="max-h-[min(260px,35dvh)] overflow-y-auto px-2 pb-2">
            {filtered.map((model) => (
              <button
                key={model.id}
                type="button"
                data-model-option
                aria-pressed={selectedModel === model.id}
                onClick={() => {
                  setSelectedModel(model.id);
                  trackEvent("chat_model_selected", { model: model.id, quantization: model.quantization || "unknown" });
                  close();
                }}
                className={`flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left transition-colors hover:bg-bg-secondary ${selectedModel === model.id ? "bg-accent-brand-dim text-accent-brand" : "text-text-primary"}`}
              >
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium">{model.display_name || model.id.split("/").pop()}</p>
                  <p className="mt-1 text-xs text-text-secondary">{modelSupportsImages(model) ? "Text and images" : "Text"}{model.quantization ? ` · ${model.quantization}` : ""}</p>
                </div>
                {selectedModel === model.id && <Check size={16} className="shrink-0" />}
              </button>
            ))}
            {filtered.length === 0 && <p className="px-3 py-5 text-sm text-text-secondary">{models.length ? "No models match your search." : "No models are available yet."}</p>}
          </div>
        </div>
      )}
    </div>
  );
}

"use client";

import { useState, useRef, useCallback, useEffect } from "react";
import { Send, Download, Loader2, ChevronDown, X } from "lucide-react";
import { useStore } from "@/lib/store";
import { generateImage } from "@/lib/api";

const SIZE_OPTIONS = ["512x512", "768x768", "1024x1024"];

export default function ImagesPage() {
  const { models } = useStore();
  const [prompt, setPrompt] = useState("");
  const [negativePrompt, setNegativePrompt] = useState("");
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [size, setSize] = useState("1024x1024");
  const [count, setCount] = useState(1);
  const [steps, setSteps] = useState<number | undefined>(undefined);
  const [seed, setSeed] = useState<number | undefined>(undefined);
  const [selectedModel, setSelectedModel] = useState("");
  const [modelOpen, setModelOpen] = useState(false);

  const [generating, setGenerating] = useState(false);
  const [error, setError] = useState("");
  const [images, setImages] = useState<string[]>([]);
  const [lightbox, setLightbox] = useState<number | null>(null);

  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const imageModels = models.filter((m) => m.model_type === "image");

  // Auto-select first image model
  useEffect(() => {
    if (!selectedModel && imageModels.length > 0) {
      setSelectedModel(imageModels[0].id);
    }
  }, [imageModels, selectedModel]);

  // Close model dropdown on outside click
  useEffect(() => {
    if (!modelOpen) return;
    const handler = () => setModelOpen(false);
    document.addEventListener("click", handler);
    return () => document.removeEventListener("click", handler);
  }, [modelOpen]);

  // Auto-resize textarea
  useEffect(() => {
    const ta = textareaRef.current;
    if (ta) {
      ta.style.height = "auto";
      ta.style.height = Math.min(ta.scrollHeight, 160) + "px";
    }
  }, [prompt]);

  const handleGenerate = useCallback(async () => {
    if (!prompt.trim() || !selectedModel || generating) return;
    setGenerating(true);
    setError("");
    try {
      const res = await generateImage({
        model: selectedModel,
        prompt: prompt.trim(),
        negative_prompt: negativePrompt.trim() || undefined,
        n: count,
        size,
        steps,
        seed,
      });
      const newImages = res.data.map((d) => d.b64_json);
      setImages((prev) => [...newImages, ...prev]);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setGenerating(false);
    }
  }, [prompt, negativePrompt, selectedModel, count, size, steps, seed, generating]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        handleGenerate();
      }
    },
    [handleGenerate]
  );

  const downloadImage = useCallback((b64: string, index: number) => {
    const link = document.createElement("a");
    link.href = `data:image/png;base64,${b64}`;
    link.download = `eigeninference-${Date.now()}-${index}.png`;
    link.click();
  }, []);

  const displayModel = imageModels.find((m) => m.id === selectedModel);
  const displayModelName = displayModel?.display_name
    || selectedModel?.split("/").pop()
    || "Select model";

  return (
    <div className="flex-1 flex flex-col h-full">
      {/* Header */}
      <div className="border-b border-border-dim px-6 py-4">
        <h1 className="text-lg font-semibold text-text-primary">Image Generation</h1>
        <p className="text-sm text-text-tertiary mt-0.5">
          Generate images with FLUX models running on attested Apple Silicon
        </p>
      </div>

      {/* Main content */}
      <div className="flex-1 overflow-y-auto">
        <div className="max-w-5xl mx-auto px-6 py-6 space-y-6">
          {/* Prompt input */}
          <div className="bg-bg-secondary rounded-2xl shadow-lg p-4 space-y-3">
            <textarea
              ref={textareaRef}
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Describe the image you want to create..."
              rows={2}
              className="w-full bg-transparent text-text-primary placeholder:text-text-tertiary text-[15px] resize-none outline-none"
            />

            {/* Controls bar */}
            <div className="flex items-center justify-between gap-3 pt-1 border-t border-border-dim">
              <div className="flex items-center gap-2 flex-wrap">
                {/* Model selector */}
                <div className="relative">
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      setModelOpen(!modelOpen);
                    }}
                    className="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs text-text-tertiary hover:text-text-secondary hover:bg-bg-hover transition-all"
                  >
                    <span className="w-1.5 h-1.5 rounded-full bg-accent-green" />
                    <span className="font-mono">{displayModelName}</span>
                    <ChevronDown size={12} />
                  </button>
                  {modelOpen && imageModels.length > 0 && (
                    <div className="absolute bottom-full left-0 mb-1 w-72 bg-bg-secondary border border-border-subtle rounded-xl shadow-xl overflow-hidden z-50">
                      {imageModels.map((m) => {
                        const name = m.display_name || m.id.split("/").pop() || m.id;
                        return (
                          <button
                            key={m.id}
                            onClick={() => {
                              setSelectedModel(m.id);
                              setModelOpen(false);
                            }}
                            className={`w-full flex items-center gap-2 px-4 py-2.5 text-left text-sm hover:bg-bg-hover transition-colors ${
                              selectedModel === m.id
                                ? "text-accent-brand bg-accent-brand-dim/20"
                                : "text-text-secondary"
                            }`}
                          >
                            <span className="flex-1 font-mono text-xs truncate">{name}</span>
                          </button>
                        );
                      })}
                    </div>
                  )}
                </div>

                {/* Size */}
                <select
                  value={size}
                  onChange={(e) => setSize(e.target.value)}
                  className="px-2.5 py-1.5 rounded-lg text-xs text-text-tertiary bg-transparent hover:bg-bg-hover border border-border-dim transition-all cursor-pointer"
                >
                  {SIZE_OPTIONS.map((s) => (
                    <option key={s} value={s}>{s}</option>
                  ))}
                </select>

                {/* Count */}
                <select
                  value={count}
                  onChange={(e) => setCount(Number(e.target.value))}
                  className="px-2.5 py-1.5 rounded-lg text-xs text-text-tertiary bg-transparent hover:bg-bg-hover border border-border-dim transition-all cursor-pointer"
                >
                  {[1, 2, 3, 4].map((n) => (
                    <option key={n} value={n}>{n} image{n > 1 ? "s" : ""}</option>
                  ))}
                </select>

                {/* Advanced toggle */}
                <button
                  onClick={() => setShowAdvanced(!showAdvanced)}
                  className="px-2.5 py-1.5 rounded-lg text-xs text-text-tertiary hover:text-text-secondary hover:bg-bg-hover transition-all"
                >
                  {showAdvanced ? "Hide advanced" : "Advanced"}
                </button>
              </div>

              {/* Generate button */}
              <button
                onClick={handleGenerate}
                disabled={!prompt.trim() || !selectedModel || generating}
                className="flex items-center gap-2 px-4 py-2 rounded-xl bg-accent-brand hover:bg-accent-brand-hover text-white text-sm font-medium disabled:opacity-30 disabled:hover:bg-accent-brand transition-colors"
              >
                {generating ? (
                  <>
                    <Loader2 size={14} className="animate-spin" />
                    Generating...
                  </>
                ) : (
                  <>
                    <Send size={14} />
                    Generate
                  </>
                )}
              </button>
            </div>

            {/* Advanced options */}
            {showAdvanced && (
              <div className="flex items-center gap-4 pt-2 border-t border-border-dim">
                <div className="flex items-center gap-2">
                  <label className="text-xs text-text-tertiary">Negative prompt</label>
                  <input
                    type="text"
                    value={negativePrompt}
                    onChange={(e) => setNegativePrompt(e.target.value)}
                    placeholder="Things to avoid..."
                    className="px-2.5 py-1.5 rounded-lg text-xs text-text-secondary bg-bg-tertiary border border-border-dim w-48 outline-none focus:border-accent-brand transition-colors"
                  />
                </div>
                <div className="flex items-center gap-2">
                  <label className="text-xs text-text-tertiary">Steps</label>
                  <input
                    type="number"
                    value={steps ?? ""}
                    onChange={(e) => setSteps(e.target.value ? Number(e.target.value) : undefined)}
                    placeholder="Auto"
                    min={1}
                    max={100}
                    className="px-2.5 py-1.5 rounded-lg text-xs text-text-secondary bg-bg-tertiary border border-border-dim w-20 outline-none focus:border-accent-brand transition-colors"
                  />
                </div>
                <div className="flex items-center gap-2">
                  <label className="text-xs text-text-tertiary">Seed</label>
                  <input
                    type="number"
                    value={seed ?? ""}
                    onChange={(e) => setSeed(e.target.value ? Number(e.target.value) : undefined)}
                    placeholder="Random"
                    className="px-2.5 py-1.5 rounded-lg text-xs text-text-secondary bg-bg-tertiary border border-border-dim w-24 outline-none focus:border-accent-brand transition-colors"
                  />
                </div>
              </div>
            )}
          </div>

          {/* Error */}
          {error && (
            <div className="px-4 py-3 rounded-xl bg-accent-red-dim border border-accent-red/20 text-sm text-accent-red">
              {error}
            </div>
          )}

          {/* Empty state */}
          {images.length === 0 && !generating && (
            <div className="flex flex-col items-center justify-center py-20 text-center">
              <div className="w-16 h-16 rounded-2xl bg-accent-brand/10 flex items-center justify-center mb-4">
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" className="text-accent-brand">
                  <rect x="3" y="3" width="18" height="18" rx="2" />
                  <circle cx="8.5" cy="8.5" r="1.5" />
                  <path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21" />
                </svg>
              </div>
              <h3 className="text-text-secondary font-medium">No images yet</h3>
              <p className="text-sm text-text-tertiary mt-1 max-w-sm">
                Describe what you want to see and hit Generate. Images are created on hardware-attested Apple Silicon.
              </p>
            </div>
          )}

          {/* Generating skeleton */}
          {generating && (
            <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
              {Array.from({ length: count }).map((_, i) => (
                <div
                  key={`skeleton-${i}`}
                  className="aspect-square rounded-xl bg-bg-secondary border border-border-dim animate-pulse flex items-center justify-center"
                >
                  <Loader2 size={24} className="text-text-tertiary animate-spin" />
                </div>
              ))}
            </div>
          )}

          {/* Image grid */}
          {images.length > 0 && (
            <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
              {images.map((b64, i) => (
                <div
                  key={`img-${i}-${b64.slice(0, 20)}`}
                  className="group relative aspect-square rounded-xl overflow-hidden bg-bg-secondary border border-border-dim hover:border-accent-brand/30 transition-all cursor-pointer"
                  onClick={() => setLightbox(i)}
                >
                  <img
                    src={`data:image/png;base64,${b64}`}
                    alt={`Generated image ${i + 1}`}
                    className="w-full h-full object-cover"
                  />
                  <div className="absolute inset-0 bg-black/0 group-hover:bg-black/20 transition-colors" />
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      downloadImage(b64, i);
                    }}
                    className="absolute bottom-2 right-2 p-2 rounded-lg bg-black/50 text-white opacity-0 group-hover:opacity-100 hover:bg-black/70 transition-all"
                    title="Download"
                  >
                    <Download size={14} />
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {/* Lightbox */}
      {lightbox !== null && images[lightbox] && (
        <div
          className="fixed inset-0 z-50 bg-black/80 backdrop-blur-sm flex items-center justify-center p-8"
          onClick={() => setLightbox(null)}
        >
          <button
            onClick={() => setLightbox(null)}
            className="absolute top-4 right-4 p-2 rounded-lg text-white/70 hover:text-white hover:bg-white/10 transition-colors"
          >
            <X size={24} />
          </button>
          <img
            src={`data:image/png;base64,${images[lightbox]}`}
            alt="Full size"
            className="max-w-full max-h-full rounded-lg shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          />
          <button
            onClick={(e) => {
              e.stopPropagation();
              downloadImage(images[lightbox], lightbox);
            }}
            className="absolute bottom-6 right-6 flex items-center gap-2 px-4 py-2 rounded-lg bg-white/10 text-white hover:bg-white/20 transition-colors text-sm"
          >
            <Download size={14} />
            Download
          </button>
        </div>
      )}
    </div>
  );
}

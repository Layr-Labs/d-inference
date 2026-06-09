"use client";

import { useState, useRef, useCallback, useEffect } from "react";
import { Send, Square, ChevronDown, LogIn, Cpu, ImagePlus, X } from "lucide-react";
import { useStore } from "@/lib/store";
import { trackEvent } from "@/lib/google-analytics";
import { modelSupportsImages, MAX_IMAGES_PER_MESSAGE } from "@/lib/image-upload";
import { useImageUpload } from "@/hooks/useImageUpload";

interface ChatInputProps {
  onSend: (content: string, images: string[]) => void;
  onStop: () => void;
  isStreaming: boolean;
  authenticated?: boolean;
  onLogin?: () => void;
}

export function ChatInput({ onSend, onStop, isStreaming, authenticated = true, onLogin }: ChatInputProps) {
  const [input, setInput] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const { selectedModel, models, setSelectedModel, useMyMachine, setUseMyMachine } = useStore();
  const [modelOpen, setModelOpen] = useState(false);

  const selectedModelObj = models.find((m) => m.id === selectedModel);
  const supportsImages = modelSupportsImages(selectedModelObj);
  const {
    images,
    imgError,
    atLimit: atImageLimit,
    fileInputRef,
    removeImage,
    clearImages,
    handlePaste,
    handleFileInputChange,
  } = useImageUpload(supportsImages);

  const handleSend = useCallback(() => {
    const trimmed = input.trim();
    if ((!trimmed && images.length === 0) || isStreaming) return;
    onSend(trimmed, images);
    setInput("");
    clearImages();
    if (textareaRef.current) textareaRef.current.style.height = "auto";
  }, [input, images, isStreaming, onSend, clearImages]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        handleSend();
      }
    },
    [handleSend]
  );

  useEffect(() => {
    const ta = textareaRef.current;
    if (ta) {
      ta.style.height = "auto";
      ta.style.height = Math.min(ta.scrollHeight, 200) + "px";
    }
  }, [input]);

  useEffect(() => {
    if (!modelOpen) return;
    const handler = () => setModelOpen(false);
    document.addEventListener("click", handler);
    return () => document.removeEventListener("click", handler);
  }, [modelOpen]);

  const chatModels = models;
  const displayModel = selectedModelObj?.display_name
    || selectedModel?.split("/").pop()
    || "Select model";

  if (!authenticated) {
    return (
      <div className="bg-bg-primary/80 backdrop-blur-sm">
        <div className="max-w-4xl mx-auto px-3 sm:px-6 py-3 sm:py-4">
          <button
            onClick={() => {
              trackEvent("login_cta_clicked", {
                source: "chat_input",
              });
              onLogin?.();
            }}
            className="w-full flex items-center justify-center gap-2 bg-bg-tertiary rounded-2xl border border-border-dim
                       py-4 text-text-tertiary hover:text-text-secondary hover:border-border-subtle cursor-pointer transition-all"
          >
            <LogIn size={16} />
            <span className="text-sm font-medium">Sign in to start chatting</span>
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="bg-bg-primary/80 backdrop-blur-sm">
      <div className="max-w-4xl mx-auto px-3 sm:px-6 py-3 sm:py-4">
        <div className="relative flex flex-col gap-2 bg-bg-white rounded-2xl border border-border-dim
                        shadow-md focus-within:shadow-lg transition-all">
          {/* Staged image thumbnails */}
          {images.length > 0 && (
            <div className="flex flex-wrap gap-2 px-4 pt-3">
              {images.map((src, i) => (
                <div key={i} className="relative">
                  <img
                    src={src}
                    alt={`Attachment ${i + 1}`}
                    className="h-16 w-16 rounded-lg border border-border-dim object-cover"
                  />
                  <button
                    type="button"
                    onClick={() => removeImage(i)}
                    aria-label={`Remove image ${i + 1}`}
                    className="absolute -top-1.5 -right-1.5 flex items-center justify-center w-5 h-5 rounded-full bg-ink text-white border border-bg-white hover:opacity-90 transition-opacity"
                  >
                    <X size={11} />
                  </button>
                </div>
              ))}
            </div>
          )}

          {/* Textarea */}
          <textarea
            ref={textareaRef}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            onPaste={handlePaste}
            placeholder="Send a message..."
            rows={1}
            className="w-full bg-transparent px-4 pt-4 pb-1 text-text-primary placeholder:text-text-tertiary text-[15px] resize-none outline-none"
          />

          {imgError && (
            <p className="px-4 text-xs text-accent-red" role="alert">{imgError}</p>
          )}

          {/* Bottom bar */}
          <div className="flex items-center justify-between px-3 pb-3">
            {/* Left: model selector */}
            <div className="flex items-center gap-1">
              <div className="relative">
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    setModelOpen(!modelOpen);
                  }}
                  className="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs text-text-tertiary hover:text-text-secondary hover:bg-bg-hover border-2 border-transparent hover:border-border-subtle transition-all"
                >
                  <span className="w-1.5 h-1.5 rounded-full bg-teal shrink-0" />
                  <span className="font-mono truncate max-w-[120px] sm:max-w-none">{displayModel}</span>
                  <ChevronDown size={12} />
                </button>

                {modelOpen && chatModels.length > 0 && (
                  <div className="absolute bottom-full left-0 mb-1 w-[calc(100vw-3rem)] sm:w-80 bg-bg-white border border-border-dim rounded-xl shadow-lg overflow-hidden z-50">
                    {chatModels.map((m) => {
                      const name = m.display_name || m.id.split("/").pop() || m.id;
                      return (
                        <button
                          key={m.id}
                          onClick={() => {
                            setSelectedModel(m.id);
                            setModelOpen(false);
                            trackEvent("chat_model_selected", {
                              model: m.id,
                              quantization: m.quantization || "unknown",
                            });
                          }}
                          className={`w-full flex items-center gap-2 px-4 py-2.5 text-left text-sm hover:bg-bg-hover transition-colors ${
                            selectedModel === m.id
                              ? "text-coral bg-coral/10 font-semibold"
                              : "text-text-secondary"
                          }`}
                        >
                          <span className="flex-1 font-mono text-xs truncate">
                            {name}
                          </span>
                          {m.quantization && (
                            <span className="text-xs text-text-tertiary px-1.5 py-0.5 bg-bg-tertiary rounded border border-border-dim">
                              {m.quantization}
                            </span>
                          )}
                        </button>
                      );
                    })}
                  </div>
                )}
              </div>

              {/* My Machine (prefer self-route, paid fallback) toggle */}
              <button
                type="button"
                onClick={() => {
                  const next = !useMyMachine;
                  setUseMyMachine(next);
                  trackEvent("self_route_toggled", { enabled: next });
                }}
                title={
                  useMyMachine
                    ? "Prefer your own machine (free when it serves). If it's offline or busy, this falls back to the paid network so you're never stuck."
                    : "Prefer a Darkbloom node you run (free when it serves); falls back to the paid network if it can't"
                }
                aria-pressed={useMyMachine}
                className={`flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs border-2 transition-all ${
                  useMyMachine
                    ? "text-teal bg-teal/10 border-teal/40 font-semibold"
                    : "text-text-tertiary border-transparent hover:text-text-secondary hover:bg-bg-hover hover:border-border-subtle"
                }`}
              >
                <Cpu size={12} />
                <span className="hidden sm:inline">My Machine</span>
                {useMyMachine && <span className="text-[10px] opacity-80">· Free, else paid</span>}
              </button>

              {/* Image attach — only for vision models (e.g. Gemma 4) */}
              {supportsImages && (
                <>
                  <input
                    ref={fileInputRef}
                    type="file"
                    accept="image/png,image/jpeg,image/webp,image/gif"
                    multiple
                    onChange={handleFileInputChange}
                    className="hidden"
                  />
                  <button
                    type="button"
                    onClick={() => fileInputRef.current?.click()}
                    disabled={isStreaming || atImageLimit}
                    title={atImageLimit ? `Up to ${MAX_IMAGES_PER_MESSAGE} images` : "Attach image"}
                    aria-label="Attach image"
                    className="flex items-center px-2.5 py-1.5 rounded-lg text-xs text-text-tertiary hover:text-text-secondary hover:bg-bg-hover border-2 border-transparent hover:border-border-subtle transition-all disabled:opacity-30 disabled:hover:bg-transparent"
                  >
                    <ImagePlus size={14} />
                  </button>
                </>
              )}
            </div>

            {/* Right: Send / Stop */}
            <div className="flex items-center gap-1.5">
              {isStreaming ? (
                <button
                  onClick={onStop}
                  className="flex items-center justify-center w-9 h-9 rounded-xl bg-accent-red/20 hover:bg-accent-red/30 text-accent-red border-2 border-accent-red transition-colors"
                >
                  <Square size={16} />
                </button>
              ) : (
                <button
                  onClick={handleSend}
                  disabled={(!input.trim() && images.length === 0) || isStreaming}
                  className="flex items-center justify-center w-9 h-9 rounded-xl bg-coral border-2 border-ink text-white
                             disabled:opacity-30 disabled:border-border-subtle
                             hover:opacity-90
                             transition-all"
                >
                  <Send size={16} />
                </button>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

"use client";

import { useState, useRef, useCallback, useEffect } from "react";
import { Send, Square, ChevronDown } from "lucide-react";
import { useStore } from "@/lib/store";
interface ChatInputProps {
  onSend: (content: string) => void;
  onStop: () => void;
  isStreaming: boolean;
}

export function ChatInput({ onSend, onStop, isStreaming }: ChatInputProps) {
  const [input, setInput] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const { selectedModel, models, setSelectedModel } = useStore();
  const [modelOpen, setModelOpen] = useState(false);

  const handleSend = useCallback(() => {
    const trimmed = input.trim();
    if (!trimmed || isStreaming) return;
    onSend(trimmed);
    setInput("");
    if (textareaRef.current) textareaRef.current.style.height = "auto";
  }, [input, isStreaming, onSend]);

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

  // Filter out STT/transcription models — chat page is for text models only
  const chatModels = models.filter(
    (m) => m.model_type !== "stt" && m.model_type !== "transcription"
  );

  const selectedModelObj = chatModels.find((m) => m.id === selectedModel);
  const displayModel = selectedModelObj?.display_name
    || selectedModel?.split("/").pop()
    || "Select model";

  return (
    <div className="bg-bg-primary/80 backdrop-blur-sm">
      <div className="max-w-4xl mx-auto px-6 py-4">
        <div className="relative flex flex-col gap-2 bg-bg-secondary rounded-2xl shadow-lg
                        focus-within:shadow-xl focus-within:ring-1 focus-within:ring-accent-brand/20 transition-all">
          {/* Textarea */}
          <textarea
            ref={textareaRef}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Send a message..."
            rows={1}
            className="w-full bg-transparent px-4 pt-4 pb-1 text-text-primary placeholder:text-text-tertiary text-[15px] resize-none outline-none"
          />

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
                  className="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs text-text-tertiary hover:text-text-secondary hover:bg-bg-hover transition-all"
                >
                  <span className="w-1.5 h-1.5 rounded-full bg-accent-green" />
                  <span className="font-mono">{displayModel}</span>
                  <ChevronDown size={12} />
                </button>

                {modelOpen && chatModels.length > 0 && (
                  <div className="absolute bottom-full left-0 mb-1 w-80 bg-bg-secondary border border-border-subtle rounded-xl shadow-xl overflow-hidden z-50">
                    {chatModels.map((m) => {
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
                          <span className="flex-1 font-mono text-xs truncate">
                            {name}
                          </span>
                          {m.quantization && (
                            <span className="text-xs text-text-tertiary px-1.5 py-0.5 bg-bg-tertiary rounded">
                              {m.quantization}
                            </span>
                          )}
                        </button>
                      );
                    })}
                  </div>
                )}
              </div>
            </div>

            {/* Right: Send / Stop */}
            {isStreaming ? (
              <button
                onClick={onStop}
                className="flex items-center justify-center w-9 h-9 rounded-xl bg-danger/20 hover:bg-danger/30 text-danger transition-colors"
              >
                <Square size={16} />
              </button>
            ) : (
              <button
                onClick={handleSend}
                disabled={!input.trim() || isStreaming}
                className="flex items-center justify-center w-9 h-9 rounded-xl bg-accent-brand hover:bg-accent-brand-hover text-white disabled:opacity-30 disabled:hover:bg-accent-brand transition-colors"
              >
                <Send size={16} />
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

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

  // Close model dropdown on outside click
  useEffect(() => {
    if (!modelOpen) return;
    const handler = () => setModelOpen(false);
    document.addEventListener("click", handler);
    return () => document.removeEventListener("click", handler);
  }, [modelOpen]);

  const displayModel = selectedModel
    ? selectedModel.split("/").pop() || selectedModel
    : "Select model";

  return (
    <div className="border-t border-border-dim bg-bg-secondary/80 backdrop-blur-sm">
      <div className="max-w-3xl mx-auto px-6 py-4">
        <div className="relative flex flex-col gap-2 bg-bg-tertiary border border-border-subtle rounded-xl focus-within:border-accent-purple/40 transition-colors">
          {/* Textarea */}
          <textarea
            ref={textareaRef}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Send a message..."
            rows={1}
            className="w-full bg-transparent px-4 pt-3 pb-1 text-text-primary placeholder:text-text-tertiary text-[15px] resize-none outline-none"
          />

          {/* Bottom bar */}
          <div className="flex items-center justify-between px-3 pb-2.5">
            {/* Model selector */}
            <div className="relative">
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  setModelOpen(!modelOpen);
                }}
                className="flex items-center gap-1.5 px-2 py-1 rounded-md text-[11px] font-mono text-text-tertiary hover:text-text-secondary hover:bg-bg-hover transition-all"
              >
                <span className="w-1.5 h-1.5 rounded-full bg-accent-green" />
                {displayModel}
                <ChevronDown size={10} />
              </button>

              {modelOpen && models.length > 0 && (
                <div className="absolute bottom-full left-0 mb-1 w-72 bg-bg-elevated border border-border-subtle rounded-lg shadow-xl overflow-hidden z-50">
                  {models.map((m) => {
                    const name = m.id.split("/").pop() || m.id;
                    return (
                      <button
                        key={m.id}
                        onClick={() => {
                          setSelectedModel(m.id);
                          setModelOpen(false);
                        }}
                        className={`w-full flex items-center gap-2 px-3 py-2 text-left text-sm hover:bg-bg-hover transition-colors ${
                          selectedModel === m.id
                            ? "text-accent-green bg-accent-green-dim/20"
                            : "text-text-secondary"
                        }`}
                      >
                        <span className="flex-1 font-mono text-xs truncate">
                          {name}
                        </span>
                        {m.quantization && (
                          <span className="text-[10px] text-text-tertiary px-1.5 py-0.5 bg-bg-tertiary rounded">
                            {m.quantization}
                          </span>
                        )}
                      </button>
                    );
                  })}
                </div>
              )}
            </div>

            {/* Send / Stop */}
            {isStreaming ? (
              <button
                onClick={onStop}
                className="flex items-center justify-center w-8 h-8 rounded-lg bg-danger/20 hover:bg-danger/30 text-danger transition-colors"
              >
                <Square size={14} />
              </button>
            ) : (
              <button
                onClick={handleSend}
                disabled={!input.trim()}
                className="flex items-center justify-center w-8 h-8 rounded-lg bg-accent-purple hover:bg-accent-purple/80 text-white disabled:opacity-30 disabled:hover:bg-accent-purple transition-colors"
              >
                <Send size={14} />
              </button>
            )}
          </div>
        </div>

        <p className="text-center text-[10px] font-mono text-text-tertiary mt-2 tracking-wider">
          Private inference via hardware-attested providers
        </p>
      </div>
    </div>
  );
}

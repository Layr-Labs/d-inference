"use client";

import { useState, useRef, useCallback, useEffect } from "react";
import { Send, Square, ChevronDown, Mic, Loader2 } from "lucide-react";
import { useStore } from "@/lib/store";
import { transcribeAudio } from "@/lib/api";

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

  // Voice recording state
  const [recording, setRecording] = useState(false);
  const [transcribing, setTranscribing] = useState(false);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);

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

  // Find a transcription model from the model list
  const sttModel = models.find(
    (m) => m.model_type === "stt" || m.model_type === "transcription"
  );

  const startRecording = useCallback(async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mediaRecorder = new MediaRecorder(stream, {
        mimeType: MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
          ? "audio/webm;codecs=opus"
          : "audio/webm",
      });
      chunksRef.current = [];

      mediaRecorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data);
      };

      mediaRecorder.onstop = async () => {
        // Stop all tracks to release the mic
        stream.getTracks().forEach((t) => t.stop());

        const blob = new Blob(chunksRef.current, { type: "audio/webm" });
        if (blob.size === 0) return;

        setTranscribing(true);
        try {
          const result = await transcribeAudio(
            blob,
            sttModel?.id || "CohereLabs/cohere-transcribe-03-2026"
          );
          const text = result?.text?.trim();
          if (text) {
            setInput((prev) => (prev ? prev + " " + text : text));
            // Focus textarea so user sees the text and can edit/send
            setTimeout(() => textareaRef.current?.focus(), 100);
          }
        } catch (err) {
          console.error("Transcription failed:", err);
        } finally {
          setTranscribing(false);
        }
      };

      mediaRecorderRef.current = mediaRecorder;
      mediaRecorder.start();
      setRecording(true);
    } catch (err) {
      console.error("Microphone access denied:", err);
    }
  }, [sttModel]);

  const stopRecording = useCallback(() => {
    if (mediaRecorderRef.current && recording) {
      mediaRecorderRef.current.stop();
      mediaRecorderRef.current = null;
      setRecording(false);
    }
  }, [recording]);

  // Filter to text models only — image/STT models have their own pages
  const chatModels = models.filter(
    (m) => m.model_type !== "stt" && m.model_type !== "transcription" && m.model_type !== "image"
  );

  const selectedModelObj = chatModels.find((m) => m.id === selectedModel);
  const displayModel = selectedModelObj?.display_name
    || selectedModel?.split("/").pop()
    || "Select model";

  return (
    <div className="bg-bg-primary/80 backdrop-blur-sm">
      <div className="max-w-4xl mx-auto px-3 sm:px-6 py-3 sm:py-4">
        <div className="relative flex flex-col gap-2 bg-bg-white rounded-2xl border-[3px] border-ink
                        shadow-md focus-within:shadow-lg focus-within:translate-x-[-1px] focus-within:translate-y-[-1px] transition-all">
          {/* Textarea */}
          <textarea
            ref={textareaRef}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder={recording ? "Listening..." : "Send a message..."}
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
                  className="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs text-text-tertiary hover:text-text-secondary hover:bg-bg-hover border-2 border-transparent hover:border-border-subtle transition-all"
                >
                  <span className="w-1.5 h-1.5 rounded-full bg-teal shrink-0" />
                  <span className="font-mono truncate max-w-[120px] sm:max-w-none">{displayModel}</span>
                  <ChevronDown size={12} />
                </button>

                {modelOpen && chatModels.length > 0 && (
                  <div className="absolute bottom-full left-0 mb-1 w-[calc(100vw-3rem)] sm:w-80 bg-bg-white border-[3px] border-ink rounded-xl shadow-lg overflow-hidden z-50">
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
            </div>

            {/* Right: Mic + Send / Stop */}
            <div className="flex items-center gap-1.5">
              {/* Mic button — only shown when a transcription model is available */}
              {sttModel && (
                <button
                  onClick={recording ? stopRecording : startRecording}
                  disabled={transcribing || isStreaming}
                  className={`flex items-center justify-center w-9 h-9 rounded-xl border-2 transition-all
                    ${recording
                      ? "bg-accent-red/20 border-accent-red text-accent-red animate-pulse"
                      : "bg-transparent border-transparent text-text-tertiary hover:text-text-secondary hover:bg-bg-hover hover:border-border-subtle"
                    }
                    disabled:opacity-30`}
                  title={recording ? "Stop recording" : "Voice input"}
                >
                  {transcribing ? (
                    <Loader2 size={16} className="animate-spin" />
                  ) : (
                    <Mic size={16} />
                  )}
                </button>
              )}

              {/* Send / Stop */}
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
                  disabled={!input.trim() || isStreaming}
                  className="flex items-center justify-center w-9 h-9 rounded-xl bg-coral border-2 border-ink text-white
                             disabled:opacity-30 disabled:border-border-subtle
                             hover:translate-x-[-1px] hover:translate-y-[-1px] hover:shadow-[2px_2px_0_var(--ink)]
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

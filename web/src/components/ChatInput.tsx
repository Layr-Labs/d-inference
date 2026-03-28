"use client";

import { useState, useRef, useCallback, useEffect } from "react";
import { Send, Square, ChevronDown, Mic, MicOff, Paperclip } from "lucide-react";
import { useStore } from "@/lib/store";

interface ChatInputProps {
  onSend: (content: string) => void;
  onStop: () => void;
  onAudio: (blob: Blob, duration: number) => void;
  isStreaming: boolean;
  isTranscribing: boolean;
}

export function ChatInput({ onSend, onStop, onAudio, isStreaming, isTranscribing }: ChatInputProps) {
  const [input, setInput] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const { selectedModel, models, setSelectedModel } = useStore();
  const [modelOpen, setModelOpen] = useState(false);

  // Recording state
  const [recording, setRecording] = useState(false);
  const [recordingDuration, setRecordingDuration] = useState(0);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const startTimeRef = useRef<number>(0);

  const busy = isStreaming || isTranscribing;

  const handleSend = useCallback(() => {
    const trimmed = input.trim();
    if (!trimmed || busy) return;
    onSend(trimmed);
    setInput("");
    if (textareaRef.current) textareaRef.current.style.height = "auto";
  }, [input, busy, onSend]);

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

  // Recording controls
  const startRecording = useCallback(async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mediaRecorder = new MediaRecorder(stream, {
        mimeType: MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
          ? "audio/webm;codecs=opus"
          : "audio/webm",
      });
      mediaRecorderRef.current = mediaRecorder;
      chunksRef.current = [];
      startTimeRef.current = Date.now();

      mediaRecorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data);
      };

      mediaRecorder.onstop = () => {
        const blob = new Blob(chunksRef.current, { type: "audio/webm" });
        const duration = (Date.now() - startTimeRef.current) / 1000;
        stream.getTracks().forEach((t) => t.stop());
        onAudio(blob, duration);
      };

      mediaRecorder.start(250); // collect chunks every 250ms
      setRecording(true);
      setRecordingDuration(0);
      timerRef.current = setInterval(() => {
        setRecordingDuration((Date.now() - startTimeRef.current) / 1000);
      }, 100);
    } catch {
      // Permission denied or no mic
    }
  }, [onAudio]);

  const stopRecording = useCallback(() => {
    if (mediaRecorderRef.current?.state === "recording") {
      mediaRecorderRef.current.stop();
    }
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }
    setRecording(false);
    setRecordingDuration(0);
  }, []);

  // File upload handler
  const handleFileSelect = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0];
      if (!file) return;
      // Estimate duration from file size (rough: ~128kbps for mp3)
      const estimatedDuration = (file.size * 8) / 128000;
      onAudio(file, estimatedDuration);
      // Reset file input
      if (fileInputRef.current) fileInputRef.current.value = "";
    },
    [onAudio]
  );

  const displayModel = selectedModel
    ? selectedModel.split("/").pop() || selectedModel
    : "Select model";

  const formatDuration = (s: number) => {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${sec.toString().padStart(2, "0")}`;
  };

  return (
    <div className="border-t border-border-dim bg-bg-secondary/80 backdrop-blur-sm">
      <div className="max-w-3xl mx-auto px-6 py-4">
        <div className="relative flex flex-col gap-2 bg-bg-tertiary border border-border-subtle rounded-xl focus-within:border-accent-purple/40 transition-colors">
          {/* Recording indicator */}
          {recording && (
            <div className="flex items-center gap-3 px-4 pt-3">
              <span className="w-2.5 h-2.5 rounded-full bg-danger animate-pulse" />
              <span className="text-sm text-danger font-mono">
                Recording {formatDuration(recordingDuration)}
              </span>
              <button
                onClick={stopRecording}
                className="ml-auto text-xs text-text-tertiary hover:text-danger transition-colors"
              >
                Stop & Transcribe
              </button>
            </div>
          )}

          {/* Transcribing indicator */}
          {isTranscribing && (
            <div className="flex items-center gap-3 px-4 pt-3">
              <span className="w-2.5 h-2.5 rounded-full bg-accent-purple animate-pulse" />
              <span className="text-sm text-accent-purple font-mono">
                Transcribing audio...
              </span>
            </div>
          )}

          {/* Textarea */}
          {!recording && (
            <textarea
              ref={textareaRef}
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Send a message or record audio..."
              rows={1}
              className="w-full bg-transparent px-4 pt-3 pb-1 text-text-primary placeholder:text-text-tertiary text-[15px] resize-none outline-none"
            />
          )}

          {/* Bottom bar */}
          <div className="flex items-center justify-between px-3 pb-2.5">
            {/* Left: model selector + audio buttons */}
            <div className="flex items-center gap-1">
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
                      const isStt = m.model_type === "stt";
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
                          {isStt && (
                            <span className="text-[10px] text-accent-purple px-1.5 py-0.5 bg-accent-purple/10 rounded">
                              STT
                            </span>
                          )}
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

              {/* Audio file upload */}
              <input
                ref={fileInputRef}
                type="file"
                accept="audio/*"
                onChange={handleFileSelect}
                className="hidden"
              />
              <button
                onClick={() => fileInputRef.current?.click()}
                disabled={busy || recording}
                className="flex items-center justify-center w-7 h-7 rounded-md text-text-tertiary hover:text-text-secondary hover:bg-bg-hover disabled:opacity-30 transition-all"
                title="Upload audio file"
              >
                <Paperclip size={14} />
              </button>

              {/* Mic button */}
              {recording ? (
                <button
                  onClick={stopRecording}
                  className="flex items-center justify-center w-7 h-7 rounded-md bg-danger/20 text-danger hover:bg-danger/30 transition-colors"
                  title="Stop recording"
                >
                  <MicOff size={14} />
                </button>
              ) : (
                <button
                  onClick={startRecording}
                  disabled={busy}
                  className="flex items-center justify-center w-7 h-7 rounded-md text-text-tertiary hover:text-accent-purple hover:bg-accent-purple/10 disabled:opacity-30 transition-all"
                  title="Record audio"
                >
                  <Mic size={14} />
                </button>
              )}
            </div>

            {/* Right: Send / Stop */}
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
                disabled={!input.trim() || busy}
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

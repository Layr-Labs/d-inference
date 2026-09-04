"use client";

import { useState, useRef, useCallback, useEffect, useId } from "react";
import { ArrowUp, Square, LogIn, Cpu, ImagePlus, LockKeyhole, X } from "lucide-react";
import { useStore } from "@/lib/store";
import { trackEvent } from "@/lib/google-analytics";
import { modelSupportsImages, MAX_IMAGES_PER_MESSAGE } from "@/lib/image-upload";
import { useImageUpload } from "@/hooks/useImageUpload";
import { ChatModelSelector } from "@/components/chat/ChatModelSelector";

export interface SuggestedDraft {
  text: string;
  revision: number;
}

interface ChatInputProps {
  onSend: (content: string, images: string[]) => void;
  onStop: () => void;
  isStreaming: boolean;
  authenticated?: boolean;
  onLogin?: () => void;
  ready?: boolean;
  submitReady?: boolean;
  suggestedDraft?: SuggestedDraft;
  spacious?: boolean;
}

export function ChatInput({
  onSend, onStop, isStreaming, authenticated = true, onLogin, ready = true,
  submitReady = true, suggestedDraft, spacious = false,
}: ChatInputProps) {
  const [input, setInput] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const helpId = useId();
  // Keep the composer independent of token updates in the conversation.
  const selectedModel = useStore((s) => s.selectedModel);
  const models = useStore((s) => s.models);
  const useMyMachine = useStore((s) => s.useMyMachine);
  const setUseMyMachine = useStore((s) => s.setUseMyMachine);
  const selectedModelObj = models.find((model) => model.id === selectedModel);
  const supportsImages = modelSupportsImages(selectedModelObj);
  const canSubmit = authenticated && submitReady && !!selectedModel;
  const {
    images, imgError, atLimit: atImageLimit, fileInputRef,
    removeImage, clearImages, handlePaste, handleFileInputChange,
  } = useImageUpload(supportsImages);

  const handleSend = useCallback(() => {
    const trimmed = input.trim();
    if ((!trimmed && images.length === 0) || isStreaming || !canSubmit) return;
    onSend(trimmed, images);
    setInput("");
    clearImages();
    if (textareaRef.current) textareaRef.current.style.height = "auto";
  }, [input, images, isStreaming, canSubmit, onSend, clearImages]);

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
      // Enter used to confirm an IME candidate must never submit a prompt.
      if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing && event.keyCode !== 229) {
        event.preventDefault();
        handleSend();
      }
    },
    [handleSend],
  );

  useEffect(() => {
    if (!suggestedDraft) return;
    setInput(suggestedDraft.text);
    textareaRef.current?.focus();
  }, [suggestedDraft]);

  useEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea) return;
    textarea.style.height = "auto";
    textarea.style.height = Math.min(textarea.scrollHeight, 200) + "px";
  }, [input]);

  if (!authenticated) {
    return (
      <div className="mx-auto max-w-3xl">
        <div className="rounded-2xl border border-border-dim bg-bg-white p-5 shadow-sm sm:p-6">
          <p className="text-[15px] text-text-secondary">Start your first conversation.</p>
          <div className="mt-7 flex flex-wrap items-center justify-between gap-4">
            <span className="inline-flex items-center gap-2 text-xs text-text-secondary"><LockKeyhole size={14} /> End-to-end encrypted</span>
            <button
              type="button"
              onClick={() => {
                trackEvent("login_cta_clicked", { source: "chat_input" });
                onLogin?.();
              }}
              disabled={!ready}
              className="flex min-h-11 items-center justify-center gap-2 rounded-xl bg-accent-brand px-5 text-sm font-medium text-white transition-colors hover:bg-accent-brand-hover disabled:cursor-not-allowed disabled:opacity-50 dark:text-bg-primary"
            >
              <LogIn size={15} />
              {ready ? "Sign in to chat" : "Loading…"}
            </button>
          </div>
        </div>
        <p className="mt-5 text-center text-xs text-text-tertiary">Use your email to get started.</p>
      </div>
    );
  }

  return (
    <div className="mx-auto w-full max-w-3xl">
      <div className="relative rounded-2xl border border-border-dim bg-bg-white shadow-sm transition-[border-color,box-shadow] focus-within:border-accent-brand/40 focus-within:shadow-md">
        {images.length > 0 && (
          <div className="flex flex-wrap gap-3 px-5 pt-4">
            {images.map((src, index) => (
              <div key={index} className="relative">
                <img src={src} alt={`Attachment ${index + 1}`} className="h-16 w-16 rounded-lg border border-border-dim object-cover" />
                <button
                  type="button"
                  onClick={() => removeImage(index)}
                  aria-label={`Remove image ${index + 1}`}
                  className="absolute -top-2 -right-2 flex h-6 w-6 items-center justify-center rounded-full border border-border-dim bg-bg-white text-text-primary shadow-sm hover:bg-bg-secondary"
                ><X size={12} /></button>
              </div>
            ))}
          </div>
        )}

        <textarea
          ref={textareaRef}
          value={input}
          onChange={(event) => setInput(event.target.value)}
          onKeyDown={handleKeyDown}
          onPaste={handlePaste}
          aria-label="Message"
          aria-describedby={helpId}
          placeholder={supportsImages ? "Ask anything, or add an image…" : "Ask anything…"}
          rows={spacious ? 3 : 2}
          className={`chat-composer-input block max-h-[200px] w-full resize-none bg-transparent px-5 pt-5 pb-2 text-[15px] leading-relaxed text-text-primary outline-none placeholder:text-text-tertiary ${spacious ? "min-h-28" : "min-h-20"}`}
        />

        {imgError && <p className="px-5 pb-2 text-xs text-accent-red" role="alert">{imgError}</p>}

        <div className="flex items-end justify-between gap-1 px-2.5 pb-2.5 sm:items-center">
          <div className="flex min-w-0 flex-wrap items-center gap-0.5">
            <ChatModelSelector />

            <button
              type="button"
              onClick={() => {
                const next = !useMyMachine;
                setUseMyMachine(next);
                trackEvent("self_route_toggled", { enabled: next });
              }}
              title="Prefer your own machine. Free when it serves; uses the paid network when it is offline or busy."
              aria-label="Prefer my machine; paid network fallback"
              aria-pressed={useMyMachine}
              className={`flex min-h-9 items-center gap-1.5 rounded-lg px-2.5 text-xs transition-colors ${useMyMachine ? "bg-accent-brand-dim font-medium text-accent-brand" : "text-text-secondary hover:bg-bg-secondary hover:text-text-primary"}`}
            >
              <Cpu size={14} />
              <span className="hidden sm:inline">My machine</span>
            </button>

            {supportsImages && (
              <>
                <input ref={fileInputRef} type="file" accept="image/png,image/jpeg,image/webp,image/gif" multiple onChange={handleFileInputChange} className="hidden" aria-label="Choose images to attach" />
                <button
                  type="button"
                  onClick={() => fileInputRef.current?.click()}
                  disabled={isStreaming || atImageLimit}
                  title={atImageLimit ? `Up to ${MAX_IMAGES_PER_MESSAGE} images` : "Attach image"}
                  aria-label="Attach image"
                  className="flex h-9 w-9 items-center justify-center rounded-lg text-text-secondary transition-colors hover:bg-bg-secondary hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-40"
                ><ImagePlus size={16} /></button>
              </>
            )}
          </div>

          {isStreaming ? (
            <button type="button" onClick={onStop} aria-label="Stop generating" title="Stop generating" className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-ink text-bg-primary transition-opacity hover:opacity-80">
              <Square size={14} fill="currentColor" />
            </button>
          ) : (
            <button
              type="button"
              onClick={handleSend}
              aria-label="Send message"
              title={canSubmit ? "Send message" : "Waiting for your account and model to be ready"}
              disabled={(!input.trim() && images.length === 0) || !canSubmit}
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-accent-brand text-white transition-colors hover:bg-accent-brand-hover disabled:cursor-not-allowed disabled:bg-bg-secondary disabled:text-text-tertiary dark:text-bg-primary"
            ><ArrowUp size={19} /></button>
          )}
        </div>
      </div>
      <div id={helpId} className="mt-3 flex min-h-4 flex-wrap items-center justify-between gap-x-3 gap-y-1 px-1 text-[11px] text-text-tertiary">
        <span>{useMyMachine ? "Your machine preferred. Paid network fallback." : "Conversations are saved in this browser."}</span>
        <span className="hidden sm:inline">Enter to send <span className="px-1">·</span> Shift + Enter for a new line</span>
      </div>
    </div>
  );
}

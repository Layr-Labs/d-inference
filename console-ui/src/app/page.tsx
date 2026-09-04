"use client";

import { useEffect, useRef, useState } from "react";
import { ArrowDown } from "lucide-react";
import { useStore } from "@/lib/store";
import { fetchModels } from "@/lib/api";
import { useAuth } from "@/hooks/useAuth";
import { useChatStream } from "@/hooks/useChatStream";
import { ChatMessage } from "@/components/chat/ChatMessage";
import { ChatWelcome, ChatStarters } from "@/components/chat/ChatWelcome";
import { ChatInput, type SuggestedDraft } from "@/components/ChatInput";
import { TopBar } from "@/components/TopBar";
import { PreSendTrustBanner } from "@/components/PreSendTrustBanner";
import { InviteCodeBanner } from "@/components/InviteCodeBanner";

export default function ChatPage() {
  const chats = useStore((s) => s.chats);
  const activeChatId = useStore((s) => s.activeChatId);
  const setModels = useStore((s) => s.setModels);
  const { ready, authenticated, apiKeyReady, login } = useAuth();
  const { isStreaming, handleSend, handleStop, handleRetry } = useChatStream();
  const [suggestedDraft, setSuggestedDraft] = useState<SuggestedDraft>();
  const [modelLoadAttempt, setModelLoadAttempt] = useState(0);
  const [modelLoadFailed, setModelLoadFailed] = useState(false);
  const [showJump, setShowJump] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);
  const followReply = useRef(true);
  const activeChat = chats.find((c) => c.id === activeChatId);
  const hasMessages = authenticated && !!activeChat?.messages.length;

  useEffect(() => {
    if (!authenticated || !apiKeyReady) return;
    let cancelled = false;
    setModelLoadFailed(false);
    fetchModels()
      .then((models) => {
        if (!cancelled) setModels(models);
        return models;
      })
      .catch(() => {
        if (!cancelled) setModelLoadFailed(true);
      });
    return () => { cancelled = true; };
  }, [setModels, authenticated, apiKeyReady, modelLoadAttempt]);

  useEffect(() => {
    followReply.current = true;
    setShowJump(false);
    if (scrollRef.current) scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [activeChatId]);

  useEffect(() => {
    const area = scrollRef.current;
    if (area && followReply.current) area.scrollTop = area.scrollHeight;
  }, [activeChat?.messages]);

  return (
    <div className="flex h-full min-h-0 flex-col">
      <TopBar />

      <div className={`relative flex min-h-0 flex-1 flex-col ${hasMessages ? "" : "overflow-y-auto"}`}>
        {hasMessages && (
          <div
            ref={scrollRef}
            onScroll={() => {
              const area = scrollRef.current;
              if (!area) return;
              const nearBottom = area.scrollHeight - area.scrollTop - area.clientHeight < 100;
              followReply.current = nearBottom;
              setShowJump(!nearBottom);
            }}
            className="min-h-0 flex-1 overflow-y-auto pt-5 pb-8 sm:pt-8"
            aria-label="Conversation"
            role="region"
            tabIndex={0}
          >
            {activeChat.messages.map((msg, idx) => {
              const isLastAssistant = msg.role === "assistant" && !msg.streaming && idx === activeChat.messages.length - 1;
              return (
                <ChatMessage
                  key={msg.id}
                  message={msg}
                  onRetry={handleRetry}
                  retryable={(msg.error || isLastAssistant) && !isStreaming && apiKeyReady}
                />
              );
            })}
          </div>
        )}

        <div className={hasMessages ? "relative shrink-0 px-4 pb-4 sm:px-8 sm:pb-5" : "mx-auto my-auto w-full max-w-3xl px-5 py-6 sm:px-10 sm:py-8"}>
          {!hasMessages && <ChatWelcome authenticated={authenticated} />}

          {showJump && hasMessages && (
            <button
              type="button"
              onClick={() => {
                followReply.current = true;
                if (scrollRef.current) scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
                setShowJump(false);
              }}
              className="absolute -top-12 left-1/2 z-10 flex -translate-x-1/2 items-center gap-2 rounded-full border border-border-dim bg-bg-white px-3 py-2 text-xs text-text-secondary shadow-sm hover:text-text-primary"
            >
              <ArrowDown size={14} /> Latest message
            </button>
          )}

          <ChatInput
            onSend={(content, images) => {
              followReply.current = true;
              void handleSend(content, images);
            }}
            onStop={handleStop}
            isStreaming={isStreaming}
            authenticated={authenticated}
            onLogin={login}
            ready={ready}
            submitReady={apiKeyReady}
            suggestedDraft={suggestedDraft}
            spacious={!hasMessages}
          />

          {modelLoadFailed && authenticated && (
            <p className="mx-auto mt-3 max-w-3xl text-center text-xs text-text-secondary" role="alert">
              Models couldn’t be loaded. <button type="button" className="font-medium text-accent-brand underline underline-offset-4" onClick={() => setModelLoadAttempt((attempt) => attempt + 1)}>Try again</button>
            </p>
          )}

          {authenticated && !hasMessages && (
            <ChatStarters onSelect={(text) => setSuggestedDraft((draft) => ({ text, revision: (draft?.revision ?? 0) + 1 }))} />
          )}
          <PreSendTrustBanner visible={authenticated && !hasMessages} />
          {authenticated && !hasMessages && <InviteCodeBanner />}
        </div>
      </div>
    </div>
  );
}

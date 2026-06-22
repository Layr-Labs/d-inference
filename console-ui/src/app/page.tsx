"use client";

import { useEffect, useRef } from "react";
import { useStore } from "@/lib/store";
import { fetchModels } from "@/lib/api";
import { useAuth } from "@/hooks/useAuth";
import { useChatStream } from "@/hooks/useChatStream";
import { ChatMessage } from "@/components/chat/ChatMessage";
import { ChatInput } from "@/components/ChatInput";
import { TopBar } from "@/components/TopBar";
import { PreSendTrustBanner } from "@/components/PreSendTrustBanner";
import { Mail } from "lucide-react";
import { InviteCodeBanner } from "@/components/InviteCodeBanner";
import { trackEvent } from "@/lib/google-analytics";

const SUGGESTED_PROMPTS = [
  { label: "Explain quantum computing", prompt: "Explain quantum computing in simple terms" },
  { label: "Write a Python script", prompt: "Write a Python script that reads a CSV and generates a summary report" },
  { label: "Compare ML frameworks", prompt: "Compare PyTorch and JAX for research use cases" },
  { label: "Explain zero-knowledge proofs", prompt: "What are zero-knowledge proofs and how are they used in blockchain?" },
];

export default function ChatPage() {
  // Narrow store selectors so unrelated state changes don't re-render the page
  // (perf F3). chats/activeChatId are necessary to render the message list.
  const chats = useStore((s) => s.chats);
  const activeChatId = useStore((s) => s.activeChatId);
  const setModels = useStore((s) => s.setModels);

  const { ready, authenticated, apiKeyReady, login } = useAuth();
  const { isStreaming, handleSend, handleStop, handleRetry } = useChatStream();
  const scrollRef = useRef<HTMLDivElement>(null);

  const activeChat = chats.find((c) => c.id === activeChatId);

  // Load models once API key is ready.
  useEffect(() => {
    if (!authenticated || !apiKeyReady) return;
    fetchModels()
      .then(setModels)
      .catch(() => {
        // coordinator may be unreachable
      });
  }, [setModels, authenticated, apiKeyReady]);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [activeChat?.messages]);

  return (
    <div className="flex flex-col h-full">
      <TopBar />

      {!authenticated ? (
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center max-w-lg px-6">
            <h2 className="text-5xl text-ink mb-3" style={{ fontFamily: "'Louize', Georgia, serif", letterSpacing: "-0.03em" }}>
              Darkbloom
            </h2>
            <p className="text-base text-text-secondary mb-8 leading-relaxed">
              Private inference on verified hardware.
              <br />
              <span className="text-text-tertiary">Your prompts stay encrypted, your data stays yours.</span>
            </p>

            <button
              onClick={() => {
                trackEvent("login_cta_clicked", {
                  source: "chat_page_guest_hero",
                });
                login();
              }}
              disabled={!ready}
              className="inline-flex items-center justify-center gap-2 px-8 py-3 rounded-lg
                         bg-coral text-white font-bold text-sm
                         hover:opacity-90
                         disabled:opacity-40 disabled:cursor-not-allowed
                         transition-all"
            >
              <Mail size={16} />
              {!ready ? "Loading..." : "Sign In"}
            </button>

            <p className="mt-4 text-xs text-text-tertiary">
              Sign in with your email to get started
            </p>

            <p className="mt-12 text-xs font-mono text-text-tertiary tracking-wide">
              End-to-end encrypted · Apple Silicon · Decentralized
            </p>
          </div>
        </div>
      ) : !activeChat || activeChat.messages.length === 0 ? (
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center max-w-lg px-6">
            <h2 className="text-4xl text-ink mb-2" style={{ fontFamily: "'Louize', Georgia, serif", letterSpacing: "-0.03em" }}>
              Darkbloom
            </h2>
            <p className="text-sm text-text-tertiary mb-10">
              Private inference on verified hardware
            </p>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 mb-10">
              {SUGGESTED_PROMPTS.map(({ label, prompt }) => (
                <button
                  key={label}
                  onClick={() => {
                    trackEvent("suggested_prompt_click", {
                      prompt_label: label,
                    });
                    handleSend(prompt);
                  }}
                  className="text-left px-4 py-3 rounded-lg bg-bg-secondary/60
                             text-sm text-text-secondary hover:text-text-primary
                             hover:bg-bg-secondary transition-colors"
                >
                  {label}
                </button>
              ))}
            </div>

            <p className="text-xs font-mono text-text-tertiary tracking-wide">
              End-to-end encrypted · Apple Silicon · Decentralized
            </p>
          </div>
        </div>
      ) : (
        <div ref={scrollRef} className="flex-1 overflow-y-auto">
          <div className="space-y-1">
            {activeChat.messages.map((msg, idx) => {
              const isLastAssistant =
                msg.role === "assistant" &&
                !msg.streaming &&
                idx === activeChat.messages.length - 1;
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
          <div className="h-4" />
        </div>
      )}

      {authenticated && <InviteCodeBanner />}

      <PreSendTrustBanner
        visible={authenticated && (!activeChat || activeChat.messages.length === 0)}
      />

      <ChatInput
        onSend={handleSend}
        onStop={handleStop}
        isStreaming={isStreaming}
        authenticated={authenticated}
        onLogin={login}
      />
    </div>
  );
}

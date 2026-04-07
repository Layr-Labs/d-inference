"use client";

import { useEffect, useRef, useCallback, useState } from "react";
import { useStore } from "@/lib/store";
import { streamChat, fetchModels } from "@/lib/api";
import { useToastStore } from "@/hooks/useToast";
import { useAuth } from "@/hooks/useAuth";
import { ChatMessage } from "@/components/ChatMessage";
import { ChatInput } from "@/components/ChatInput";
import { TopBar } from "@/components/TopBar";
import { Lock, Cpu, Globe, Mail } from "lucide-react";
import { InviteCodeBanner } from "@/components/InviteCodeBanner";
import type { Message } from "@/lib/store";

function generateId() {
  return Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
}

const SUGGESTED_PROMPTS = [
  { label: "Explain quantum computing", prompt: "Explain quantum computing in simple terms" },
  { label: "Write a Python script", prompt: "Write a Python script that reads a CSV and generates a summary report" },
  { label: "Compare ML frameworks", prompt: "Compare PyTorch and JAX for research use cases" },
  { label: "Explain zero-knowledge proofs", prompt: "What are zero-knowledge proofs and how are they used in blockchain?" },
];

export default function ChatPage() {
  const {
    chats,
    activeChatId,
    createChat,
    addMessage,
    updateMessage,
    appendToMessage,
    appendToThinking,
    updateChatTitle,
    selectedModel,
    setModels,
  } = useStore();

  const { ready, authenticated, login } = useAuth();
  const addToast = useToastStore((s) => s.addToast);
  const abortRef = useRef<AbortController | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [isStreaming, setIsStreaming] = useState(false);

  const activeChat = chats.find((c) => c.id === activeChatId);

  // Load models on mount
  useEffect(() => {
    if (!authenticated) return;

    async function bootstrap() {
      try {
        const models = await fetchModels();
        setModels(models);
      } catch {
        // coordinator may be unreachable
      }
    }
    bootstrap();
  }, [setModels, authenticated]);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [activeChat?.messages]);

  const handleSend = useCallback(
    async (content: string) => {
      let chatId = activeChatId;
      if (!chatId) {
        chatId = createChat();
      }

      const chat = useStore.getState().chats.find((c) => c.id === chatId);
      if (chat && chat.messages.length === 0) {
        const title =
          content.length > 40 ? content.slice(0, 40) + "..." : content;
        updateChatTitle(chatId, title);
      }

      const userMsg: Message = {
        id: generateId(),
        role: "user",
        content,
        timestamp: Date.now(),
      };
      addMessage(chatId, userMsg);

      const assistantId = generateId();
      const assistantMsg: Message = {
        id: assistantId,
        role: "assistant",
        content: "",
        streaming: true,
        timestamp: Date.now(),
      };
      addMessage(chatId, assistantMsg);

      setIsStreaming(true);
      const abort = new AbortController();
      abortRef.current = abort;

      const currentChat = useStore
        .getState()
        .chats.find((c) => c.id === chatId);
      const allMessages = currentChat
        ? currentChat.messages
            .filter((m) => m.id !== assistantId)
            .map((m) => ({ role: m.role, content: m.content }))
        : [{ role: "user" as const, content }];

      try {
        await streamChat(
          allMessages,
          selectedModel,
          {
            onToken: (token) => {
              appendToMessage(chatId!, assistantId, token);
            },
            onThinking: (token) => {
              appendToThinking(chatId!, assistantId, token);
            },
            onMetrics: (metrics) => {
              updateMessage(chatId!, assistantId, {
                tps: metrics.tps,
                ttft: metrics.ttft,
                tokenCount: metrics.tokenCount,
              });
            },
            onDone: (trust, metrics) => {
              updateMessage(chatId!, assistantId, {
                streaming: false,
                trust,
                tps: metrics.tps,
                ttft: metrics.ttft,
                tokenCount: metrics.tokenCount,
              });
              setIsStreaming(false);
            },
            onError: (error) => {
              updateMessage(chatId!, assistantId, {
                content: `Error: ${error}`,
                streaming: false,
                error: true,
              });
              addToast(error);
              setIsStreaming(false);
            },
          },
          abort.signal
        );
      } catch (err) {
        if ((err as Error).name !== "AbortError") {
          const msg = (err as Error).message;
          updateMessage(chatId!, assistantId, {
            content: `Connection error: ${msg}`,
            streaming: false,
            error: true,
          });
          addToast(`Connection error: ${msg}`);
        }
        setIsStreaming(false);
      }
    },
    [
      activeChatId,
      createChat,
      addMessage,
      updateMessage,
      appendToMessage,
      appendToThinking,
      updateChatTitle,
      selectedModel,
      addToast,
    ]
  );

  const handleStop = useCallback(() => {
    abortRef.current?.abort();
    setIsStreaming(false);
  }, []);

  const handleRetry = useCallback(
    (errorMsgId: string) => {
      if (!activeChat || isStreaming) return;
      const messages = activeChat.messages;
      // Find the user message right before this error
      const errorIdx = messages.findIndex((m) => m.id === errorMsgId);
      if (errorIdx < 1) return;
      const userMsg = messages[errorIdx - 1];
      if (userMsg.role !== "user") return;

      // Reset the error message to streaming state
      updateMessage(activeChat.id, errorMsgId, {
        content: "",
        error: false,
        streaming: true,
        thinking: undefined,
      });

      setIsStreaming(true);
      const abort = new AbortController();
      abortRef.current = abort;

      // Rebuild message history up to (but not including) the error message
      const allMessages = messages
        .slice(0, errorIdx)
        .map((m) => ({ role: m.role, content: m.content }));

      streamChat(
        allMessages,
        selectedModel,
        {
          onToken: (token) => appendToMessage(activeChat.id, errorMsgId, token),
          onThinking: (token) => appendToThinking(activeChat.id, errorMsgId, token),
          onMetrics: (metrics) => updateMessage(activeChat.id, errorMsgId, {
            tps: metrics.tps, ttft: metrics.ttft, tokenCount: metrics.tokenCount,
          }),
          onDone: (trust, metrics) => {
            updateMessage(activeChat.id, errorMsgId, {
              streaming: false, trust,
              tps: metrics.tps, ttft: metrics.ttft, tokenCount: metrics.tokenCount,
            });
            setIsStreaming(false);
          },
          onError: (error) => {
            updateMessage(activeChat.id, errorMsgId, {
              content: `Error: ${error}`, streaming: false, error: true,
            });
            addToast(error);
            setIsStreaming(false);
          },
        },
        abort.signal
      ).catch((err) => {
        if ((err as Error).name !== "AbortError") {
          updateMessage(activeChat.id, errorMsgId, {
            content: `Connection error: ${(err as Error).message}`,
            streaming: false, error: true,
          });
        }
        setIsStreaming(false);
      });
    },
    [activeChat, isStreaming, selectedModel, updateMessage, appendToMessage, appendToThinking, addToast]
  );

  return (
    <div className="flex flex-col h-full">
      <TopBar />

      {!authenticated ? (
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center max-w-lg px-6">
            {/* Research badge */}
            <div className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full bg-gold-light border-2 border-gold text-ink text-xs font-bold mb-4 font-display">
              Research Preview
            </div>

            <h2 className="text-5xl font-display text-ink tracking-tight mb-3">
              Eigen<span className="text-coral">Inference</span>
            </h2>
            <p className="text-base text-text-secondary mb-8 leading-relaxed">
              Private AI inference through hardware-attested Apple Silicon providers.
              <br />
              Your prompts stay encrypted, your data stays yours.
            </p>

            <button
              onClick={login}
              disabled={!ready}
              className="inline-flex items-center justify-center gap-2 px-8 py-3 rounded-xl
                         bg-coral text-white font-bold text-base border-[3px] border-ink
                         hover:translate-x-[-2px] hover:translate-y-[-2px] hover:shadow-[4px_4px_0_var(--ink)]
                         disabled:opacity-40 disabled:cursor-not-allowed
                         transition-all"
            >
              <Mail size={18} />
              {!ready ? "Loading..." : "Sign In"}
            </button>

            <p className="mt-4 text-xs text-text-tertiary">
              Sign in with your email to get started
            </p>

            <div className="flex flex-wrap justify-center gap-3 mt-10">
              {[
                { icon: Lock, label: "End-to-end encrypted", color: "teal" },
                { icon: Cpu, label: "Apple Silicon native", color: "purple" },
                { icon: Globe, label: "Decentralized network", color: "blue" },
              ].map(({ icon: Icon, label, color }) => (
                <span
                  key={label}
                  className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full
                             bg-${color}-light border-2 border-${color} text-xs text-ink font-semibold`}
                >
                  <Icon size={12} />
                  {label}
                </span>
              ))}
            </div>
          </div>
        </div>
      ) : !activeChat || activeChat.messages.length === 0 ? (
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center max-w-lg px-6">
            {/* Hero illustration (floating) */}
            <div className="float-gentle mb-6">
              <svg width="80" height="80" viewBox="0 0 64 64" fill="none" className="mx-auto">
                <circle cx="32" cy="32" r="28" fill="var(--teal-light)" stroke="var(--ink)" strokeWidth="3"/>
                <path d="M22 28 Q22 20, 32 20 Q42 20, 42 28 L42 34 Q42 42, 32 44 Q22 42, 22 34Z" fill="var(--teal)" stroke="var(--ink)" strokeWidth="2"/>
                <polyline points="26,32 30,36 38,26" fill="none" stroke="white" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </div>

            <h2 className="text-4xl font-display text-ink tracking-tight mb-2">
              Eigen<span className="text-coral">Inference</span>
            </h2>
            <p className="text-base text-text-secondary mb-10 leading-relaxed">
              Private AI inference through hardware-attested providers.
              <br />
              <span className="text-xs text-text-tertiary font-display">This is an experimental research project &mdash; results may vary.</span>
            </p>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-8">
              {SUGGESTED_PROMPTS.map(({ label, prompt }) => (
                <button
                  key={label}
                  onClick={() => handleSend(prompt)}
                  className="text-left px-4 py-3 rounded-xl bg-bg-white border-[3px] border-ink
                             text-sm text-text-secondary hover:text-text-primary font-semibold
                             hover:translate-x-[-2px] hover:translate-y-[-2px]
                             hover:shadow-[4px_4px_0_var(--ink)] transition-all"
                >
                  {label}
                </button>
              ))}
            </div>

            <div className="flex flex-wrap justify-center gap-3">
              {[
                { icon: Lock, label: "End-to-end encrypted", color: "bg-teal-light border-teal" },
                { icon: Cpu, label: "Apple Silicon native", color: "bg-purple-light border-purple" },
                { icon: Globe, label: "Decentralized network", color: "bg-blue-light border-blue" },
              ].map(({ icon: Icon, label, color }) => (
                <span
                  key={label}
                  className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full
                             ${color} border-2 text-xs text-ink font-semibold`}
                >
                  <Icon size={12} />
                  {label}
                </span>
              ))}
            </div>
          </div>
        </div>
      ) : (
        <div ref={scrollRef} className="flex-1 overflow-y-auto">
          <div className="space-y-1">
            {activeChat.messages.map((msg) => (
              <ChatMessage
                key={msg.id}
                message={msg}
                onRetry={msg.error ? () => handleRetry(msg.id) : undefined}
              />
            ))}
          </div>
          <div className="h-4" />
        </div>
      )}

      {authenticated && <InviteCodeBanner />}

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

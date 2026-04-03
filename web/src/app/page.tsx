"use client";

import { useEffect, useRef, useCallback, useState } from "react";
import { useStore } from "@/lib/store";
import { streamChat, fetchModels } from "@/lib/api";
import { useToastStore } from "@/hooks/useToast";
import { useAuth } from "@/hooks/useAuth";
import { ChatMessage } from "@/components/ChatMessage";
import { ChatInput } from "@/components/ChatInput";
import { TopBar } from "@/components/TopBar";
import { Sparkles, Lock, Cpu, Globe, Mail } from "lucide-react";
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

  return (
    <div className="flex flex-col h-full">
      <TopBar />

      {!authenticated ? (
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center max-w-lg px-6">
            <div className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full bg-accent-amber/10 text-accent-amber text-xs font-medium mb-4">
              <span className="w-1.5 h-1.5 rounded-full bg-accent-amber animate-pulse" />
              Research Preview
            </div>
            <h2 className="text-3xl font-bold text-text-primary tracking-tight mb-2">
              Eigen<span className="font-normal text-text-secondary">Inference</span>
            </h2>
            <p className="text-base text-text-tertiary mb-8 leading-relaxed">
              Private AI inference through hardware-attested Apple Silicon providers.
              <br />
              Your prompts stay encrypted, your data stays yours.
            </p>

            <button
              onClick={login}
              disabled={!ready}
              className="inline-flex items-center justify-center gap-2 px-8 py-3 rounded-xl
                         bg-accent-brand text-white font-medium text-base
                         hover:bg-accent-brand-hover transition-colors
                         disabled:opacity-40 disabled:cursor-not-allowed
                         shadow-lg"
            >
              <Mail size={18} />
              {!ready ? "Loading..." : "Sign In"}
            </button>

            <p className="mt-4 text-xs text-text-tertiary">
              Sign in with your email to get started
            </p>

            <div className="flex flex-wrap justify-center gap-3 mt-10">
              {[
                { icon: Lock, label: "End-to-end encrypted" },
                { icon: Sparkles, label: "Secure Enclave attested" },
                { icon: Cpu, label: "Apple Silicon native" },
                { icon: Globe, label: "Decentralized network" },
              ].map(({ icon: Icon, label }) => (
                <span
                  key={label}
                  className="flex items-center gap-1.5 px-3 py-1.5 rounded-full
                             bg-bg-secondary text-xs text-text-tertiary"
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
            <h2 className="text-3xl font-bold text-text-primary tracking-tight mb-2">
              Eigen<span className="font-normal text-text-secondary">Inference</span>
            </h2>
            <p className="text-base text-text-tertiary mb-10 leading-relaxed">
              Private AI inference through hardware-attested providers.
              <br />
              <span className="text-xs">This is an experimental research project — results may vary.</span>
            </p>

            <div className="grid grid-cols-2 gap-3 mb-8">
              {SUGGESTED_PROMPTS.map(({ label, prompt }) => (
                <button
                  key={label}
                  onClick={() => handleSend(prompt)}
                  className="text-left px-4 py-3 rounded-xl bg-bg-secondary hover:bg-bg-tertiary
                             text-sm text-text-secondary hover:text-text-primary
                             shadow-sm hover:shadow-md transition-all"
                >
                  {label}
                </button>
              ))}
            </div>

            <div className="flex flex-wrap justify-center gap-3">
              {[
                { icon: Lock, label: "End-to-end encrypted" },
                { icon: Sparkles, label: "Secure Enclave attested" },
                { icon: Cpu, label: "Apple Silicon native" },
                { icon: Globe, label: "Decentralized network" },
              ].map(({ icon: Icon, label }) => (
                <span
                  key={label}
                  className="flex items-center gap-1.5 px-3 py-1.5 rounded-full
                             bg-bg-secondary text-xs text-text-tertiary"
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
              <ChatMessage key={msg.id} message={msg} />
            ))}
          </div>
          <div className="h-4" />
        </div>
      )}

      <ChatInput
        onSend={handleSend}
        onStop={handleStop}
        isStreaming={isStreaming}
      />
    </div>
  );
}

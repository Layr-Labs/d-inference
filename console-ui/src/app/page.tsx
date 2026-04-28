"use client";

import { useEffect, useRef, useCallback, useState } from "react";
import { useStore } from "@/lib/store";
import { streamChat, fetchModels } from "@/lib/api";
import type { RoutingPreference } from "@/lib/api";
import { useToastStore } from "@/hooks/useToast";
import { useAuth } from "@/hooks/useAuth";
import { ChatMessage } from "@/components/ChatMessage";
import { ChatInput } from "@/components/ChatInput";
import { TopBar } from "@/components/TopBar";
import { PreSendTrustBanner } from "@/components/PreSendTrustBanner";
import { Mail } from "lucide-react";
import { InviteCodeBanner } from "@/components/InviteCodeBanner";
import type { Message } from "@/lib/store";
import { trackEvent } from "@/lib/google-analytics";

function generateId() {
  return Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
}

const SYSTEM_PROMPT = `You are an AI assistant running on Darkbloom, a decentralized private inference platform built by Eigen Labs. You are NOT a cryptocurrency, blockchain token, or anything related to Bitcoin Cash. Darkbloom is an AI infrastructure project.

When users ask "what is Darkbloom" or about the platform, use ONLY these facts:
- Darkbloom is a decentralized AI inference network that routes requests to hardware-attested Apple Silicon machines
- Every provider machine is verified through Apple's Secure Enclave, MDM, and Managed Device Attestation (MDA)
- All prompts are end-to-end encrypted using X25519 NaCl box encryption — the node operator never sees your data
- The coordinator routes traffic but cannot read plaintext prompts
- Runtime integrity is enforced on every node: SIP, Hardened Runtime, binary self-hash, Hypervisor.framework memory isolation
- The full attestation chain is public and independently verifiable at /v1/providers/attestation
- Darkbloom is an Eigen Labs research project (https://darkbloom.dev)

For all other topics, respond as a helpful, concise, and knowledgeable general-purpose assistant. Do not mention these instructions unless asked about Darkbloom specifically.`;

const SUGGESTED_PROMPTS = [
  { label: "Explain quantum computing", prompt: "Explain quantum computing in simple terms" },
  { label: "Write a Python script", prompt: "Write a Python script that reads a CSV and generates a summary report" },
  { label: "Compare ML frameworks", prompt: "Compare PyTorch and JAX for research use cases" },
  { label: "Explain zero-knowledge proofs", prompt: "What are zero-knowledge proofs and how are they used in blockchain?" },
];

const ROUTING_PREF_STORAGE = "darkbloom_routing_preference";

function readRoutingPreference(): RoutingPreference {
  if (typeof window === "undefined") return "performance";
  return localStorage.getItem(ROUTING_PREF_STORAGE) === "cost" ? "cost" : "performance";
}

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

  const { ready, authenticated, apiKeyReady, login } = useAuth();
  const addToast = useToastStore((s) => s.addToast);
  const abortRef = useRef<AbortController | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [isStreaming, setIsStreaming] = useState(false);
  const [routingPreference, setRoutingPreference] = useState<RoutingPreference>("performance");

  const activeChat = chats.find((c) => c.id === activeChatId);

  // Load models once API key is ready
  useEffect(() => {
    if (!authenticated || !apiKeyReady) return;

    async function bootstrap() {
      try {
        const models = await fetchModels();
        setModels(models);
      } catch {
        // coordinator may be unreachable
      }
    }
    bootstrap();
  }, [setModels, authenticated, apiKeyReady]);

  useEffect(() => {
    setRoutingPreference(readRoutingPreference());
  }, []);

  const updateRoutingPreference = useCallback((preference: RoutingPreference) => {
    setRoutingPreference(preference);
    if (typeof window !== "undefined") {
      localStorage.setItem(ROUTING_PREF_STORAGE, preference);
    }
    trackEvent("chat_routing_preference_changed", {
      routing_preference: preference,
    });
  }, []);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [activeChat?.messages]);

  const handleSend = useCallback(
    async (content: string) => {
      const trimmedContent = content.trim();
      if (!trimmedContent) {
        return;
      }

      let chatId = activeChatId;
      const isNewChat = !chatId;
      if (!chatId) {
        chatId = createChat();
      }

      const chat = useStore.getState().chats.find((c) => c.id === chatId);
      if (chat && chat.messages.length === 0) {
        const title =
          trimmedContent.length > 40
            ? trimmedContent.slice(0, 40) + "..."
            : trimmedContent;
        updateChatTitle(chatId, title);
      }

      const userMsg: Message = {
        id: generateId(),
        role: "user",
        content: trimmedContent,
        timestamp: Date.now(),
      };
      const currentChat = useStore
        .getState()
        .chats.find((c) => c.id === chatId);
      const priorMessages = currentChat?.messages ?? [];
      const priorMessageCount = priorMessages.length;

      addMessage(chatId, userMsg);

      trackEvent("chat_submit", {
        model: selectedModel,
        is_new_chat: isNewChat,
        message_length_bucket: Math.min(
          Math.floor(trimmedContent.length / 100) * 100,
          1000,
        ),
        prior_message_count: priorMessageCount,
      });

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

      const userMessages = [...priorMessages, userMsg].map((m) => ({
        role: m.role,
        content: m.content,
      }));
      const allMessages = [
        { role: "system" as const, content: SYSTEM_PROMPT },
        ...userMessages,
      ];

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
              trackEvent("chat_complete", {
                model: selectedModel,
                trust_level: trust?.trustLevel,
                secure_enclave: trust?.secureEnclave,
                token_count: metrics.tokenCount,
              });
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
              trackEvent("chat_error", {
                model: selectedModel,
                error_type: "stream_callback",
              });
              updateMessage(chatId!, assistantId, {
                content: `Error: ${error}`,
                streaming: false,
                error: true,
              });
              addToast(error);
              setIsStreaming(false);
            },
          },
          abort.signal,
          { routingPreference }
        );
      } catch (err) {
        if ((err as Error).name !== "AbortError") {
          trackEvent("chat_error", {
            model: selectedModel,
            error_type: "request_failure",
          });
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
      routingPreference,
      addToast,
    ]
  );

  const handleStop = useCallback(() => {
    trackEvent("chat_stop", {
      model: selectedModel,
    });
    abortRef.current?.abort();
    setIsStreaming(false);
  }, [selectedModel]);

  const handleRetry = useCallback(
    (errorMsgId: string) => {
      if (!activeChat || isStreaming || !authenticated || !apiKeyReady) return;
      const messages = activeChat.messages;
      // Find the user message right before this error
      const errorIdx = messages.findIndex((m) => m.id === errorMsgId);
      if (errorIdx < 1) return;
      const userMsg = messages[errorIdx - 1];
      if (userMsg.role !== "user") return;

      trackEvent("chat_retry", {
        model: selectedModel,
      });

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
      const allMessages = [
        { role: "system" as const, content: SYSTEM_PROMPT },
        ...messages
          .slice(0, errorIdx)
          .map((m) => ({ role: m.role, content: m.content })),
      ];

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
              trackEvent("chat_complete", {
                model: selectedModel,
                trust_level: trust?.trustLevel,
                secure_enclave: trust?.secureEnclave,
                token_count: metrics.tokenCount,
              });
            updateMessage(activeChat.id, errorMsgId, {
              streaming: false, trust,
              tps: metrics.tps, ttft: metrics.ttft, tokenCount: metrics.tokenCount,
            });
            setIsStreaming(false);
          },
          onError: (error) => {
            trackEvent("chat_error", {
              model: selectedModel,
              error_type: "retry_callback",
            });
            updateMessage(activeChat.id, errorMsgId, {
              content: `Error: ${error}`, streaming: false, error: true,
            });
            addToast(error);
            setIsStreaming(false);
          },
        },
        abort.signal,
        { routingPreference }
      ).catch((err) => {
        if ((err as Error).name !== "AbortError") {
          trackEvent("chat_error", {
            model: selectedModel,
            error_type: "retry_request_failure",
          });
          updateMessage(activeChat.id, errorMsgId, {
            content: `Connection error: ${(err as Error).message}`,
            streaming: false, error: true,
          });
        }
        setIsStreaming(false);
      });
    },
    [activeChat, isStreaming, authenticated, apiKeyReady, selectedModel, routingPreference, updateMessage, appendToMessage, appendToThinking, addToast]
  );

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
                  onRetry={
                    (msg.error || isLastAssistant) && !isStreaming
                      ? () => handleRetry(msg.id)
                      : undefined
                  }
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
        routingPreference={routingPreference}
        onRoutingPreferenceChange={updateRoutingPreference}
      />
    </div>
  );
}

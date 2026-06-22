"use client";

import { useCallback, useRef, useState } from "react";
import { useStore, type Message } from "@/lib/store";
import { streamChat, type ChatMessage as ApiChatMessage } from "@/lib/api";
import { toApiMessages } from "@/lib/chat-messages";
import { useToastStore } from "@/hooks/useToast";
import { trackEvent } from "@/lib/google-analytics";

const SYSTEM_PROMPT = `You are an AI assistant running on Darkbloom, a decentralized private inference platform built by Eigen Labs. You are NOT a cryptocurrency, blockchain token, or anything related to Bitcoin Cash. Darkbloom is an AI infrastructure project.

When users ask "what is Darkbloom" or about the platform, use ONLY these facts:
- Darkbloom is a decentralized AI inference network that routes requests to hardware-attested Apple Silicon machines
- Every provider machine is verified through Apple's Secure Enclave, MDM, and Managed Device Attestation (MDA)
- All prompts are end-to-end encrypted using X25519 NaCl box encryption — the node operator never sees your data
- The coordinator routes traffic but cannot read plaintext prompts
- Runtime integrity is enforced on every node: SIP, Hardened Runtime, binary self-hash, Hypervisor.framework memory isolation
- The full attestation chain is public and independently verifiable at /v1/providers/attestation
- Darkbloom is an Eigen Labs project, currently in public alpha (https://darkbloom.dev)

For all other topics, respond as a helpful, concise, and knowledgeable general-purpose assistant. Do not mention these instructions unless asked about Darkbloom specifically.`;

function generateId() {
  return Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
}

interface RunOptions {
  chatId: string;
  msgId: string;
  apiMessages: ApiChatMessage[];
  model: string;
  selfRoute: boolean;
  /** error_type label for the in-band onError analytics event. */
  errorCallbackType: string;
  /** error_type label for a request-level (thrown) failure. */
  errorRequestType: string;
  /** Whether to toast on a request-level failure (send does, retry didn't). */
  toastOnRequestFailure: boolean;
}

/**
 * Unifies the chat send + retry stream orchestration that was near-duplicated
 * in app/page.tsx (proposal F3c). Batches per-token store writes with
 * requestAnimationFrame so a high-TPS reply triggers ~one store update per
 * frame instead of one per token (perf F3).
 */
export function useChatStream() {
  const addToast = useToastStore((s) => s.addToast);
  const abortRef = useRef<AbortController | null>(null);
  const [isStreaming, setIsStreaming] = useState(false);

  const createChat = useStore((s) => s.createChat);
  const addMessage = useStore((s) => s.addMessage);
  const updateMessage = useStore((s) => s.updateMessage);
  const appendToMessage = useStore((s) => s.appendToMessage);
  const appendToThinking = useStore((s) => s.appendToThinking);
  const updateChatTitle = useStore((s) => s.updateChatTitle);

  const runStream = useCallback(
    async (opts: RunOptions) => {
      const { chatId, msgId, apiMessages, model, selfRoute } = opts;
      setIsStreaming(true);
      const abort = new AbortController();
      abortRef.current = abort;

      // rAF token batching: accumulate tokens between frames, flush once.
      let pendingContent = "";
      let pendingThinking = "";
      let rafId: number | null = null;
      const flush = () => {
        rafId = null;
        if (pendingContent) {
          appendToMessage(chatId, msgId, pendingContent);
          pendingContent = "";
        }
        if (pendingThinking) {
          appendToThinking(chatId, msgId, pendingThinking);
          pendingThinking = "";
        }
      };
      const schedule = () => {
        if (rafId === null) rafId = requestAnimationFrame(flush);
      };
      const cancelPending = () => {
        if (rafId !== null) {
          cancelAnimationFrame(rafId);
          rafId = null;
        }
      };

      try {
        await streamChat(
          apiMessages,
          model,
          {
            onToken: (token) => {
              pendingContent += token;
              schedule();
            },
            onThinking: (token) => {
              pendingThinking += token;
              schedule();
            },
            onMetrics: (metrics) => {
              updateMessage(chatId, msgId, {
                tps: metrics.tps,
                ttft: metrics.ttft,
                tokenCount: metrics.tokenCount,
              });
            },
            onDone: (trust, metrics) => {
              cancelPending();
              flush();
              trackEvent("chat_complete", {
                model,
                trust_level: trust?.trustLevel,
                secure_enclave: trust?.secureEnclave,
                token_count: metrics.tokenCount,
              });
              updateMessage(chatId, msgId, {
                streaming: false,
                trust,
                tps: metrics.tps,
                ttft: metrics.ttft,
                tokenCount: metrics.tokenCount,
              });
              setIsStreaming(false);
            },
            onError: (error) => {
              cancelPending();
              trackEvent("chat_error", { model, error_type: opts.errorCallbackType });
              updateMessage(chatId, msgId, {
                content: `Error: ${error}`,
                streaming: false,
                error: true,
              });
              addToast(error);
              setIsStreaming(false);
            },
          },
          abort.signal,
          { selfRoute },
        );
      } catch (err) {
        cancelPending();
        if ((err as Error).name !== "AbortError") {
          trackEvent("chat_error", { model, error_type: opts.errorRequestType });
          const msg = (err as Error).message;
          updateMessage(chatId, msgId, {
            content: `Connection error: ${msg}`,
            streaming: false,
            error: true,
          });
          if (opts.toastOnRequestFailure) addToast(`Connection error: ${msg}`);
        }
        setIsStreaming(false);
      }
    },
    [appendToMessage, appendToThinking, updateMessage, addToast],
  );

  const handleSend = useCallback(
    async (content: string, images: string[] = []) => {
      const trimmedContent = content.trim();
      if (!trimmedContent && images.length === 0) return;

      let chatId = useStore.getState().activeChatId;
      const isNewChat = !chatId;
      if (!chatId) chatId = createChat();

      const chat = useStore.getState().chats.find((c) => c.id === chatId);
      if (chat && chat.messages.length === 0) {
        const base = trimmedContent || (images.length > 0 ? "Image" : "");
        const title = base.length > 40 ? base.slice(0, 40) + "..." : base;
        updateChatTitle(chatId, title);
      }

      const userMsg: Message = {
        id: generateId(),
        role: "user",
        content: trimmedContent,
        ...(images.length > 0 ? { images } : {}),
        timestamp: Date.now(),
      };
      const currentChat = useStore.getState().chats.find((c) => c.id === chatId);
      const priorMessages = currentChat?.messages ?? [];
      const priorMessageCount = priorMessages.length;

      addMessage(chatId, userMsg);

      const model = useStore.getState().selectedModel;
      trackEvent("chat_submit", {
        model,
        is_new_chat: isNewChat,
        message_length_bucket: Math.min(Math.floor(trimmedContent.length / 100) * 100, 1000),
        prior_message_count: priorMessageCount,
      });

      const assistantId = generateId();
      addMessage(chatId, {
        id: assistantId,
        role: "assistant",
        content: "",
        streaming: true,
        timestamp: Date.now(),
      });

      await runStream({
        chatId,
        msgId: assistantId,
        apiMessages: [
          { role: "system", content: SYSTEM_PROMPT },
          ...toApiMessages([...priorMessages, userMsg]),
        ],
        model,
        selfRoute: useStore.getState().useMyMachine,
        errorCallbackType: "stream_callback",
        errorRequestType: "request_failure",
        toastOnRequestFailure: true,
      });
    },
    [createChat, addMessage, updateChatTitle, runStream],
  );

  const handleStop = useCallback(() => {
    trackEvent("chat_stop", { model: useStore.getState().selectedModel });
    abortRef.current?.abort();
    setIsStreaming(false);
  }, []);

  const handleRetry = useCallback(
    (errorMsgId: string) => {
      const { activeChatId, chats, selectedModel, useMyMachine } = useStore.getState();
      const activeChat = chats.find((c) => c.id === activeChatId);
      if (!activeChat || isStreaming) return;
      const messages = activeChat.messages;
      const errorIdx = messages.findIndex((m) => m.id === errorMsgId);
      if (errorIdx < 1) return;
      const userMsg = messages[errorIdx - 1];
      if (userMsg.role !== "user") return;

      trackEvent("chat_retry", { model: selectedModel });

      updateMessage(activeChat.id, errorMsgId, {
        content: "",
        error: false,
        streaming: true,
        thinking: undefined,
      });

      void runStream({
        chatId: activeChat.id,
        msgId: errorMsgId,
        apiMessages: [
          { role: "system", content: SYSTEM_PROMPT },
          ...toApiMessages(messages.slice(0, errorIdx)),
        ],
        model: selectedModel,
        selfRoute: useMyMachine,
        errorCallbackType: "retry_callback",
        errorRequestType: "retry_request_failure",
        toastOnRequestFailure: false,
      });
    },
    [isStreaming, updateMessage, runStream],
  );

  return { isStreaming, handleSend, handleStop, handleRetry };
}

"use client";

import { useEffect, useRef, useCallback, useState } from "react";
import { useStore } from "@/lib/store";
import { streamChat, fetchModels, transcribeAudio } from "@/lib/api";
import { useToastStore } from "@/hooks/useToast";
import { ChatMessage } from "@/components/ChatMessage";
import { ChatInput } from "@/components/ChatInput";
import { TopBar } from "@/components/TopBar";
import { Shield, Zap, Lock, Globe } from "lucide-react";
import type { Message } from "@/lib/store";

function generateId() {
  return Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
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
    models,
    setModels,
  } = useStore();

  const addToast = useToastStore((s) => s.addToast);
  const abortRef = useRef<AbortController | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [isStreaming, setIsStreaming] = useState(false);
  const [isTranscribing, setIsTranscribing] = useState(false);

  const activeChat = chats.find((c) => c.id === activeChatId);

  // Auto-provision: generate API key if none exists or stale, then load models
  useEffect(() => {
    async function generateKey(coordUrl: string) {
      try {
        const res = await fetch("/api/auth/keys", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-coordinator-url": coordUrl,
          },
        });
        if (res.ok) {
          const { api_key } = await res.json();
          localStorage.setItem("dginf_api_key", api_key);
          return true;
        }
      } catch {
        // coordinator not reachable
      }
      return false;
    }

    async function bootstrap() {
      const coordUrl =
        localStorage.getItem("dginf_coordinator_url") ||
        process.env.NEXT_PUBLIC_COORDINATOR_URL ||
        "https://inference-test.openinnovation.dev";

      if (!localStorage.getItem("dginf_api_key")) {
        await generateKey(coordUrl);
      }

      try {
        const models = await fetchModels();
        setModels(models);
      } catch (e) {
        // If 401, the stored key is stale (coordinator restarted) — regenerate
        if (String(e).includes("401")) {
          localStorage.removeItem("dginf_api_key");
          if (await generateKey(coordUrl)) {
            try {
              setModels(await fetchModels());
            } catch {
              // still failing
            }
          }
        }
      }
    }
    bootstrap();
  }, [setModels]);

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
            onDone: (trust) => {
              updateMessage(chatId!, assistantId, {
                streaming: false,
                trust,
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
    ]
  );

  const handleStop = useCallback(() => {
    abortRef.current?.abort();
    setIsStreaming(false);
  }, []);

  const handleAudio = useCallback(
    async (blob: Blob, duration: number) => {
      let chatId = activeChatId;
      if (!chatId) {
        chatId = createChat();
      }

      const chat = useStore.getState().chats.find((c) => c.id === chatId);
      if (chat && chat.messages.length === 0) {
        updateChatTitle(chatId, "Audio transcription");
      }

      // Create a URL for the audio blob so we can play it back
      const audioUrl = URL.createObjectURL(blob);

      // Add user message showing audio was sent
      const userMsg: Message = {
        id: generateId(),
        role: "user",
        content: `[Audio: ${Math.round(duration)}s]`,
        audioUrl,
        audioDuration: duration,
        timestamp: Date.now(),
      };
      addMessage(chatId, userMsg);

      // Add assistant placeholder for transcription result
      const assistantId = generateId();
      const assistantMsg: Message = {
        id: assistantId,
        role: "assistant",
        content: "",
        streaming: true,
        timestamp: Date.now(),
      };
      addMessage(chatId, assistantMsg);

      setIsTranscribing(true);

      try {
        // Find an STT model, or use the selected model
        const sttModel =
          models.find((m) => m.model_type === "stt")?.id || selectedModel;

        const result = await transcribeAudio(blob, sttModel);

        updateMessage(chatId, assistantId, {
          content: result.text,
          streaming: false,
        });

        // If we got a transcription, also update the user message with the text
        if (result.text) {
          updateMessage(chatId, userMsg.id, {
            content: result.text,
            audioUrl,
            audioDuration: result.duration || duration,
          });
          // Update chat title with first bit of transcription
          const title =
            result.text.length > 40
              ? result.text.slice(0, 40) + "..."
              : result.text;
          updateChatTitle(chatId, title);
        }
      } catch (err) {
        const msg = (err as Error).message;
        updateMessage(chatId, assistantId, {
          content: `Transcription error: ${msg}`,
          streaming: false,
        });
        addToast(`Transcription error: ${msg}`);
      } finally {
        setIsTranscribing(false);
      }
    },
    [
      activeChatId,
      createChat,
      addMessage,
      updateMessage,
      updateChatTitle,
      selectedModel,
      models,
      addToast,
    ]
  );

  return (
    <div className="flex flex-col h-full">
      <TopBar />

      {!activeChat || activeChat.messages.length === 0 ? (
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center max-w-md px-6">
            <div className="w-16 h-16 rounded-2xl bg-accent-purple/10 border border-accent-purple/20 flex items-center justify-center mx-auto mb-6">
              <Shield size={28} className="text-accent-purple" />
            </div>
            <h2 className="text-xl font-semibold text-text-primary mb-2">
              DGInf
            </h2>
            <p className="text-sm text-text-tertiary mb-8 leading-relaxed">
              Private inference through decentralized,
              <br />
              hardware-attested Apple Silicon providers.
            </p>

            <div className="flex flex-wrap justify-center gap-2">
              {[
                { icon: Lock, label: "End-to-end encrypted" },
                { icon: Shield, label: "Secure Enclave attested" },
                { icon: Zap, label: "Apple Silicon native" },
                { icon: Globe, label: "Decentralized network" },
              ].map(({ icon: Icon, label }) => (
                <span
                  key={label}
                  className="flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-bg-tertiary border border-border-dim text-[11px] text-text-tertiary font-mono"
                >
                  <Icon size={11} />
                  {label}
                </span>
              ))}
            </div>
          </div>
        </div>
      ) : (
        <div ref={scrollRef} className="flex-1 overflow-y-auto">
          <div className="divide-y divide-border-dim/50">
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
        onAudio={handleAudio}
        isStreaming={isStreaming}
        isTranscribing={isTranscribing}
      />
    </div>
  );
}

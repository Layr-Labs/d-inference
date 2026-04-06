import { create } from "zustand";
import { persist } from "zustand/middleware";
import type { TrustMetadata, Model } from "./api";

export interface Chat {
  id: string;
  title: string;
  messages: Message[];
  createdAt: number;
}

export interface Message {
  id: string;
  role: "user" | "assistant";
  content: string;
  thinking?: string;
  trust?: TrustMetadata;
  streaming?: boolean;
  error?: boolean;
  timestamp: number;
  tps?: number;
  ttft?: number;
  tokenCount?: number;
}

interface AppState {
  // Chat state
  chats: Chat[];
  activeChatId: string | null;
  selectedModel: string;
  models: Model[];
  sidebarOpen: boolean;

  // Actions
  createChat: () => string;
  deleteChat: (id: string) => void;
  setActiveChat: (id: string) => void;
  addMessage: (chatId: string, msg: Message) => void;
  updateMessage: (chatId: string, msgId: string, update: Partial<Message>) => void;
  appendToMessage: (chatId: string, msgId: string, token: string) => void;
  appendToThinking: (chatId: string, msgId: string, token: string) => void;
  setSelectedModel: (model: string) => void;
  setModels: (models: Model[]) => void;
  setSidebarOpen: (open: boolean) => void;
  updateChatTitle: (chatId: string, title: string) => void;
}

function generateId(): string {
  return Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
}

export const useStore = create<AppState>()(
  persist(
    (set, get) => ({
      chats: [],
      activeChatId: null,
      selectedModel: "",
      models: [],
      sidebarOpen: typeof window !== "undefined" ? window.innerWidth >= 640 : true,

      createChat: () => {
        const id = generateId();
        const chat: Chat = {
          id,
          title: "New chat",
          messages: [],
          createdAt: Date.now(),
        };
        set((s) => ({
          chats: [chat, ...s.chats],
          activeChatId: id,
        }));
        return id;
      },

      deleteChat: (id) =>
        set((s) => {
          const chats = s.chats.filter((c) => c.id !== id);
          return {
            chats,
            activeChatId:
              s.activeChatId === id ? (chats[0]?.id ?? null) : s.activeChatId,
          };
        }),

      setActiveChat: (id) => set({ activeChatId: id }),

      addMessage: (chatId, msg) =>
        set((s) => ({
          chats: s.chats.map((c) =>
            c.id === chatId ? { ...c, messages: [...c.messages, msg] } : c
          ),
        })),

      updateMessage: (chatId, msgId, update) =>
        set((s) => ({
          chats: s.chats.map((c) =>
            c.id === chatId
              ? {
                  ...c,
                  messages: c.messages.map((m) =>
                    m.id === msgId ? { ...m, ...update } : m
                  ),
                }
              : c
          ),
        })),

      appendToMessage: (chatId, msgId, token) =>
        set((s) => ({
          chats: s.chats.map((c) =>
            c.id === chatId
              ? {
                  ...c,
                  messages: c.messages.map((m) =>
                    m.id === msgId ? { ...m, content: m.content + token } : m
                  ),
                }
              : c
          ),
        })),

      appendToThinking: (chatId, msgId, token) =>
        set((s) => ({
          chats: s.chats.map((c) =>
            c.id === chatId
              ? {
                  ...c,
                  messages: c.messages.map((m) =>
                    m.id === msgId
                      ? { ...m, thinking: (m.thinking || "") + token }
                      : m
                  ),
                }
              : c
          ),
        })),

      setSelectedModel: (model) => set({ selectedModel: model }),
      setModels: (models) => {
        const current = get().selectedModel;
        set({
          models,
          selectedModel: current || models[0]?.id || "",
        });
      },
      setSidebarOpen: (open) => set({ sidebarOpen: open }),
      updateChatTitle: (chatId, title) =>
        set((s) => ({
          chats: s.chats.map((c) =>
            c.id === chatId ? { ...c, title } : c
          ),
        })),
    }),
    {
      name: "eigeninference-store",
      partialize: (state) => ({
        chats: state.chats.map((c) => ({
          ...c,
          // Clear streaming flag on any messages that were mid-stream when page closed
          messages: c.messages.map((m) => ({ ...m, streaming: false })),
        })),
        activeChatId: state.activeChatId,
        selectedModel: state.selectedModel,
        sidebarOpen: state.sidebarOpen,
      }),
    }
  )
);

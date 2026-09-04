"use client";

import { useState } from "react";
import { useStore } from "@/lib/store";
import { Menu, ShieldCheck } from "lucide-react";
import { E2ELockIndicator } from "./E2ELockIndicator";
import { TrustExplainerModal } from "./TrustExplainerModal";

export function TopBar({ title }: { title?: string }) {
  const sidebarOpen = useStore((s) => s.sidebarOpen);
  const setSidebarOpen = useStore((s) => s.setSidebarOpen);
  const chatTitle = useStore((s) => s.chats.find((chat) => chat.id === s.activeChatId)?.title);
  const hasMessages = useStore((s) => !!s.chats.find((chat) => chat.id === s.activeChatId)?.messages.length);
  const lastTrust = useStore((s) => s.chats.find((chat) => chat.id === s.activeChatId)?.messages.filter((m) => m.role === "assistant" && m.trust).at(-1)?.trust);
  const [showExplainer, setShowExplainer] = useState(false);
  const isChat = !title || title === "Chat";
  const conversationTitle = hasMessages ? chatTitle || "Conversation" : "Chat";

  return (
    <>
      <header className="flex h-[64px] shrink-0 items-center gap-3 border-b border-border-dim px-4 sm:px-8">
        <button type="button" onClick={() => setSidebarOpen(true)} aria-label="Open navigation" aria-controls="console-navigation" aria-expanded={sidebarOpen} className="-ml-2 rounded-lg p-2 text-text-secondary hover:bg-bg-hover sm:hidden"><Menu size={19} /></button>
        <div className="flex min-w-0 items-center gap-3 text-[13px]">
          <span className="hidden text-text-tertiary sm:inline">Console</span><span className="hidden text-border-subtle sm:inline" aria-hidden="true">/</span>
          <span className="truncate font-medium text-text-primary">{isChat ? conversationTitle : title}</span>
        </div>
        <div className="ml-auto shrink-0">
          {isChat && hasMessages ? <E2ELockIndicator trust={lastTrust} onOpenExplainer={() => setShowExplainer(true)} /> : <button type="button" onClick={() => setShowExplainer(true)} className="flex items-center gap-2 rounded-lg px-2 py-2 text-xs text-text-secondary transition-colors hover:bg-bg-hover hover:text-accent-brand"><ShieldCheck size={15} /><span className="hidden sm:inline">How privacy works</span><span className="sm:hidden">Privacy</span></button>}
        </div>
      </header>
      <TrustExplainerModal open={showExplainer} onClose={() => setShowExplainer(false)} />
    </>
  );
}

"use client";

import { useState } from "react";
import { useStore } from "@/lib/store";
import { Menu } from "lucide-react";
import { E2ELockIndicator } from "./E2ELockIndicator";
import { TrustExplainerModal } from "./TrustExplainerModal";

export function TopBar({ title }: { title?: string }) {
  const sidebarOpen = useStore((s) => s.sidebarOpen);
  const setSidebarOpen = useStore((s) => s.setSidebarOpen);
  // Subscribe to derived primitives instead of the whole `chats` array so the
  // header doesn't re-render on every streamed token (perf F3): `hasMessages`
  // is a boolean and `lastTrust` only changes when a reply completes.
  const hasMessages = useStore((s) => {
    const c = s.chats.find((chat) => chat.id === s.activeChatId);
    return !!c && c.messages.length > 0;
  });
  const lastTrust = useStore((s) => {
    const c = s.chats.find((chat) => chat.id === s.activeChatId);
    return c?.messages.filter((m) => m.role === "assistant" && m.trust).at(-1)?.trust;
  });
  const [showExplainer, setShowExplainer] = useState(false);

  return (
    <>
      <header className="h-14 bg-bg-primary/80 backdrop-blur-sm flex items-center px-3 sm:px-5 gap-3 shrink-0 border-b border-border-dim">
        {!sidebarOpen && (
          <button
            onClick={() => setSidebarOpen(true)}
            className="p-2 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-primary transition-colors border-2 border-transparent hover:border-border-subtle"
          >
            <Menu size={18} />
          </button>
        )}
        {!sidebarOpen && (
          <div className="mr-3">
            <span className="text-xl text-ink tracking-tight" style={{ fontFamily: "'Louize', Georgia, serif" }}>
              Darkbloom
            </span>
          </div>
        )}
        {title && (
          <h1 className="text-base font-medium text-text-secondary">{title}</h1>
        )}

        {/* E2E lock indicator — shown when there's an active chat */}
        {hasMessages && (
          <div className="ml-auto">
            <E2ELockIndicator
              trust={lastTrust}
              onOpenExplainer={() => setShowExplainer(true)}
            />
          </div>
        )}
      </header>

      <TrustExplainerModal
        open={showExplainer}
        onClose={() => setShowExplainer(false)}
      />
    </>
  );
}

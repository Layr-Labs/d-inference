"use client";

import { useState } from "react";
import { Search, Trash2, X } from "lucide-react";
import { useStore } from "@/lib/store";

export function ConversationHistory({ onNavigate }: { onNavigate: () => void }) {
  const chats = useStore((s) => s.chats);
  const activeChatId = useStore((s) => s.activeChatId);
  const setActiveChat = useStore((s) => s.setActiveChat);
  const deleteChat = useStore((s) => s.deleteChat);
  const [query, setQuery] = useState("");
  const filtered = chats.filter((chat) => chat.title.toLowerCase().includes(query.trim().toLowerCase()));

  return (
    <section className="mt-5 border-t border-border-dim pt-4" aria-label="Conversation history">
      <div className="mb-2 flex items-center justify-between px-3">
        <h2 className="text-xs font-medium tracking-normal text-text-tertiary">Conversations</h2>
        <span className="text-[11px] tabular-nums text-text-tertiary">{chats.length}</span>
      </div>
      {(chats.length > 3 || query) && (
        <div className="relative mx-1 mb-2">
          <Search size={13} className="pointer-events-none absolute left-2.5 top-2.5 text-text-tertiary" />
          <input aria-label="Search conversations" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Find a conversation" className="h-8 w-full rounded-md border border-border-dim bg-bg-primary py-1 pl-8 pr-7 text-xs placeholder:text-text-tertiary" />
          {query && <button type="button" aria-label="Clear conversation search" onClick={() => setQuery("")} className="absolute right-1 top-1 rounded p-1 text-text-tertiary"><X size={14} /></button>}
        </div>
      )}
      {chats.length === 0 && <p className="px-3 py-1 text-xs leading-relaxed text-text-tertiary">Your conversations will appear here.</p>}
      {chats.length > 0 && filtered.length === 0 && <p className="px-3 py-2 text-xs text-text-tertiary">No matching conversations.</p>}
      {filtered.length > 0 && (
        <div className="space-y-0.5">
          {filtered.map((chat) => (
            <div key={chat.id} className={`group flex items-center rounded-lg ${activeChatId === chat.id ? "bg-bg-elevated text-text-primary" : "text-text-secondary hover:bg-bg-hover"}`}>
              <button type="button" onClick={() => { setActiveChat(chat.id); onNavigate(); }} className="min-w-0 flex-1 truncate rounded-lg px-3 py-2 text-left text-xs" title={chat.title} aria-current={activeChatId === chat.id ? "true" : undefined}>{chat.title}</button>
              <button type="button" onClick={() => deleteChat(chat.id)} aria-label={`Delete ${chat.title}`} className="mr-1 rounded-md p-2 text-text-tertiary transition-opacity hover:bg-accent-red-dim hover:text-accent-red sm:opacity-0 sm:group-hover:opacity-100 sm:focus-visible:opacity-100"><Trash2 size={13} /></button>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

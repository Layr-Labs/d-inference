"use client";

import { useStore } from "@/lib/store";
import {
  Plus,
  MessageSquare,
  Trash2,
  CreditCard,
  Settings,
  Cpu,
  X,
  Shield,
} from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";

export function Sidebar() {
  const {
    chats,
    activeChatId,
    setActiveChat,
    createChat,
    deleteChat,
    sidebarOpen,
    setSidebarOpen,
  } = useStore();
  const pathname = usePathname();

  if (!sidebarOpen) return null;

  return (
    <aside className="sidebar-animate w-64 h-screen flex flex-col bg-bg-secondary border-r border-border-dim shrink-0">
      {/* Header */}
      <div className="p-4 flex items-center justify-between border-b border-border-dim">
        <Link href="/" className="flex items-center gap-2 group">
          <div className="w-7 h-7 rounded-md bg-accent-purple/20 border border-accent-purple/30 flex items-center justify-center">
            <Shield size={14} className="text-accent-purple" />
          </div>
          <span className="font-mono text-sm font-semibold tracking-tight text-text-primary">
            DG<span className="text-accent-purple">Inf</span>
          </span>
        </Link>
        <button
          onClick={() => setSidebarOpen(false)}
          className="p-1 rounded hover:bg-bg-hover text-text-tertiary hover:text-text-secondary transition-colors"
        >
          <X size={16} />
        </button>
      </div>

      {/* New Chat */}
      <div className="p-3">
        <button
          onClick={() => createChat()}
          className="w-full flex items-center gap-2 px-3 py-2 rounded-lg border border-border-subtle hover:border-accent-purple/40 hover:bg-accent-purple-dim/20 text-text-secondary hover:text-text-primary transition-all text-sm font-mono"
        >
          <Plus size={14} />
          New chat
        </button>
      </div>

      {/* Chat list */}
      <div className="flex-1 overflow-y-auto px-3 space-y-0.5">
        {chats.map((chat) => (
          <div
            key={chat.id}
            className={`group flex items-center gap-2 px-3 py-2 rounded-lg cursor-pointer transition-all text-sm ${
              activeChatId === chat.id && pathname === "/"
                ? "bg-bg-elevated text-text-primary border border-border-subtle"
                : "text-text-secondary hover:bg-bg-hover hover:text-text-primary border border-transparent"
            }`}
            onClick={() => {
              setActiveChat(chat.id);
              if (pathname !== "/") window.location.href = "/";
            }}
          >
            <MessageSquare size={14} className="shrink-0 opacity-50" />
            <span className="truncate flex-1">{chat.title}</span>
            <button
              onClick={(e) => {
                e.stopPropagation();
                deleteChat(chat.id);
              }}
              className="opacity-0 group-hover:opacity-100 p-0.5 rounded hover:bg-danger/20 hover:text-danger transition-all"
            >
              <Trash2 size={12} />
            </button>
          </div>
        ))}
      </div>

      {/* Navigation */}
      <nav className="p-3 border-t border-border-dim space-y-0.5">
        {[
          { href: "/models", icon: Cpu, label: "Models" },
          { href: "/billing", icon: CreditCard, label: "Billing" },
          { href: "/settings", icon: Settings, label: "Settings" },
        ].map(({ href, icon: Icon, label }) => (
          <Link
            key={href}
            href={href}
            className={`flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all ${
              pathname === href
                ? "bg-bg-elevated text-text-primary border border-border-subtle"
                : "text-text-secondary hover:bg-bg-hover hover:text-text-primary border border-transparent"
            }`}
          >
            <Icon size={14} className="opacity-60" />
            {label}
          </Link>
        ))}
      </nav>

      {/* Footer */}
      <div className="p-4 border-t border-border-dim">
        <p className="text-[10px] font-mono text-text-tertiary uppercase tracking-widest">
          Decentralized Private Inference
        </p>
      </div>
    </aside>
  );
}

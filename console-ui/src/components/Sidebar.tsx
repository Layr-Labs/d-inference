"use client";

/* eslint-disable @next/next/no-html-link-for-pages */
import { useStore } from "@/lib/store";
import { useAuth } from "@/hooks/useAuth";
import { useTheme } from "@/components/providers/ThemeProvider";
import {
  Plus,
  MessageSquare,
  Trash2,
  CreditCard,
  Settings,
  Cpu,
  X,
  Server,
  Code,
  Activity,
  Coins,
  Trophy,
  LogOut,
  Sun,
  Moon,
} from "lucide-react";
import { usePathname, useRouter } from "next/navigation";
import { CommunityLinks } from "@/components/community/CommunityLinks";

export function Sidebar() {
  // Per-field selectors so the sidebar only re-renders when chat list / sidebar
  // state changes, not on unrelated store updates (perf F3).
  const chats = useStore((s) => s.chats);
  const activeChatId = useStore((s) => s.activeChatId);
  const setActiveChat = useStore((s) => s.setActiveChat);
  const createChat = useStore((s) => s.createChat);
  const deleteChat = useStore((s) => s.deleteChat);
  const sidebarOpen = useStore((s) => s.sidebarOpen);
  const setSidebarOpen = useStore((s) => s.setSidebarOpen);
  const pathname = usePathname();
  const router = useRouter();
  const { displayName, logout } = useAuth();
  const { theme, toggleTheme } = useTheme();

  if (!sidebarOpen) return null;

  const isChatActive = pathname === "/";
  const closeSidebarOnMobile = () => {
    if (window.innerWidth < 640) setSidebarOpen(false);
  };

  return (
    <aside className="sidebar-animate fixed inset-0 z-50 w-full sm:static sm:w-[260px] h-screen flex flex-col bg-bg-secondary sm:border-r sm:border-border-default shrink-0">
      {/* Brand header */}
      <div className="px-5 pt-5 pb-4 flex items-center justify-between">
        <a href="/" className="group" onClick={closeSidebarOnMobile}>
          <h1 className="font-display text-2xl text-ink tracking-[0.04em]">
            Darkbloom
          </h1>
          <p className="text-[9px] font-mono text-text-tertiary tracking-[0.12em] uppercase mt-1">
            An Eigen Labs project · Public Alpha
          </p>
        </a>
        <button
          onClick={() => setSidebarOpen(false)}
          className="p-1.5 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-primary transition-colors"
        >
          <X size={16} />
        </button>
      </div>

      {/* Primary navigation */}
      <nav className="px-3 space-y-1">
        {[
          { href: "/", icon: MessageSquare, label: "Chat" },
          { href: "/stats", icon: Activity, label: "Stats" },
          { href: "/leaderboard", icon: Trophy, label: "Leaderboard" },
          { href: "/providers", icon: Server, label: "Provider Dashboard" },
          { href: "/earn", icon: Coins, label: "Earn" },
          { href: "/api-console", icon: Code, label: "API" },
        ].map(({ href, icon: Icon, label }) => {
          const isActive =
            href === "/"
              ? pathname === "/"
              : pathname.startsWith(href);
          return (
            <a
              key={href}
              href={href}
              onClick={closeSidebarOnMobile}
              className={`flex items-center gap-3 px-3 py-2.5 rounded-r2 font-mono text-[12.5px] font-medium tracking-[0.02em] transition-all ${
                isActive
                  ? "bg-coral/10 text-coral font-semibold"
                  : "text-text-secondary hover:bg-bg-hover hover:text-text-primary"
              }`}
            >
              <Icon size={17} className={isActive ? "text-coral" : "opacity-55"} />
              {label}
            </a>
          );
        })}
      </nav>

      {/* Chat history — only visible on chat page */}
      {isChatActive && (
        <>
          <div className="px-3 mt-4">
            <button
              onClick={() => createChat()}
              className="w-full flex items-center justify-center gap-2 px-3 h-[38px] rounded-r2
                         bg-coral text-white font-mono text-[11px] font-medium uppercase
                         tracking-[0.07em] transition-all hover:bg-accent-brand-hover
                         hover:shadow-md active:scale-[0.985]"
            >
              <Plus size={15} />
              New chat
            </button>
          </div>

          <div className="flex-1 overflow-y-auto px-3 mt-2 space-y-1">
            {chats.map((chat) => (
              <div
                key={chat.id}
                className={`group flex items-center gap-2 px-3 py-2 rounded-lg cursor-pointer transition-all text-sm ${
                  activeChatId === chat.id
                    ? "bg-bg-elevated text-text-primary border-2 border-border-subtle font-semibold"
                    : "text-text-secondary hover:bg-bg-hover hover:text-text-primary border-2 border-transparent"
                }`}
                onClick={() => {
                  setActiveChat(chat.id);
                  if (pathname !== "/") router.push("/");
                  if (window.innerWidth < 640) setSidebarOpen(false);
                }}
              >
                <MessageSquare size={14} className="shrink-0 opacity-40" />
                <span className="truncate flex-1">{chat.title}</span>
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    deleteChat(chat.id);
                  }}
                  className="opacity-0 group-hover:opacity-100 p-1 rounded-md hover:bg-accent-red/10 hover:text-accent-red transition-all"
                >
                  <Trash2 size={12} />
                </button>
              </div>
            ))}
          </div>
        </>
      )}

      {/* Spacer when not on chat page */}
      {!isChatActive && <div className="flex-1" />}

      {/* Secondary navigation */}
      <nav className="px-3 pt-3 border-t border-border-dim space-y-1">
        {[
          { href: "/models", icon: Cpu, label: "Models" },
          { href: "/billing", icon: CreditCard, label: "Billing" },
          { href: "/settings", icon: Settings, label: "Settings" },
        ].map(({ href, icon: Icon, label }) => (
          <a
            key={href}
            href={href}
            onClick={closeSidebarOnMobile}
            className={`flex items-center gap-3 px-3 py-2 rounded-r2 font-mono text-[12.5px] font-medium tracking-[0.02em] transition-all ${
              pathname === href
                ? "bg-coral/10 text-coral font-semibold"
                : "text-text-secondary hover:bg-bg-hover hover:text-text-primary"
            }`}
          >
            <Icon size={16} className={pathname === href ? "text-coral" : "opacity-55"} />
            {label}
          </a>
        ))}
      </nav>

      {/* Alpha disclaimer */}
      <div className="px-4 py-2 border-t border-border-dim">
        <p className="text-[10px] text-text-tertiary leading-relaxed">
          Public alpha. Provided as-is for evaluation. Not for production use.
        </p>
      </div>

      {/* Community links */}
      <CommunityLinks />

      {/* User footer */}
      <div className="px-3 py-3 border-t border-border-dim">
        <div className="flex items-center gap-2">
          <div className="flex-1 min-w-0">
            {displayName && (
              <p className="text-xs text-text-secondary font-semibold truncate">{displayName}</p>
            )}
          </div>
          <button
            onClick={toggleTheme}
            className="p-1.5 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-secondary transition-colors"
            title={`Switch to ${theme === "light" ? "dark" : "light"} mode`}
          >
            {theme === "light" ? <Moon size={14} /> : <Sun size={14} />}
          </button>
          <button
            onClick={() => logout()}
            className="p-1.5 rounded-lg hover:bg-accent-red/10 text-text-tertiary hover:text-accent-red transition-colors"
            title="Sign out"
          >
            <LogOut size={14} />
          </button>
        </div>
      </div>
    </aside>
  );
}

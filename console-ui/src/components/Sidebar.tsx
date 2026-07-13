"use client";

/* eslint-disable @next/next/no-html-link-for-pages */
import { usePathname, useRouter } from "next/navigation";
import {
  Activity,
  Code,
  Coins,
  Cpu,
  CreditCard,
  LogOut,
  MessageSquare,
  Moon,
  PanelLeftClose,
  Plus,
  Server,
  Settings,
  Sun,
  Trash2,
  Trophy,
  type LucideIcon,
} from "lucide-react";
import { useStore } from "@/lib/store";
import { useAuth } from "@/hooks/useAuth";
import { useTheme } from "@/components/providers/ThemeProvider";
import { CommunityLinks } from "@/components/community/CommunityLinks";

interface NavigationItem {
  href: string;
  icon: LucideIcon;
  label: string;
}

const NAVIGATION_GROUPS: Array<{ label: string; items: NavigationItem[] }> = [
  {
    label: "Use the network",
    items: [
      { href: "/", icon: MessageSquare, label: "Chat" },
      { href: "/stats", icon: Activity, label: "Network stats" },
      { href: "/leaderboard", icon: Trophy, label: "Leaderboard" },
    ],
  },
  {
    label: "Provide",
    items: [
      { href: "/providers", icon: Server, label: "Provider fleet" },
      { href: "/earn", icon: Coins, label: "Earnings" },
    ],
  },
  {
    label: "Build",
    items: [
      { href: "/api-console", icon: Code, label: "API console" },
      { href: "/models", icon: Cpu, label: "Models" },
    ],
  },
];

const ACCOUNT_ITEMS: NavigationItem[] = [
  { href: "/billing", icon: CreditCard, label: "Billing" },
  { href: "/settings", icon: Settings, label: "Settings" },
];

function SidebarLink({ item, active, onNavigate }: { item: NavigationItem; active: boolean; onNavigate: () => void }) {
  const Icon = item.icon;
  return (
    <a
      href={item.href}
      onClick={onNavigate}
      aria-current={active ? "page" : undefined}
      className={`group relative flex h-9 items-center gap-2.5 rounded-lg px-3 text-[13px] transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand ${active ? "bg-accent-brand/10 font-semibold text-accent-brand" : "text-text-secondary hover:bg-bg-hover hover:text-text-primary"}`}
    >
      {active && <span className="absolute inset-y-2 left-0 w-0.5 rounded-r-full bg-accent-brand" />}
      <Icon size={15} strokeWidth={active ? 2.3 : 1.8} className={active ? "text-accent-brand" : "text-text-tertiary group-hover:text-text-secondary"} />
      <span>{item.label}</span>
    </a>
  );
}

export function Sidebar() {
  const chats = useStore((state) => state.chats);
  const activeChatId = useStore((state) => state.activeChatId);
  const setActiveChat = useStore((state) => state.setActiveChat);
  const createChat = useStore((state) => state.createChat);
  const deleteChat = useStore((state) => state.deleteChat);
  const sidebarOpen = useStore((state) => state.sidebarOpen);
  const setSidebarOpen = useStore((state) => state.setSidebarOpen);
  const pathname = usePathname();
  const router = useRouter();
  const { logout } = useAuth();
  const { theme, toggleTheme } = useTheme();

  if (!sidebarOpen) return null;

  const isChatActive = pathname === "/";
  const closeOnMobile = () => {
    if (window.innerWidth < 640) setSidebarOpen(false);
  };
  const isActive = (href: string) => href === "/" ? pathname === "/" : pathname.startsWith(href);
  return (
    <aside className="sidebar-animate fixed inset-0 z-50 flex h-screen w-full shrink-0 flex-col border-r border-border-default bg-bg-secondary sm:static sm:w-[224px]">
      <div className="px-4 pb-3 pt-4">
        <div className="flex items-start justify-between gap-3">
          <a href="/" onClick={closeOnMobile} className="min-w-0 rounded-lg focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand">
            <div className="min-w-0">
              <h1 className="truncate text-xl leading-none text-ink" style={{ fontFamily: "'Louize', Georgia, serif" }}>Darkbloom</h1>
              <p className="mt-1 truncate font-mono text-[9px] uppercase tracking-[0.14em] text-text-tertiary">Private inference</p>
            </div>
          </a>
          <button onClick={() => setSidebarOpen(false)} aria-label="Collapse navigation" title="Collapse navigation" className="rounded-lg p-1.5 text-text-tertiary transition-colors hover:bg-bg-hover hover:text-text-primary">
            <PanelLeftClose size={16} />
          </button>
        </div>
        <div className="mt-3 flex items-center justify-between rounded-lg border border-border-dim bg-bg-primary/65 px-2.5 py-2">
          <div className="flex items-center gap-2">
            <span className="h-1.5 w-1.5 rounded-full bg-accent-green" />
            <span className="font-mono text-[9px] uppercase tracking-wider text-text-secondary">Public alpha</span>
          </div>
          <span className="font-mono text-[8px] text-text-tertiary">LIVE</span>
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-2.5 pb-3">
        {NAVIGATION_GROUPS.map((group) => (
          <nav key={group.label} aria-label={group.label} className="mt-3 first:mt-1">
            <p className="mb-1 px-3 font-mono text-[9px] uppercase tracking-[0.14em] text-text-tertiary">{group.label}</p>
            <div className="space-y-0.5">
              {group.items.map((item) => <SidebarLink key={item.href} item={item} active={isActive(item.href)} onNavigate={closeOnMobile} />)}
            </div>
          </nav>
        ))}

        {isChatActive && (
          <div className="mt-4 border-t border-border-dim pt-3">
            <button onClick={() => createChat()} className="flex h-9 w-full items-center justify-center gap-2 rounded-lg bg-accent-brand text-xs font-semibold text-white transition-opacity hover:opacity-90">
              <Plus size={14} /> New conversation
            </button>
            <div className="mt-2 space-y-0.5">
              {chats.map((chat) => (
                <div
                  key={chat.id}
                  role="button"
                  tabIndex={0}
                  onClick={() => {
                    setActiveChat(chat.id);
                    if (pathname !== "/") router.push("/");
                    closeOnMobile();
                  }}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault();
                      setActiveChat(chat.id);
                    }
                  }}
                  className={`group flex items-center gap-2 rounded-lg px-3 py-2 text-xs transition-colors ${activeChatId === chat.id ? "bg-bg-elevated font-medium text-text-primary" : "text-text-secondary hover:bg-bg-hover hover:text-text-primary"}`}
                >
                  <MessageSquare size={12} className="shrink-0 text-text-tertiary" />
                  <span className="min-w-0 flex-1 truncate">{chat.title}</span>
                  <button onClick={(event) => { event.stopPropagation(); deleteChat(chat.id); }} aria-label={`Delete ${chat.title}`} className="rounded p-1 text-text-tertiary opacity-0 transition-opacity hover:bg-accent-red/10 hover:text-accent-red group-hover:opacity-100 focus:opacity-100">
                    <Trash2 size={11} />
                  </button>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>

      <div className="border-t border-border-dim px-2.5 py-2">
        <nav aria-label="Account" className="space-y-0.5">
          {ACCOUNT_ITEMS.map((item) => <SidebarLink key={item.href} item={item} active={isActive(item.href)} onNavigate={closeOnMobile} />)}
        </nav>
      </div>

      <CommunityLinks />

      <div className="border-t border-border-dim p-2.5">
        <div className="grid grid-cols-2 gap-1">
          <button onClick={toggleTheme} aria-label={`Switch to ${theme === "light" ? "dark" : "light"} mode`} className="flex items-center gap-2 rounded-lg px-2 py-2 text-left text-[11px] text-text-secondary transition-colors hover:bg-bg-hover hover:text-text-primary">
            {theme === "light" ? <Moon size={13} /> : <Sun size={13} />}
            <span>Appearance</span>
          </button>
          <button onClick={() => logout()} aria-label="Sign out" className="flex items-center justify-end gap-2 rounded-lg px-2 py-2 text-[11px] text-text-secondary transition-colors hover:bg-accent-red/10 hover:text-accent-red">
            <span>Sign out</span>
            <LogOut size={13} />
          </button>
        </div>
        <p className="mt-1 px-2 font-mono text-[8px] leading-3 text-text-tertiary">Public alpha · evaluation use only</p>
      </div>
    </aside>
  );
}

"use client";

/* eslint-disable @next/next/no-html-link-for-pages */
import { useCallback } from "react";
import { usePathname, useRouter } from "next/navigation";
import { BookOpen, LogIn, LogOut, Moon, PanelLeftClose, PanelLeftOpen, Plus, Sun } from "lucide-react";
import { useStore } from "@/lib/store";
import { useAuth } from "@/hooks/useAuth";
import { useTheme } from "@/components/providers/ThemeProvider";
import { CommunityLinks } from "@/components/community/CommunityLinks";
import { BloomMark } from "./brand/BloomMark";
import { ACCOUNT_ITEMS, NAVIGATION_GROUPS, isNavigationActive } from "./navigation/items";
import { NavigationLink } from "./navigation/NavigationLink";
import { ConversationHistory } from "./navigation/ConversationHistory";
import { useSidebarDialog } from "./navigation/useSidebarDialog";

export function Sidebar() {
  const createChat = useStore((s) => s.createChat);
  const sidebarOpen = useStore((s) => s.sidebarOpen);
  const setSidebarOpen = useStore((s) => s.setSidebarOpen);
  const pathname = usePathname();
  const router = useRouter();
  const { ready, authenticated, displayName, login, logout } = useAuth();
  const { theme, toggleTheme } = useTheme();
  const close = useCallback(() => setSidebarOpen(false), [setSidebarOpen]);
  const { ref, mobile } = useSidebarDialog(sidebarOpen, close);
  const closeOnMobile = () => { if (window.innerWidth < 640) close(); };
  const startChat = () => {
    createChat();
    if (pathname !== "/") { router.push("/"); }
    closeOnMobile();
  };

  if (!sidebarOpen) {
    return (
      <aside className="hidden w-[60px] shrink-0 flex-col items-center border-r border-border-dim bg-bg-secondary px-2 py-5 sm:flex" aria-label="Collapsed navigation">
        <a href="/" aria-label="Darkbloom home" className="mb-5 rounded p-1 text-accent-brand"><BloomMark size={24} /></a>
        <button type="button" onClick={() => setSidebarOpen(true)} aria-label="Expand navigation" title="Expand navigation (⌘/Ctrl B)" className="mb-4 rounded-lg p-2.5 text-text-tertiary hover:bg-bg-hover"><PanelLeftOpen size={18} /></button>
        <nav aria-label="Main navigation" className="w-full space-y-1">
          {NAVIGATION_GROUPS.flatMap((group) => group.items).map((item) => <NavigationLink key={item.href} item={item} active={isNavigationActive(pathname, item.href)} collapsed />)}
        </nav>
        <nav aria-label="Account" className="mt-auto w-full space-y-1 pt-4">
          {ACCOUNT_ITEMS.map((item) => <NavigationLink key={item.href} item={item} active={isNavigationActive(pathname, item.href)} collapsed />)}
        </nav>
      </aside>
    );
  }

  return (
    <>
      <div onClick={close} className="fixed inset-0 z-40 bg-black/25 backdrop-blur-[2px] sm:hidden" aria-hidden="true" />
      <aside ref={ref} id="console-navigation" role={mobile ? "dialog" : undefined} aria-modal={mobile ? true : undefined} aria-label="Console navigation" className="sidebar-animate fixed inset-y-0 left-0 z-50 flex h-dvh w-[min(300px,85vw)] shrink-0 flex-col border-r border-border-dim bg-bg-secondary sm:static sm:w-[244px]">
        <div className="px-5 pb-3 pt-6">
          <div className="flex items-center gap-3">
            <a href="/" onClick={closeOnMobile} className="flex min-w-0 flex-1 items-center gap-2.5 rounded text-ink">
              <BloomMark size={26} className="shrink-0 text-accent-brand" />
              <span className="font-logo text-[27px] leading-none tracking-tight">Darkbloom</span>
            </a>
            <button type="button" onClick={close} aria-label="Collapse navigation" title="Collapse navigation (⌘/Ctrl B)" className="-mr-2 rounded-lg p-2 text-text-tertiary hover:bg-bg-hover hover:text-text-primary"><PanelLeftClose size={16} /></button>
          </div>
          <div className="mb-5 mt-2.5 flex items-center gap-2 pl-[36px] text-[11px] text-text-tertiary">
            <span>Console</span><span className="rounded border border-border-default px-1.5 py-0.5 text-[10px] leading-none">Alpha</span>
          </div>
          <button type="button" onClick={startChat} className="flex h-10 w-full items-center justify-between rounded-lg bg-accent-brand px-3 text-[13px] font-medium text-white transition-colors hover:bg-accent-brand-hover dark:text-bg-primary"><span>New conversation</span><Plus size={16} /></button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-3 pb-5">
          {NAVIGATION_GROUPS.map((group) => (
            <nav key={group.label} aria-label={group.label} className="mt-5 first:mt-2">
              <p className="mb-2 px-3 text-[11px] font-medium text-text-tertiary">{group.label}</p>
              <div className="space-y-0.5">{group.items.map((item) => <NavigationLink key={item.href} item={item} active={isNavigationActive(pathname, item.href)} onNavigate={closeOnMobile} />)}</div>
            </nav>
          ))}
          {pathname === "/" && <ConversationHistory onNavigate={closeOnMobile} />}
        </div>
        <div className="px-3 pb-2">
          <nav aria-label="Account" className="space-y-0.5">{ACCOUNT_ITEMS.map((item) => <NavigationLink key={item.href} item={item} active={isNavigationActive(pathname, item.href)} onNavigate={closeOnMobile} />)}</nav>
          <a href="https://github.com/Layr-Labs/d-inference/tree/master/docs" target="_blank" rel="noopener noreferrer" className="mt-1 flex min-h-10 items-center gap-3 rounded-lg px-3 text-[13px] text-text-secondary hover:bg-bg-hover"><BookOpen size={17} strokeWidth={1.7} />Documentation</a>
        </div>
        <CommunityLinks />
        <div className="flex items-center gap-2 border-t border-border-dim px-4 py-3">
          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-accent-brand-dim text-xs font-medium text-accent-brand">{displayName?.slice(0, 1).toUpperCase() || "D"}</div>
          <div className="min-w-0 flex-1"><p className="truncate text-xs font-medium text-text-primary">{authenticated ? displayName || "Workspace" : "Guest workspace"}</p><p className="mt-0.5 text-[10px] text-text-tertiary">Public alpha</p></div>
          <button type="button" onClick={toggleTheme} aria-label={`Switch to ${theme === "light" ? "dark" : "light"} mode`} title="Change appearance" className="rounded-lg p-2 text-text-tertiary hover:bg-bg-hover hover:text-text-primary">{theme === "light" ? <Moon size={16} /> : <Sun size={16} />}</button>
          <button type="button" disabled={!ready} onClick={() => authenticated ? logout() : login()} aria-label={authenticated ? "Sign out" : "Sign in"} title={authenticated ? "Sign out" : "Sign in"} className="rounded-lg p-2 text-text-tertiary hover:bg-bg-hover hover:text-text-primary disabled:opacity-40">{authenticated ? <LogOut size={16} /> : <LogIn size={16} />}</button>
        </div>
      </aside>
    </>
  );
}

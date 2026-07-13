"use client";

import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { PanelLeftOpen } from "lucide-react";
import { Sidebar } from "./Sidebar";
import { Toasts } from "./Toasts";
import { ProviderSlackPopup } from "./community/ProviderSlackPopup";
import { useStore, STORE_NAME } from "@/lib/store";

export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const sidebarOpen = useStore((state) => state.sidebarOpen);
  const setSidebarOpen = useStore((state) => state.setSidebarOpen);

  // The store uses `skipHydration` so the first client render matches the server
  // (no React #418 hydration mismatch). Now that we're mounted, restore the
  // persisted state, then apply the responsive sidebar default for first-time
  // visitors on small screens (where the sidebar is a full-screen overlay).
  useEffect(() => {
    const firstVisit =
      typeof window !== "undefined" &&
      window.localStorage.getItem(STORE_NAME) === null;
    useStore.persist.rehydrate();
    if (firstVisit && typeof window !== "undefined" && window.innerWidth < 640) {
      useStore.getState().setSidebarOpen(false);
    }
  }, []);

  // Device-linking page — no shell
  if (pathname === "/link") {
    return <>{children}</>;
  }

  // Render the shell + page immediately. Auth readiness is progressive
  // enhancement: the Privy SDK loads as a lazy chunk after first paint and
  // auth-dependent affordances (sidebar account state, login CTA) reconcile
  // when it resolves — so Privy is off the LCP critical path (perf F1/F2).
  return (
    <div className="flex h-screen overflow-hidden bg-bg-primary">
      <Sidebar />
      {!sidebarOpen && (
        <aside className={`${pathname === "/stats" ? "flex" : "hidden sm:flex"} w-11 shrink-0 flex-col items-center border-r border-border-default bg-bg-secondary py-3`} aria-label="Collapsed navigation">
          <button
            type="button"
            onClick={() => setSidebarOpen(true)}
            aria-label="Expand navigation"
            title="Expand navigation"
            className="rounded-lg p-2 text-text-tertiary transition-colors hover:bg-bg-hover hover:text-text-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand"
          >
            <PanelLeftOpen size={16} />
          </button>
        </aside>
      )}
      <main className="flex-1 flex flex-col overflow-y-auto">{children}</main>
      <ProviderSlackPopup />
      <Toasts />
    </div>
  );
}

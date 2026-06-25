"use client";

import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { Sidebar } from "./Sidebar";
import { Toasts } from "./Toasts";
import { ProviderSlackPopup } from "./community/ProviderSlackPopup";
import { useStore, STORE_NAME } from "@/lib/store";

export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();

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
      <main className="flex-1 flex flex-col overflow-y-auto">{children}</main>
      <ProviderSlackPopup />
      <Toasts />
    </div>
  );
}

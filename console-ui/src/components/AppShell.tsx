"use client";

import { usePathname } from "next/navigation";
import { Sidebar } from "./Sidebar";
import { Toasts } from "./Toasts";
import { ProviderSlackPopup } from "./community/ProviderSlackPopup";

export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();

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

"use client";

import { useAuth } from "@/hooks/useAuth";
import { usePathname } from "next/navigation";
import { Sidebar } from "./Sidebar";
import { Toasts } from "./Toasts";

export function AppShell({ children }: { children: React.ReactNode }) {
  const { ready, authenticated } = useAuth();
  const pathname = usePathname();

  // Device-linking page — no shell
  if (pathname === "/link") {
    return <>{children}</>;
  }

  // Loading state
  if (!ready) {
    return (
      <div className="flex h-screen items-center justify-center bg-bg-primary">
        <div className="text-center">
          <h1 className="text-2xl font-bold text-text-primary tracking-tight">
            Eigen<span className="font-normal text-text-secondary">Inference</span>
          </h1>
          <p className="mt-2 text-sm text-text-tertiary">Loading...</p>
        </div>
      </div>
    );
  }

  // Unauthenticated — show page content without sidebar (page handles its own CTA)
  if (!authenticated) {
    return (
      <div className="flex h-screen overflow-hidden bg-bg-primary">
        <main className="flex-1 flex flex-col overflow-y-auto">{children}</main>
        <Toasts />
      </div>
    );
  }

  return (
    <div className="flex h-screen overflow-hidden bg-bg-primary">
      <Sidebar />
      <main className="flex-1 flex flex-col overflow-y-auto">{children}</main>
      <Toasts />
    </div>
  );
}

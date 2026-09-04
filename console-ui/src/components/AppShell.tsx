"use client";

import { useEffect, useState } from "react";
import { usePathname } from "next/navigation";
import { Sidebar } from "./Sidebar";
import { Toasts } from "./Toasts";
import { useStore, STORE_NAME } from "@/lib/store";
import { ConsoleExperienceProvider } from "./console-entry/ConsoleExperience";

export function AppShell({ children }: { children: React.ReactNode }) {
  return <ConsoleExperienceProvider><WorkspaceShell>{children}</WorkspaceShell></ConsoleExperienceProvider>;
}

function WorkspaceShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const sidebarOpen = useStore((state) => state.sidebarOpen);
  const [mobile, setMobile] = useState(false);

  useEffect(() => {
    const firstVisit = window.localStorage.getItem(STORE_NAME) === null;
    useStore.persist.rehydrate();
    const media = window.matchMedia("(max-width: 639px)");
    const syncViewport = () => setMobile(media.matches);
    syncViewport();
    if (firstVisit && media.matches) useStore.getState().setSidebarOpen(false);
    media.addEventListener("change", syncViewport);
    return () => media.removeEventListener("change", syncViewport);
  }, []);

  useEffect(() => {
    if (pathname === "/link" || pathname === "/") return;
    const shortcut = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "b") {
        event.preventDefault();
        useStore.getState().setSidebarOpen(!useStore.getState().sidebarOpen);
      }
    };
    document.addEventListener("keydown", shortcut);
    return () => document.removeEventListener("keydown", shortcut);
  }, [pathname]);

  if (pathname === "/link") return <>{children}</>;

  if (pathname === "/") return <div className="min-h-dvh bg-bg-primary"><a href="#main-content" className="skip-link">Skip to content</a><main id="main-content" tabIndex={-1} className="outline-none">{children}</main><Toasts /></div>;

  return (
    <div className="flex h-dvh overflow-hidden bg-bg-primary">
      <a href="#main-content" className="skip-link">Skip to content</a>
      <Sidebar />
      <main id="main-content" tabIndex={-1} inert={mobile && sidebarOpen} className="relative flex min-h-0 min-w-0 flex-1 flex-col overflow-y-auto outline-none">
        {children}
      </main>
      <Toasts />
    </div>
  );
}

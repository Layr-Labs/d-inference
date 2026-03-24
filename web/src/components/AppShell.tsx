"use client";

import { Sidebar } from "./Sidebar";
import { Toasts } from "./Toasts";

export function AppShell({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-screen overflow-hidden">
      <Sidebar />
      <main className="flex-1 flex flex-col overflow-hidden">{children}</main>
      <Toasts />
    </div>
  );
}

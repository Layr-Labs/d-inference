"use client";

import { useStore } from "@/lib/store";
import { Menu } from "lucide-react";

export function TopBar({ title }: { title?: string }) {
  const { sidebarOpen, setSidebarOpen } = useStore();

  return (
    <header className="h-14 bg-bg-primary/80 backdrop-blur-sm flex items-center px-3 sm:px-5 gap-3 shrink-0 squiggly-border-bottom">
      {!sidebarOpen && (
        <button
          onClick={() => setSidebarOpen(true)}
          className="p-2 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-primary transition-colors border-2 border-transparent hover:border-border-subtle"
        >
          <Menu size={18} />
        </button>
      )}
      {!sidebarOpen && (
        <div className="mr-3">
          <span className="text-xl font-display text-ink tracking-tight">
            Eigen<span className="text-coral">Inference</span>
          </span>
        </div>
      )}
      {title && (
        <h1 className="text-base font-display text-text-secondary">{title}</h1>
      )}
    </header>
  );
}

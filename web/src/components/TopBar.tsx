"use client";

import { useStore } from "@/lib/store";
import { Menu, Shield } from "lucide-react";

export function TopBar({ title }: { title?: string }) {
  const { sidebarOpen, setSidebarOpen } = useStore();

  return (
    <header className="h-12 border-b border-border-dim bg-bg-secondary/60 backdrop-blur-md flex items-center px-4 gap-3 shrink-0">
      {!sidebarOpen && (
        <button
          onClick={() => setSidebarOpen(true)}
          className="p-1.5 rounded-md hover:bg-bg-hover text-text-tertiary hover:text-text-secondary transition-colors"
        >
          <Menu size={16} />
        </button>
      )}
      {!sidebarOpen && (
        <div className="flex items-center gap-2 mr-3">
          <div className="w-6 h-6 rounded-md bg-accent-purple/20 border border-accent-purple/30 flex items-center justify-center">
            <Shield size={11} className="text-accent-purple" />
          </div>
          <span className="font-mono text-xs font-semibold text-text-primary">
            DG<span className="text-accent-purple">Inf</span>
          </span>
        </div>
      )}
      {title && (
        <h1 className="text-sm font-medium text-text-secondary">{title}</h1>
      )}
    </header>
  );
}

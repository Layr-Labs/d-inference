"use client";

import { useStore } from "@/lib/store";
import { Menu } from "lucide-react";

export function TopBar({ title }: { title?: string }) {
  const { sidebarOpen, setSidebarOpen } = useStore();

  return (
    <header className="h-14 bg-bg-primary/80 backdrop-blur-xl flex items-center px-5 gap-3 shrink-0 shadow-sm">
      {!sidebarOpen && (
        <button
          onClick={() => setSidebarOpen(true)}
          className="p-2 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-secondary transition-colors"
        >
          <Menu size={18} />
        </button>
      )}
      {!sidebarOpen && (
        <div className="mr-3">
          <span className="text-sm font-bold text-text-primary tracking-tight">
            Eigen<span className="font-normal text-text-secondary">Inference</span>
          </span>
        </div>
      )}
      {title && (
        <h1 className="text-sm font-medium text-text-secondary">{title}</h1>
      )}
    </header>
  );
}

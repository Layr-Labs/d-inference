"use client";

import { useToastStore } from "@/hooks/useToast";
import { X, AlertCircle, CheckCircle, Info } from "lucide-react";

const icons = {
  error: AlertCircle,
  success: CheckCircle,
  info: Info,
};

const colors = {
  error: "bg-accent-red-dim border-accent-red/25 text-accent-red",
  success: "bg-accent-green-dim border-accent-green/25 text-accent-green",
  info: "bg-accent-brand-dim border-accent-brand/25 text-accent-brand",
};

const iconColors = {
  error: "text-accent-red",
  success: "text-accent-green",
  info: "text-accent-brand",
};

export function Toasts() {
  const { toasts, removeToast } = useToastStore();

  if (toasts.length === 0) return null;

  return (
    <div className="fixed bottom-4 right-4 z-[10000] flex flex-col gap-2 max-w-sm">
      {toasts.map((toast) => {
        const Icon = icons[toast.type];
        return (
          <div
            key={toast.id}
            className={`flex items-start gap-2 px-4 py-3 rounded-lg border shadow-lg text-sm message-animate ${colors[toast.type]}`}
          >
            <Icon size={16} className={`shrink-0 mt-0.5 ${iconColors[toast.type]}`} />
            <span className="flex-1">{toast.message}</span>
            <button
              onClick={() => removeToast(toast.id)}
              className="shrink-0 p-0.5 rounded hover:bg-black/10 transition-colors"
            >
              <X size={14} />
            </button>
          </div>
        );
      })}
    </div>
  );
}

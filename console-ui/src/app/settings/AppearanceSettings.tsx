"use client";

import { Check, Monitor, Moon, Sun } from "lucide-react";
import { useTheme } from "@/components/app-providers/ThemeProvider";

export function AppearanceSettings() {
  const { theme, preference, setTheme } = useTheme();

  return (
    <div className="grid max-w-lg grid-cols-3 gap-3" role="group" aria-label="Color theme">
      {(["light", "dark", "system"] as const).map((option) => {
        const selected = (preference ?? theme) === option;
        const Icon = option === "light" ? Sun : option === "dark" ? Moon : Monitor;
        return (
          <button key={option} type="button" aria-pressed={selected} onClick={() => setTheme(option)} className={`appearance-option overflow-hidden rounded-lg border p-1 text-left transition-colors ${selected ? "border-accent-brand ring-1 ring-accent-brand" : "border-border-dim hover:border-border-subtle"}`}>
            <div aria-hidden="true" className={`appearance-preview flex h-20 gap-2 overflow-hidden rounded p-2.5 ${option === "light" ? "bg-[#f7f7f8]" : option === "dark" ? "bg-[#070707]" : "bg-linear-to-r from-[#f7f7f8] from-50% to-[#070707] to-50%"}`}>
              <div className={`w-1/4 rounded-sm ${option !== "dark" ? "bg-white" : "bg-[#202020]"}`}>
                <div className="mx-1 mt-2 h-1 rounded-full bg-[#0b41ff]" />
              </div>
              <div className="flex flex-1 flex-col justify-center gap-2 px-1">
                <div className={`h-1.5 w-3/4 rounded-full ${option === "light" ? "bg-[#c9c9d0]" : "bg-[#606066]"}`} />
                <div className="ml-auto h-4 w-2/3 rounded bg-[#0b41ff]" />
                <div className={`h-1 w-full rounded-full ${option === "light" ? "bg-[#dedee3]" : "bg-[#47474b]"}`} />
              </div>
            </div>
            <span className="flex items-center gap-1.5 px-1.5 py-2.5 text-xs font-medium text-text-primary sm:text-sm"><Icon size={14} className="shrink-0 text-text-secondary" />{option === "light" ? "Light" : option === "dark" ? "Dark" : "System"}{selected && <Check size={14} className="ml-auto shrink-0 text-accent-brand" />}</span>
          </button>
        );
      })}
    </div>
  );
}

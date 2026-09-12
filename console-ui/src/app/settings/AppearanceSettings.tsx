"use client";

import { Check, Moon, Sun } from "lucide-react";
import { useTheme } from "@/components/providers/ThemeProvider";

export function AppearanceSettings() {
  const { theme, setTheme } = useTheme();

  return (
    <div className="grid max-w-md grid-cols-2 gap-3" role="group" aria-label="Color theme">
      {(["light", "dark"] as const).map((option) => {
        const selected = theme === option;
        const Icon = option === "light" ? Sun : Moon;
        return (
          <button key={option} type="button" aria-pressed={selected} onClick={() => setTheme(option)} className={`overflow-hidden rounded-xl border-2 p-1 text-left transition-colors ${selected ? "border-accent-brand" : "border-border-dim hover:border-border-subtle"}`}>
            <div aria-hidden="true" className={`flex h-20 gap-2 overflow-hidden rounded-lg p-2.5 ${option === "light" ? "bg-[#f2f3f7]" : "bg-[#151520]"}`}>
              <div className={`w-1/4 rounded-sm ${option === "light" ? "bg-white" : "bg-[#262636]"}`}>
                <div className={`mx-1 mt-2 h-1 rounded-full ${option === "light" ? "bg-[#1a0c6d]/25" : "bg-[#a5a8ff]/40"}`} />
              </div>
              <div className="flex flex-1 flex-col justify-center gap-2 px-1">
                <div className={`h-1.5 w-3/4 rounded-full ${option === "light" ? "bg-[#c6c8d1]" : "bg-[#636378]"}`} />
                <div className={`ml-auto h-4 w-2/3 rounded ${option === "light" ? "bg-[#1a0c6d]/10" : "bg-[#a5a8ff]/20"}`} />
                <div className={`h-1 w-full rounded-full ${option === "light" ? "bg-[#d6d8df]" : "bg-[#414152]"}`} />
              </div>
            </div>
            <span className="flex items-center gap-2 px-2 py-2.5 text-sm font-medium text-text-primary"><Icon size={15} className="text-text-secondary" />{option === "light" ? "Light" : "Dark"}{selected && <Check size={15} className="ml-auto text-accent-brand" />}</span>
          </button>
        );
      })}
    </div>
  );
}

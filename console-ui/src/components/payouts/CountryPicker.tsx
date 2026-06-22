"use client";

import { useEffect, useRef, useState } from "react";
import { ChevronDown, Globe, Search } from "lucide-react";
import { STRIPE_CONNECT_COUNTRIES } from "@/lib/stripe-countries";

// Searchable country dropdown for Stripe onboarding. Encapsulates its own
// open/filter/click-outside state. Replaces the plain <select> in billing and
// the dropdown that was duplicated twice inside earnings (proposal F3).
export function CountryPicker({
  value,
  onChange,
}: {
  value: string;
  onChange: (code: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [filter, setFilter] = useState("");
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const handleClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [open]);

  const selected = STRIPE_CONNECT_COUNTRIES.find((c) => c.code === value);

  return (
    <div className="relative mb-4" ref={ref}>
      <button
        type="button"
        onClick={() => {
          setOpen(!open);
          setFilter("");
        }}
        className="w-full flex items-center justify-between gap-2 bg-bg-primary border border-border-dim rounded-lg px-4 py-3 text-sm text-left transition-colors hover:border-teal/40 focus:outline-none focus:border-teal"
      >
        {selected ? (
          <span className="flex items-center gap-2 text-text-primary">
            <span>{selected.flag}</span>
            <span>{selected.name}</span>
          </span>
        ) : (
          <span className="flex items-center gap-2 text-text-tertiary">
            <Globe size={14} />
            <span>Select your country</span>
          </span>
        )}
        <ChevronDown size={14} className={`text-text-tertiary transition-transform ${open ? "rotate-180" : ""}`} />
      </button>

      {open && (
        <div className="absolute z-50 mt-1 w-full bg-bg-white border border-border-dim rounded-xl shadow-lg overflow-hidden">
          <div className="p-2 border-b border-border-dim">
            <div className="relative">
              <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-text-tertiary" />
              <input
                type="text"
                value={filter}
                onChange={(e) => setFilter(e.target.value)}
                placeholder="Search countries..."
                autoFocus
                className="w-full bg-bg-primary border border-border-dim rounded-lg pl-9 pr-3 py-2 text-sm text-text-primary placeholder:text-text-tertiary outline-none focus:border-teal"
              />
            </div>
          </div>
          <div className="max-h-64 overflow-y-auto">
            {STRIPE_CONNECT_COUNTRIES.filter((c) => {
              const q = filter.toLowerCase();
              return !q || c.name.toLowerCase().includes(q) || c.code.toLowerCase().includes(q);
            }).map((c) => (
              <button
                key={c.code}
                type="button"
                onClick={() => {
                  onChange(c.code);
                  setOpen(false);
                }}
                className={`w-full flex items-center gap-3 px-4 py-2.5 text-sm text-left transition-colors ${
                  value === c.code ? "bg-teal/10 text-teal" : "text-text-secondary hover:bg-bg-hover"
                }`}
              >
                <span className="text-base">{c.flag}</span>
                <span className="flex-1">{c.name}</span>
                <span className="text-xs font-mono text-text-tertiary">{c.code}</span>
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

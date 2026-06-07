"use client";

// Reusable chevron accordion for progressive disclosure (backend slots,
// attestation chain). Holds its own open state; defaults to collapsed so the
// machine card's resting height stays small.

import { useState, type ReactNode } from "react";
import { ChevronDown, type LucideIcon } from "lucide-react";

export function ExpandSection({
  label,
  icon: Icon,
  defaultOpen = false,
  right,
  children,
}: {
  label: string;
  icon: LucideIcon;
  defaultOpen?: boolean;
  /** Optional trailing content shown in the header (e.g. a count). */
  right?: ReactNode;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className="border-t border-border-dim/60">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        className="focus-ring w-full flex items-center gap-2 px-4 py-2.5 text-left hover:bg-bg-hover/60 transition-colors"
      >
        <Icon size={13} className="text-text-tertiary shrink-0" />
        <span className="text-xs font-medium text-text-secondary">{label}</span>
        {right && <span className="ml-1 text-[11px] text-text-tertiary">{right}</span>}
        <ChevronDown
          size={14}
          className={`ml-auto text-text-tertiary transition-transform ${open ? "rotate-180" : ""}`}
        />
      </button>
      {open && <div className="px-4 pb-4 pt-1 space-y-3">{children}</div>}
    </div>
  );
}

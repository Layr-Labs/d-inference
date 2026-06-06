"use client";

// One row of the attention feed: a deduped issue, its severity, the WHY, the
// affected machines (expandable chips that scroll to the card), and the FIX.

import { useState } from "react";
import { AlertTriangle, ChevronDown, Info, XCircle, type LucideIcon } from "lucide-react";
import type { AttentionGroup } from "./aggregate";
import type { WarningSeverity } from "../warnings";
import { maskSerial, shortModelName } from "./format";
import { FixAffordance } from "./FixAffordance";

const SEV: Record<WarningSeverity, { icon: LucideIcon; color: string; rail: string }> = {
  blocking: { icon: XCircle, color: "text-accent-red", rail: "bg-accent-red" },
  degrading: { icon: AlertTriangle, color: "text-accent-amber", rail: "bg-accent-amber" },
  info: { icon: Info, color: "text-accent-brand", rail: "bg-accent-brand" },
};

function scrollToMachine(id: string) {
  if (typeof document === "undefined") return;
  const el = document.getElementById(`machine-${id}`);
  if (!el) return;
  el.scrollIntoView({ behavior: "smooth", block: "center" });
  el.classList.add("ring-2", "ring-accent-brand/50");
  setTimeout(() => el.classList.remove("ring-2", "ring-accent-brand/50"), 1600);
}

export function AttentionItem({ group }: { group: AttentionGroup }) {
  const [expanded, setExpanded] = useState(false);
  const sev = SEV[group.severity];
  const Icon = sev.icon;
  const count = group.providers.length;

  return (
    <div className="flex gap-3 px-4 py-3">
      <span className={`w-1 rounded-full ${sev.rail} shrink-0`} />
      <Icon size={16} className={`${sev.color} shrink-0 mt-0.5`} />

      <div className="flex-1 min-w-0">
        <div className="flex items-start justify-between gap-3 flex-wrap">
          <div className="min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <p className="text-sm font-medium text-text-primary">{group.title}</p>
              <button
                type="button"
                aria-expanded={expanded}
                onClick={() => setExpanded((e) => !e)}
                className="focus-ring inline-flex items-center gap-0.5 px-1.5 py-0.5 rounded-full bg-bg-tertiary text-[10px] font-semibold text-text-secondary hover:bg-bg-hover transition-colors"
              >
                ×{count} machine{count === 1 ? "" : "s"}
                <ChevronDown size={11} className={`transition-transform ${expanded ? "rotate-180" : ""}`} />
              </button>
            </div>
            <p className="text-xs text-text-secondary mt-0.5 line-clamp-2">{group.detail}</p>
          </div>

          <div className="shrink-0">
            <FixAffordance fix={group.fix} compact showNote={false} />
          </div>
        </div>

        {expanded && (
          <div className="flex flex-wrap gap-1.5 mt-2">
            {group.providers.map((p) => (
              <button
                key={p.id}
                type="button"
                onClick={() => scrollToMachine(p.id)}
                className="focus-ring inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md bg-bg-tertiary hover:bg-bg-hover text-[11px] font-mono text-text-secondary transition-colors"
                title="Jump to machine"
              >
                {shortModelName(p.hardware.chip_name || "machine")}
                {p.serial_number && <span className="text-text-tertiary">{maskSerial(p.serial_number)}</span>}
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

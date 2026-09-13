"use client";

import { Check, X } from "lucide-react";

/** A pass/fail security check row. */
export function StatusLine({
  ok,
  label,
  detail,
}: {
  ok: boolean;
  label: string;
  detail?: string;
}) {
  return (
    <div className="flex items-center gap-2 py-1">
      {ok ? (
        <Check size={12} className="text-accent-green shrink-0" />
      ) : (
        <X size={12} className="text-accent-red shrink-0" />
      )}
      <span className="text-xs text-text-primary">{label}</span>
      {detail && (
        <span className="text-xs text-text-tertiary ml-auto font-mono">
          {detail}
        </span>
      )}
    </div>
  );
}

"use client";

import { Check, X, Loader2 } from "lucide-react";
import type { VerificationStep } from "@/lib/cert-verify";

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

/** A live cert-verification step row (pending / running / success / error). */
export function VerifyStepLine({ step }: { step: VerificationStep }) {
  return (
    <div className="flex items-center gap-2 py-0.5">
      {step.status === "success" && (
        <Check size={12} className="text-accent-green shrink-0" />
      )}
      {step.status === "error" && (
        <X size={12} className="text-accent-red shrink-0" />
      )}
      {step.status === "running" && (
        <Loader2 size={12} className="text-accent-brand animate-spin shrink-0" />
      )}
      {step.status === "pending" && (
        <div className="w-3 h-3 rounded-full border border-border-dim shrink-0" />
      )}
      <span className="text-xs text-text-primary">{step.label}</span>
      {step.detail && (
        <span className="text-xs text-text-tertiary ml-auto font-mono truncate max-w-[180px]">
          {step.detail}
        </span>
      )}
    </div>
  );
}

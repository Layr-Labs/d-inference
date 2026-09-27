"use client";

import { Shield, ShieldCheck } from "lucide-react";
import type { TrustMetadata } from "@/lib/api";
import { verificationPresentation } from "@/lib/verification";

export function TrustBadge({ trust, compact = false }: { trust: TrustMetadata; compact?: boolean }) {
  const view = verificationPresentation(trust.verification);
  const Icon = view.verified ? ShieldCheck : Shield;
  const color = view.verified ? "text-teal bg-teal-light/50" : "text-text-tertiary bg-bg-elevated";
  return <span title={`${view.label} at dispatch`} className={`inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium ${color}`}>
    <Icon size={12} />{!compact && view.label}
  </span>;
}

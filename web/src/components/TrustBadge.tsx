"use client";

import { Shield, ShieldCheck, ShieldAlert } from "lucide-react";
import type { TrustMetadata } from "@/lib/api";

const config = {
  hardware: {
    icon: ShieldCheck,
    label: "Hardware Attested",
    color: "text-accent-green",
    bg: "bg-accent-green-dim/40",
    border: "border-accent-green/30",
    glow: "trust-glow-hardware",
  },
  self_signed: {
    icon: ShieldAlert,
    label: "Self-Signed",
    color: "text-accent-amber",
    bg: "bg-accent-amber-dim/40",
    border: "border-accent-amber/30",
    glow: "",
  },
  none: {
    icon: Shield,
    label: "Unverified",
    color: "text-text-tertiary",
    bg: "bg-bg-elevated",
    border: "border-border-dim",
    glow: "",
  },
};

export function TrustBadge({
  trust,
  compact = false,
}: {
  trust: TrustMetadata;
  compact?: boolean;
}) {
  const c = config[trust.trustLevel] || config.none;
  const Icon = c.icon;

  if (compact) {
    return (
      <span
        className={`inline-flex items-center gap-1 text-[10px] font-mono uppercase tracking-wider ${c.color} ${c.glow}`}
        title={`${c.label}${trust.secureEnclave ? " · Secure Enclave" : ""}`}
      >
        <Icon size={12} />
      </span>
    );
  }

  return (
    <span
      className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-mono uppercase tracking-wider ${c.color} ${c.bg} border ${c.border} ${c.glow}`}
    >
      <Icon size={11} />
      {c.label}
      {trust.secureEnclave && (
        <span className="opacity-60">· SE</span>
      )}
    </span>
  );
}

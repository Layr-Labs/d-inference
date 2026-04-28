"use client";

import { Shield, ShieldCheck } from "lucide-react";
import type { TrustMetadata } from "@/lib/api";
import { useVerificationMode } from "@/lib/verification-mode";

const config = {
  hardware_mda: {
    icon: ShieldCheck,
    normalLabel: "Apple-verified hardware",
    technicalLabel: "Apple Attested",
    color: "text-teal",
    bg: "bg-teal-light/50",
    glow: "trust-glow-hardware",
  },
  hardware: {
    icon: ShieldCheck,
    normalLabel: "Hardware Verified",
    technicalLabel: "Hardware Attested",
    color: "text-teal",
    bg: "bg-teal-light/50",
    glow: "trust-glow-hardware",
  },
  none: {
    icon: Shield,
    normalLabel: "Unverified",
    technicalLabel: "Unverified",
    color: "text-text-tertiary",
    bg: "bg-bg-elevated",
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
  const { mode } = useVerificationMode();

  const level =
    trust.trustLevel === "hardware" && trust.mdaVerified
      ? "hardware_mda"
      : trust.trustLevel;
  const c = config[level] || config.none;
  const Icon = c.icon;
  const label = mode === "normal" ? c.normalLabel : c.technicalLabel;

  if (compact) {
    return (
      <span
        className={`inline-flex items-center gap-1 text-xs ${c.color} ${c.glow}`}
        title={label}
      >
        <Icon size={12} />
      </span>
    );
  }

  return (
    <span
      className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium ${c.color} ${c.bg} ${c.glow}`}
    >
      <Icon size={12} />
      {label}
      {mode === "technical" && trust.secureEnclave && (
        <span className="opacity-60">· SE</span>
      )}
      {mode === "technical" && trust.mdaVerified && (
        <span className="opacity-60">· MDA</span>
      )}
    </span>
  );
}

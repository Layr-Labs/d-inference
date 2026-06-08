// Status + trust pills, shared by the machine card header and the attention
// feed machine chips. Extracted so the styling stays consistent everywhere.

import { ShieldCheck, ShieldQuestion, ShieldX } from "lucide-react";

const STATUS: Record<string, { color: string; label: string; live: boolean }> = {
  serving: { color: "bg-accent-green/15 text-accent-green", label: "Serving", live: true },
  online: { color: "bg-accent-green/15 text-accent-green", label: "Online", live: true },
  offline: { color: "bg-text-tertiary/15 text-text-tertiary", label: "Offline", live: false },
  untrusted: { color: "bg-accent-red/15 text-accent-red", label: "Untrusted", live: false },
  never_seen: { color: "bg-text-tertiary/15 text-text-tertiary", label: "Never seen", live: false },
};

export function StatusPill({ status }: { status: string }) {
  const c = STATUS[status] || { color: "bg-text-tertiary/15 text-text-tertiary", label: status, live: false };
  return (
    <span
      className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-semibold uppercase tracking-wider ${c.color}`}
    >
      <span
        className={`w-1.5 h-1.5 rounded-full ${c.live ? "bg-current" : "bg-current opacity-50"} ${
          status === "serving" ? "animate-pulse" : ""
        }`}
      />
      {c.label}
    </span>
  );
}

export function TrustPill({ trustLevel }: { trustLevel: string }) {
  if (trustLevel === "hardware") {
    return (
      <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-accent-green/10 text-accent-green text-[10px] font-semibold uppercase tracking-wider">
        <ShieldCheck size={10} /> Hardware
      </span>
    );
  }
  if (trustLevel === "self_signed") {
    return (
      <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-accent-amber/10 text-accent-amber text-[10px] font-semibold uppercase tracking-wider">
        <ShieldQuestion size={10} /> Self-signed
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-text-tertiary/15 text-text-tertiary text-[10px] font-semibold uppercase tracking-wider">
      <ShieldX size={10} /> Unverified
    </span>
  );
}

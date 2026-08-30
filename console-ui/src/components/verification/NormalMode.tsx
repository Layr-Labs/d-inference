"use client";

import type { TrustMetadata } from "@/lib/api";
import {
  ShieldCheck,
  Cpu,
  Lock,
  Fingerprint,
  Info,
} from "lucide-react";

/** Normal mode: human-readable coordinator-verified trust guarantees. */
export function NormalMode({
  trust,
  onOpenExplainer,
}: {
  trust: TrustMetadata;
  onOpenExplainer: () => void;
}) {
  const isHardware = trust.trustLevel === "hardware";

  const guarantees = [
    {
      icon: Fingerprint,
      color: "text-teal",
      title: "Hardware Identity",
      description:
        "This machine's identity is sealed in Apple's Secure Enclave chip — it can't be cloned, copied, or faked.",
      info: "P-256 key generated inside the Secure Enclave. The private key never leaves the chip and cannot be exported.",
      ok: trust.secureEnclave,
    },
    {
      icon: ShieldCheck,
      color: "text-blue",
      title: "Software Integrity",
      description:
        "The inference software hasn't been modified — its hash matches the signed release.",
      info: "SHA-256 hash of the provider binary is verified against the CI-signed release. Runtime packages are also hash-checked.",
      ok: isHardware,
    },
    {
      icon: Lock,
      color: "text-coral",
      title: "Data Protection",
      description:
        "Your prompts are encrypted in this browser directly to the certified provider process.",
      info: "Ephemeral X25519 + HKDF-SHA256 + AES-256-GCM. The browser verifies Apple-backed process evidence; the coordinator relays ciphertext only.",
      ok: trust.privacyTier === "private-v2-process-bound",
    },
    {
      icon: Cpu,
      color: "text-purple",
      title: "Anti-Tampering",
      description:
        "No process can inspect memory during inference. Debuggers are blocked and memory is wiped after each request.",
      info: "PT_DENY_ATTACH prevents debugger attachment. Hardened Runtime blocks task_for_pid. Memory is zeroed after each request.",
      ok: isHardware,
    },
  ];

  return (
    <div className="space-y-3">
      {guarantees.map(({ icon: Icon, color, title, description, info, ok }) => (
        <div key={title} className="flex gap-3">
          <div className="shrink-0 mt-0.5">
            {ok ? (
              <Icon size={16} className={color} />
            ) : (
              <Icon size={16} className="text-text-tertiary" />
            )}
          </div>
          <div className="flex-1">
            <div className="flex items-center gap-1">
              <p className="text-xs font-semibold text-text-primary">{title}</p>
              <span title={info} className="cursor-help">
                <Info size={10} className="text-text-tertiary hover:text-text-secondary transition-colors" />
              </span>
            </div>
            <p className="text-xs text-text-secondary leading-relaxed mt-0.5">
              {description}
            </p>
          </div>
        </div>
      ))}

      {isHardware && (
        <div className="flex items-center gap-2 border-t border-border-dim/50 pt-2 text-xs text-accent-green">
          <ShieldCheck size={14} />
          <span className="font-semibold">
            {trust.mdaVerified ? "Apple attestation verified by the coordinator" : "Hardware posture verified"}
          </span>
        </div>
      )}

      <button
        onClick={onOpenExplainer}
        className="flex items-center gap-1.5 text-xs text-teal font-semibold hover:underline mt-2"
      >
        <Info size={12} />
        Learn how the trust chain works
      </button>
    </div>
  );
}

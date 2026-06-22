"use client";

import type { TrustMetadata } from "@/lib/api";
import type { VerificationStep, CertVerificationResult } from "@/lib/cert-verify";
import {
  ShieldCheck,
  Cpu,
  Lock,
  Fingerprint,
  Loader2,
  Info,
} from "lucide-react";
import { VerifyStepLine } from "./StatusLine";

/** Normal mode: human-readable trust guarantees with one-click verification. */
export function NormalMode({
  trust,
  onOpenExplainer,
  verifySteps,
  verifyResult,
  verifying,
  onVerify,
}: {
  trust: TrustMetadata;
  onOpenExplainer: () => void;
  verifySteps: VerificationStep[];
  verifyResult: CertVerificationResult | null;
  verifying: boolean;
  onVerify: () => void;
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
        "Your prompts are encrypted end-to-end. Not even Darkbloom servers can read them.",
      info: "X25519 key exchange + XSalsa20-Poly1305 encryption (NaCl box). The coordinator only sees ciphertext.",
      ok: true, // E2E is always active
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

      {/* One-click verification for normal users */}
      {isHardware && (
        <div className="pt-2 border-t border-border-dim/50">
          <button
            onClick={onVerify}
            disabled={verifying}
            className="flex items-center gap-2 px-3 py-2 rounded-lg bg-teal-light/50 border-2 border-teal/30 text-teal text-xs font-semibold hover:bg-teal-light/70 transition-colors disabled:opacity-50 w-full justify-center"
          >
            {verifying ? (
              <Loader2 size={14} className="animate-spin" />
            ) : (
              <ShieldCheck size={14} />
            )}
            {verifying
              ? "Verifying..."
              : verifyResult?.success
                ? "Apple-verified hardware"
                : "Verify device"}
          </button>

          {verifySteps.length > 0 && (
            <div className="mt-2 space-y-0.5">
              {verifySteps.map((step, i) => (
                <VerifyStepLine key={i} step={step} />
              ))}
            </div>
          )}

          {verifyResult && (
            <p
              className={`mt-2 text-xs font-semibold text-center ${
                verifyResult.success ? "text-accent-green" : "text-accent-red"
              }`}
            >
              {verifyResult.success
                ? `Genuine Apple device ${verifyResult.deviceInfo?.serial ? `(${verifyResult.deviceInfo.serial})` : ""}`
                : verifyResult.error || "Verification failed"}
            </p>
          )}
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

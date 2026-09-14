"use client";

import { useState, useEffect, useCallback } from "react";
import {
  X,
  Cpu,
  Fingerprint,
  ShieldCheck,
  Lock,
  RefreshCw,
  ChevronDown,
} from "lucide-react";
import { useVerificationMode } from "@/components/app-providers/verification-mode";

interface TrustExplainerModalProps {
  open: boolean;
  onClose: () => void;
}

interface StepData {
  icon: typeof Cpu;
  iconColor: string;
  iconBg: string;
  title: string;
  description: string;
  technical: string;
}

const STEPS: StepData[] = [
  {
    icon: Cpu,
    iconColor: "text-purple",
    iconBg: "bg-purple-light",
    title: "Apple Hardware",
    description:
      "The coordinator verifies the provider's Secure Enclave identity and hardware security posture.",
    technical:
      "The provider runs on Apple Silicon with a Secure Enclave identity key. " +
      "MDM SecurityInfo checks System Integrity Protection and Secure Boot before hardware trust is granted. " +
      "Apple Managed Device Attestation (MDA) provides a separate certificate proof when verified.",
  },
  {
    icon: Fingerprint,
    iconColor: "text-teal",
    iconBg: "bg-teal-light",
    title: "Secure Enclave",
    description:
      "The machine's identity key is sealed in a tamper-proof chip that can't be cloned.",
    technical:
      "A P-256 key pair is generated inside Apple's Secure Enclave Processor (SEP). " +
      "The private key never leaves the hardware — it cannot be exported, copied, or read by software. " +
      "The provider signs attestation blobs with ECDSA (SHA-256 + P-256), proving identity without " +
      "revealing the key. The SEP has its own isolated firmware (SepOS) and memory.",
  },
  {
    icon: ShieldCheck,
    iconColor: "text-blue",
    iconBg: "bg-blue-light",
    title: "Apple Certificate, When Verified",
    description:
      "Providers marked Apple attestation verified have an Apple-signed device certificate checked by the coordinator.",
    technical:
      "When mda_verified is true, the coordinator has verified the device certificate chain " +
      "against Apple's pinned Enterprise Attestation Root CA. This proof is reported separately from hardware trust. " +
      "The leaf certificate embeds device-specific OIDs signed by Apple; " +
      "the raw certificate, serial number, and UDID remain private to the provider and coordinator.",
  },
  {
    icon: Lock,
    iconColor: "text-coral",
    iconBg: "bg-coral-light",
    title: "Encryption in Transit",
    description:
      "Requests travel over encrypted connections. The coordinator and provider process plaintext; so does the console proxy when sender sealing is off.",
    technical:
      "HTTPS terminates at the console service. By default its /api/chat proxy parses plaintext requests " +
      "before forwarding them over HTTPS. Turning on Encrypt to coordinator adds X25519/NaCl box sealing " +
      "in the browser, so that proxy forwards ciphertext and the coordinator opens it. " +
      "The coordinator processes plaintext in confidential-VM memory for routing and billing, " +
      "without logging or retaining prompt content, then re-seals to the provider's registered key. " +
      "The attested provider decrypts the request for inference. This is hop-by-hop encryption.",
  },
  {
    icon: RefreshCw,
    iconColor: "text-gold",
    iconBg: "bg-gold-light",
    title: "Continuous Verification",
    description:
      "Periodic checks keep provider trust up to date. Providers that fail required security checks stop receiving requests.",
    technical:
      "The coordinator sends attestation challenges (32-byte random nonce + timestamp) " +
      "every 5 minutes and verifies the provider's SE signature and required security posture. " +
      "Trust and routing decisions distinguish proven security failures from transient timeouts; " +
      "RDMA enablement alone does not revoke hardware trust.",
  },
];

function TechnicalDetails({ text }: { text: string }) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="mt-2">
      <button
        onClick={() => setExpanded(!expanded)}
        className="flex items-center gap-1 text-xs text-text-tertiary hover:text-text-secondary transition-colors"
      >
        <ChevronDown
          size={12}
          className={`transition-transform ${expanded ? "rotate-180" : ""}`}
        />
        <span className="font-mono">Technical Details</span>
      </button>
      {expanded && (
        <p className="mt-1.5 text-xs text-text-tertiary leading-relaxed pl-4 border-l-2 border-border-dim">
          {text}
        </p>
      )}
    </div>
  );
}

export function TrustExplainerModal({ open, onClose }: TrustExplainerModalProps) {
  const { mode } = useVerificationMode();

  // Close on Escape
  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    },
    [onClose]
  );

  useEffect(() => {
    if (open) {
      document.addEventListener("keydown", handleKeyDown);
      return () => document.removeEventListener("keydown", handleKeyDown);
    }
  }, [open, handleKeyDown]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-ink/40 backdrop-blur-sm fade-in"
        onClick={onClose}
      />

      {/* Modal */}
      <div className="relative w-full max-w-lg mx-4 max-h-[85vh] overflow-y-auto rounded-2xl bg-bg-white border border-border-dim shadow-xl fade-in">
        {/* Header */}
        <div className="sticky top-0 bg-bg-white z-10 px-6 pt-6 pb-4 border-b-2 border-border-dim">
          <div className="flex items-center justify-between">
            <div>
              <h2 className="text-2xl font-semibold text-ink">
                How Your Privacy is Protected
              </h2>
              <p className="text-sm text-text-secondary mt-1">
                5 layers of hardware-backed security
              </p>
            </div>
            <button
              onClick={onClose}
              className="p-2 rounded-lg hover:bg-bg-hover transition-colors"
            >
              <X size={18} className="text-text-tertiary" />
            </button>
          </div>
        </div>

        {/* Steps */}
        <div className="px-6 py-4 space-y-1">
          {STEPS.map((step, idx) => {
            const Icon = step.icon;
            return (
              <div key={idx} className="relative">
                {/* Connector line */}
                {idx < STEPS.length - 1 && (
                  <div className="absolute left-[23px] top-[48px] bottom-0 w-0.5 bg-border-dim" />
                )}

                <div className="flex gap-4 pb-5">
                  {/* Step number + icon */}
                  <div className="shrink-0">
                    <div
                      className={`w-[46px] h-[46px] rounded-xl ${step.iconBg} border-2 border-ink/10 flex items-center justify-center relative`}
                    >
                      <Icon size={20} className={step.iconColor} />
                      <span className="absolute -top-1.5 -right-1.5 w-5 h-5 rounded-full bg-ink text-bg-white text-[10px] font-bold flex items-center justify-center">
                        {idx + 1}
                      </span>
                    </div>
                  </div>

                  {/* Content */}
                  <div className="flex-1 min-w-0 pt-0.5">
                    <h3 className="text-sm font-bold text-text-primary">
                      {step.title}
                    </h3>
                    <p className="text-sm text-text-secondary mt-1 leading-relaxed">
                      {step.description}
                    </p>
                    {mode === "technical" && (
                      <TechnicalDetails text={step.technical} />
                    )}
                  </div>
                </div>
              </div>
            );
          })}
        </div>

        {/* Footer */}
        <div className="px-6 pb-6">
          <div className="rounded-xl bg-teal-light/50 border-2 border-teal/30 p-4">
            <div className="flex items-start gap-3">
              <ShieldCheck size={20} className="text-teal shrink-0 mt-0.5" />
              <div>
                <p className="text-sm font-semibold text-text-primary">
                  Privacy-Preserving Verification
                </p>
                <p className="text-xs text-text-secondary mt-1 leading-relaxed">
                  The coordinator publishes hardware trust and the separate
                  Apple attestation status without exposing the
                  device&apos;s serial number, UDID, or raw certificate.
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

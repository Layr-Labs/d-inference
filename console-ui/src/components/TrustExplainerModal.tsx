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
import { useVerificationMode } from "@/lib/verification-mode";

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
      "Your request is processed on a real Apple Silicon Mac, verified by Apple.",
    technical:
      "The provider runs on Apple Silicon (M1/M2/M3/M4) with hardware-backed security features. " +
      "The device identity is established through Apple's Managed Device Attestation (MDA), " +
      "which uses DeviceInformation DevicePropertiesAttestation OIDs (1.2.840.113635.100.8.9.*, " +
      "100.8.10.*, 100.8.11.*) to certify serial number, UDID, OS version, and SepOS version.",
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
    title: "Apple Certificate",
    description:
      "Apple's certificate authority confirms this specific device's identity.",
    technical:
      "Apple's Enterprise Attestation Root CA (P-384, valid until 2047) signs intermediate " +
      "certificates that chain to the device leaf certificate. This X.509 chain is verified " +
      "in your browser using the WebCrypto API. The leaf certificate embeds device-specific " +
      "OIDs (serial number, UDID, OS version) signed by Apple — not self-reported by the device.",
  },
  {
    icon: Lock,
    iconColor: "text-coral",
    iconBg: "bg-coral-light",
    title: "End-to-End Encryption",
    description:
      "Your prompts are encrypted before leaving your browser. Only the verified hardware can decrypt them.",
    technical:
      "E2E encryption uses X25519/NaCl box (Curve25519 + XSalsa20-Poly1305). " +
      "The coordinator generates ephemeral X25519 session keys for each request, encrypts " +
      "the request body with the provider's public key, and forwards the ciphertext. " +
      "Decryption happens only inside the hardened provider process with PT_DENY_ATTACH, " +
      "Hardened Runtime, and SIP protections.",
  },
  {
    icon: RefreshCw,
    iconColor: "text-gold",
    iconBg: "bg-gold-light",
    title: "Continuous Verification",
    description:
      "The machine is re-verified every 5 minutes. If anything changes, it's taken offline.",
    technical:
      "The coordinator sends attestation challenges (32-byte random nonce + timestamp) " +
      "every 5 minutes. The provider must sign the challenge with its SE key and report " +
      "fresh security posture: SIP status, Secure Boot, binary hash (self-hash of provider binary), " +
      "RDMA status, hypervisor isolation status, and runtime integrity hashes " +
      "(Python, vllm-mlx, Jinja templates). Any mismatch triggers demotion.",
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
      <div className="relative w-full max-w-lg mx-4 max-h-[85vh] overflow-y-auto rounded-2xl bg-bg-white border-[3px] border-ink shadow-xl fade-in">
        {/* Header */}
        <div className="sticky top-0 bg-bg-white z-10 px-6 pt-6 pb-4 border-b-2 border-border-dim">
          <div className="flex items-center justify-between">
            <div>
              <h2 className="text-2xl font-display text-ink">
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
                  Independently Verifiable
                </p>
                <p className="text-xs text-text-secondary mt-1 leading-relaxed">
                  Every step in this chain can be verified independently. Click
                  &quot;Verify Apple Attestation&quot; on any response to run
                  real X.509 certificate verification in your browser.
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

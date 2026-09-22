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
  { icon: ShieldCheck, iconColor: "text-blue", iconBg: "bg-blue-light", title: "Two verification methods",
    description: "App Attest and legacy MDM/MDA/APNs are separate ways to earn serving authorization. A provider may qualify through either or both.",
    technical: "App Attest requires Apple key enrollment, connection-bound assertions, receipt policy and a qualified signed build. Legacy authorization requires its own device, application and challenge evidence. A self_signed legacy field does not rule out App Attest." },
  { icon: Fingerprint, iconColor: "text-teal", iconBg: "bg-teal-light", title: "Apple evidence and Darkbloom authorization",
    description: "The coordinator validates Apple's evidence and applies Darkbloom's serving policy. Your browser displays that verdict.",
    technical: "Raw certificate chains and Apple receipts can contain private device and credential information. Public views omit them. Reported chip, memory and macOS properties are not certified merely because App Attest succeeded." },
  { icon: Lock, iconColor: "text-coral", iconBg: "bg-coral-light", title: "Encryption between hops",
    description: "Encrypted requests are decrypted in the coordinator’s confidential VM, then re-encrypted to the provider.",
    technical: "NaCl Box protects each encrypted leg. The provider is a plaintext endpoint and the coordinator handles routing and billing. The provider-hop encryption header does not establish browser-to-coordinator encryption." },
  { icon: RefreshCw, iconColor: "text-gold", iconBg: "bg-gold-light", title: "Freshness and request history",
    description: "Live authorization expires and can be revoked. Each chat message retains the verification recorded at dispatch.",
    technical: "Each method has its own verification and expiry timestamps. Live views also expire stale cached verdicts. Historical response metadata is not evidence of a current authorization and does not prove that an inference result is correct." },
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
                How provider verification works
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
                  The coordinator verifies Apple&apos;s certificate chain and
                  publishes the resulting trust status without exposing the
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

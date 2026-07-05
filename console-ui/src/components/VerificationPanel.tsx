"use client";

import { useState } from "react";
import type { TrustMetadata } from "@/lib/api";
import { maskSerial } from "@/lib/format";
import { useVerificationMode } from "@/components/providers/verification-mode";
import { TrustExplainerModal } from "./TrustExplainerModal";
import { useDeviceVerification } from "./verification/useDeviceVerification";
import { NormalMode } from "./verification/NormalMode";
import { TechnicalMode } from "./verification/TechnicalMode";
import { ShieldCheck, Shield, ChevronDown, Code, Eye } from "lucide-react";

// Thin orchestrator: owns only the expand/mode/explainer UI state and composes
// the verification hook + the two mode bodies (proposal F7). The heavy X.509
// verifier is lazy-loaded by useDeviceVerification (perf F4).
export function VerificationPanel({ trust }: { trust: TrustMetadata }) {
  const { mode, toggle } = useVerificationMode();
  const [open, setOpen] = useState(false);
  const [showExplainer, setShowExplainer] = useState(false);
  const { verifying, verifySteps, verifyResult, providerDetail, verify } =
    useDeviceVerification(trust);

  const isHardware = trust.trustLevel === "hardware";

  const Icon = isHardware ? ShieldCheck : Shield;
  const color = isHardware ? "text-accent-green" : "text-text-tertiary";
  const bg = isHardware ? "bg-accent-green/5" : "bg-bg-secondary";
  const title = isHardware
    ? trust.mdaVerified
      ? mode === "normal"
        ? "Apple-verified hardware"
        : "Apple Attested"
      : "Hardware Verified"
    : "Unverified";

  const displaySerial = trust.providerSerial
    ? mode === "normal" ? maskSerial(trust.providerSerial) : trust.providerSerial
    : "";
  const chipLabel = trust.providerChip
    ? `${trust.providerChip}${displaySerial ? ` · ${displaySerial}` : ""}`
    : "";

  return (
    <>
      <div className={`rounded-xl ${bg} shadow-sm overflow-hidden max-w-full`}>
        <button
          onClick={() => setOpen(!open)}
          className="w-full flex items-center gap-2 px-3 py-2.5 text-left"
        >
          <Icon size={14} className={color} />
          <span className={`text-xs font-medium ${color}`}>{title}</span>
          {chipLabel && (
            <span className="text-xs text-text-tertiary font-mono ml-1">
              {chipLabel}
            </span>
          )}
          <ChevronDown
            size={12}
            className={`ml-auto text-text-tertiary transition-transform ${
              open ? "rotate-180" : ""
            }`}
          />
        </button>

        {open && (
          <div className="px-3 pb-3 border-t border-border-dim/50">
            {/* Mode toggle */}
            <div className="flex items-center justify-between mt-2 mb-2">
              <p className="text-xs text-text-tertiary font-medium uppercase tracking-wider">
                {mode === "normal"
                  ? "Security Guarantees"
                  : "Provider Security Verification"}
              </p>
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  toggle();
                }}
                className="flex items-center gap-1 px-2 py-1 rounded-md text-xs text-text-tertiary hover:text-text-secondary hover:bg-bg-hover transition-colors"
                title={
                  mode === "normal"
                    ? "Switch to technical view"
                    : "Switch to simple view"
                }
              >
                {mode === "normal" ? <Code size={12} /> : <Eye size={12} />}
                <span className="text-[10px]">
                  {mode === "normal" ? "Technical" : "Simple"}
                </span>
              </button>
            </div>

            {mode === "normal" ? (
              <NormalMode
                trust={trust}
                onOpenExplainer={() => setShowExplainer(true)}
                verifySteps={verifySteps}
                verifyResult={verifyResult}
                verifying={verifying}
                onVerify={verify}
              />
            ) : (
              <TechnicalMode
                trust={trust}
                verifySteps={verifySteps}
                verifyResult={verifyResult}
                verifying={verifying}
                onVerify={verify}
                providerDetail={providerDetail}
              />
            )}
          </div>
        )}
      </div>

      <TrustExplainerModal
        open={showExplainer}
        onClose={() => setShowExplainer(false)}
      />
    </>
  );
}

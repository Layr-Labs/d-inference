"use client";

import { verificationPresentation } from "@/lib/verification";
import { useState } from "react";
import type { TrustMetadata } from "@/lib/api";
import { useVerificationMode } from "@/components/app-providers/verification-mode";
import { TrustExplainerModal } from "./TrustExplainerModal";
import { NormalMode } from "./verification/NormalMode";
import { TechnicalMode } from "./verification/TechnicalMode";
import { ShieldCheck, Shield, ChevronDown, Code, Eye } from "lucide-react";

// Thin orchestrator for the coordinator-verified trust state returned with each
// inference response. Raw identity-bearing MDA certificates are never fetched.
export function VerificationPanel({ trust }: { trust: TrustMetadata }) {
  const { mode, toggle } = useVerificationMode();
  const [open, setOpen] = useState(false);
  const [showExplainer, setShowExplainer] = useState(false);
  const view = verificationPresentation(trust.verification);
  const Icon = view.verified ? ShieldCheck : Shield;
  const color = view.verified ? "text-accent-green" : "text-text-tertiary";
  const bg = view.verified ? "bg-accent-green/5" : "bg-bg-secondary";
  const title = view.label;

  const chipLabel = trust.providerChip;

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
                  ? "Verification at dispatch"
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
              />
            ) : (
              <TechnicalMode trust={trust} />
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

"use client";

import { useState, useRef, useEffect } from "react";
import { Lock } from "lucide-react";
import type { TrustMetadata } from "@/lib/api";
import { useVerificationMode } from "@/lib/verification-mode";

interface E2ELockIndicatorProps {
  trust?: TrustMetadata;
  onOpenExplainer?: () => void;
}

function maskSerial(serial: string): string {
  if (serial.length <= 6) return serial;
  return serial.slice(0, 4) + "\u2022".repeat(serial.length - 6) + serial.slice(-2);
}

export function E2ELockIndicator({ trust, onOpenExplainer }: E2ELockIndicatorProps) {
  const { mode } = useVerificationMode();
  const [showPopover, setShowPopover] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  // Close on outside click
  useEffect(() => {
    if (!showPopover) return;
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setShowPopover(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [showPopover]);

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setShowPopover(!showPopover)}
        className="flex items-center gap-1.5 px-2 py-1 rounded-lg text-xs text-teal hover:bg-teal-light/40 transition-colors"
      >
        <Lock size={12} />
        <span className="font-semibold hidden sm:inline">End-to-end encrypted</span>
      </button>

      {showPopover && (
        <div className="absolute top-full right-0 mt-1 w-72 rounded-xl bg-bg-white border-[3px] border-ink shadow-lg z-50 fade-in">
          <div className="px-4 py-3 border-b-2 border-border-dim">
            <div className="flex items-center gap-2">
              <Lock size={14} className="text-teal" />
              <span className="text-sm font-bold text-text-primary">
                End-to-End Encrypted
              </span>
            </div>
          </div>
          <div className="px-4 py-3 space-y-2">
            <p className="text-xs text-text-secondary leading-relaxed">
              Messages are secured with end-to-end encryption.
              Only the verified provider hardware can decrypt your prompts.
            </p>
            {trust && (trust.providerChip || trust.providerSerial) && (
              <div className="rounded-lg bg-bg-secondary px-3 py-2">
                {trust.providerChip && (
                  <p className="text-xs text-text-secondary">
                    <span className="font-mono text-text-tertiary">Chip:</span>{" "}
                    {trust.providerChip}
                  </p>
                )}
                {trust.providerSerial && (
                  <p className="text-xs text-text-secondary">
                    <span className="font-mono text-text-tertiary">Serial:</span>{" "}
                    {mode === "normal" ? maskSerial(trust.providerSerial) : trust.providerSerial}
                  </p>
                )}
              </div>
            )}
            {onOpenExplainer && (
              <button
                onClick={() => {
                  setShowPopover(false);
                  onOpenExplainer();
                }}
                className="text-xs text-teal font-semibold hover:underline"
              >
                Learn how your privacy is protected
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

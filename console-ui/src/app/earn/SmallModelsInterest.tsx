"use client";

import { useEffect, useState } from "react";
import { Bell, Check } from "lucide-react";
import { trackEvent } from "@/lib/google-analytics";
import type { EarningsCalculator } from "./useEarningsCalculator";

const STORAGE_KEY = "darkbloom.smallModelsInterest";

/**
 * Shown when the selected hardware can't run any current catalog model:
 * lets the visitor register interest in smaller models. Signing in registers
 * their email; the tracked event carries the hardware so we know what to
 * target and whom to notify.
 */
export function SmallModelsInterest({
  calc,
  authenticated,
  ready,
  login,
}: {
  calc: EarningsCalculator;
  authenticated: boolean;
  ready: boolean;
  login: () => void;
}) {
  const [registered, setRegistered] = useState(false);

  useEffect(() => {
    setRegistered(Boolean(window.localStorage.getItem(STORAGE_KEY)));
  }, []);

  const register = () => {
    trackEvent("small_models_interest_registered", {
      source: "earn_page",
      mac_type: calc.hardware.macType,
      chip: calc.hardware.chip,
      ram_gb: calc.effectiveRAM,
      authenticated: String(authenticated),
    });
    window.localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        macType: calc.hardware.macType,
        chip: calc.hardware.chip,
        ramGB: calc.effectiveRAM,
        at: Date.now(),
      }),
    );
    setRegistered(true);
    // Sign-in is what actually captures a contactable email.
    if (!authenticated) login();
  };

  if (registered) {
    return (
      <div className="mt-4 inline-flex items-center gap-2 px-4 py-2.5 rounded-lg bg-accent-green/10 text-sm text-text-primary">
        <Check size={14} className="text-accent-green shrink-0" />
        You&apos;re on the list — we&apos;ll notify you when smaller models go live.
      </div>
    );
  }

  return (
    <div className="mt-4">
      <button
        onClick={register}
        disabled={!ready}
        className="inline-flex items-center justify-center gap-2 px-5 py-2.5 rounded-lg
                   bg-accent-brand text-white font-medium text-sm
                   hover:bg-accent-brand-hover
                   disabled:opacity-40 disabled:cursor-not-allowed
                   transition-colors"
      >
        <Bell size={14} />
        Notify me when smaller models launch
      </button>
      <p className="mt-2 text-xs text-text-secondary">
        We&apos;re working on supporting smaller models. Register and we&apos;ll email you when your
        Mac can start earning.
      </p>
    </div>
  );
}

"use client";

import { useEffect, useState } from "react";
import { Bell, Check } from "lucide-react";
import { trackEvent } from "@/lib/google-analytics";
import type { EarningsCalculator } from "./useEarningsCalculator";

type InterestVariant = "smaller-models" | "production-readiness";

interface InterestContent {
  storageKey: string;
  event: string;
  button: string;
  detail: string;
  registered: string;
}

const SMALLER_MODELS_CONTENT: InterestContent = {
  storageKey: "darkbloom.smallModelsInterest",
  event: "small_models_interest_registered",
  button: "Notify me when smaller models launch",
  detail:
    "Smaller models aren't supported yet. Register, and we'll email you when this Mac can start earning.",
  registered: "You're on the list — we'll notify you when smaller models go live.",
};

const PRODUCTION_READINESS_CONTENT: InterestContent = {
  storageKey: "darkbloom.productionReadinessInterest",
  event: "production_readiness_interest_registered",
  button: "Register your interest",
  detail: "We'll email you as soon as your Mac is ready to start earning.",
  registered: "You're on the list — we'll let you know as soon as your Mac can start earning.",
};

/** Registers interest when hardware is blocked by model fit or production readiness. */
export function SmallModelsInterest({
  calc,
  authenticated,
  ready,
  login,
  variant = "smaller-models",
}: {
  calc: EarningsCalculator;
  authenticated: boolean;
  ready: boolean;
  login: () => void;
  variant?: InterestVariant;
}) {
  const [registered, setRegistered] = useState(false);
  const content =
    variant === "production-readiness"
      ? PRODUCTION_READINESS_CONTENT
      : SMALLER_MODELS_CONTENT;

  useEffect(() => {
    setRegistered(Boolean(window.localStorage.getItem(content.storageKey)));
  }, [content.storageKey]);

  const register = () => {
    trackEvent(content.event, {
      source: "earn_page",
      mac_type: calc.hardware.macType,
      chip: calc.hardware.chip,
      ram_gb: calc.effectiveRAM,
      authenticated: String(authenticated),
    });
    window.localStorage.setItem(
      content.storageKey,
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
        {content.registered}
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
        {content.button}
      </button>
      <p className="mt-2 text-xs text-text-secondary">{content.detail}</p>
    </div>
  );
}

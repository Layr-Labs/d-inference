"use client";

import { useCallback } from "react";
import { Bell, Check } from "lucide-react";
import { trackEvent } from "@/lib/google-analytics";
import type { EarningsCalculator } from "./useEarningsCalculator";
import { useSmallModelsInterest, type InterestAuth } from "./useSmallModelsInterest";
import type { InterestHardware } from "@/lib/api/interest";

type InterestVariant = "smaller-models" | "production-readiness";

interface InterestContent {
  event: string;
  button: string;
  detail: string;
  registered: string;
}

const SMALLER_MODELS_CONTENT: InterestContent = {
  event: "small_models_interest_registered",
  button: "Notify me when smaller models launch",
  detail:
    "Smaller models aren't supported yet. Register, and we'll email you when this Mac can start earning.",
  registered: "You're on the list — we'll notify you when smaller models go live.",
};

const PRODUCTION_READINESS_CONTENT: InterestContent = {
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
  accountId,
  getAccessToken,
  variant = "smaller-models",
}: {
  calc: EarningsCalculator;
  variant?: InterestVariant;
} & InterestAuth) {
  const content =
    variant === "production-readiness"
      ? PRODUCTION_READINESS_CONTENT
      : SMALLER_MODELS_CONTENT;

  const onRegistered = useCallback((hardware: InterestHardware) => {
    trackEvent(content.event, {
      source: "earn_page",
      ...hardware,
      authenticated: "true",
    });
  }, [content.event]);
  const { registered, waitingForLogin, saving, error, register, cancel } = useSmallModelsInterest(
    { mac_type: calc.hardware.macType, chip: calc.hardware.chip, ram_gb: calc.effectiveRAM },
    { authenticated, ready, accountId, getAccessToken, login },
    onRegistered,
  );

  if (registered) {
    return (
      <div className="mt-4 inline-flex items-center gap-2 px-4 py-2.5 rounded-lg bg-accent-green/10 text-sm text-text-primary">
        <Check size={14} className="text-accent-green shrink-0" />
        {content.registered}
      </div>
    );
  }

  if (waitingForLogin || saving) {
    return (
      <div className="mt-4 text-sm text-text-secondary">
        <p role="status">{saving ? "Saving your interest…" : "Sign in to finish registering. Your registration is still pending."}</p>
        {waitingForLogin && <>
          <button onClick={login} className="mt-2 mr-4 text-accent-brand">Continue sign-in</button>
          <button onClick={cancel} className="mt-2 underline">Cancel registration</button>
        </>}
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
      {error && <p role="alert" className="mt-2 text-sm text-accent-amber">{error}</p>}
    </div>
  );
}

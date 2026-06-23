"use client";

import { useCallback, useEffect, useState } from "react";
import {
  fetchStripeStatus,
  startStripeOnboarding,
  withdrawStripe,
  fetchStripeWithdrawals,
  type StripeStatus,
  type StripeWithdrawal,
} from "@/lib/api";

type WithdrawMethod = "standard" | "instant";

export interface UseStripePayouts {
  status: StripeStatus | null;
  withdrawals: StripeWithdrawal[];
  onboardLoading: boolean;
  selectedCountry: string;
  setSelectedCountry: (c: string) => void;
  withdrawOpen: boolean;
  setWithdrawOpen: (open: boolean) => void;
  withdrawAmount: string;
  setWithdrawAmount: (v: string) => void;
  withdrawMethod: WithdrawMethod;
  setWithdrawMethod: (m: WithdrawMethod) => void;
  withdrawLoading: boolean;
  /** Refetch Stripe status + withdrawal history (refresh=1 pulls live). */
  reload: (refresh?: boolean) => Promise<void>;
  /** Start (or continue) Stripe Express onboarding for the selected country. */
  onboard: () => Promise<void>;
  /** Submit a withdrawal for the current amount + method. */
  withdraw: () => Promise<void>;
  /** Open the withdraw modal, seeding the amount + best available method. */
  openWithdraw: (defaultAmount?: string) => void;
}

export interface StripePayoutsOptions {
  addToast: (message: string, kind?: "success" | "error") => void;
  /** Gates the on-mount status load + stripe_return detection (auth). */
  enabled?: boolean;
  /** Page-specific data reload to run after a successful withdrawal. */
  onAfterWithdraw?: () => Promise<unknown> | void;
  /** Optional analytics hooks (provider earnings tracks these). */
  onWithdrawStart?: (method: WithdrawMethod) => void;
  onWithdrawSuccess?: (method: WithdrawMethod) => void;
  onWithdrawError?: () => void;
}

/**
 * Shared Stripe Connect payouts state machine used by both the billing and
 * provider-earnings pages. Owns status/withdrawals/onboarding/withdraw-modal
 * state and the onboard + withdraw flows; the page supplies its own post-
 * withdraw data reload and optional analytics (proposal F3).
 */
export function useStripePayouts(opts: StripePayoutsOptions): UseStripePayouts {
  const { addToast, enabled = true, onAfterWithdraw, onWithdrawStart, onWithdrawSuccess, onWithdrawError } = opts;

  const [status, setStatus] = useState<StripeStatus | null>(null);
  const [withdrawals, setWithdrawals] = useState<StripeWithdrawal[]>([]);
  const [onboardLoading, setOnboardLoading] = useState(false);
  const [withdrawOpen, setWithdrawOpen] = useState(false);
  const [withdrawAmount, setWithdrawAmount] = useState("10");
  const [withdrawMethod, setWithdrawMethod] = useState<WithdrawMethod>("standard");
  const [withdrawLoading, setWithdrawLoading] = useState(false);
  const [selectedCountry, setSelectedCountry] = useState("");

  // Once a Stripe Express account exists its country is locked — pre-select it.
  useEffect(() => {
    if (status?.stripe_account_country) {
      setSelectedCountry(status.stripe_account_country);
    }
  }, [status?.stripe_account_country]);

  const reload = useCallback(async (refresh = false) => {
    try {
      const [s, wds] = await Promise.all([
        fetchStripeStatus(refresh),
        fetchStripeWithdrawals(20).catch(() => [] as StripeWithdrawal[]),
      ]);
      setStatus(s);
      setWithdrawals(wds);
    } catch (e) {
      // Silent — Stripe Payouts is optional infrastructure.
      console.warn("stripe status fetch failed:", (e as Error).message);
    }
  }, []);

  // On mount (when enabled), load status and detect a return from the
  // Stripe-hosted onboarding flow (?stripe_return=1 → refresh + toast).
  useEffect(() => {
    if (!enabled) return;
    const params = typeof window !== "undefined" ? new URLSearchParams(window.location.search) : null;
    const justReturned = params?.get("stripe_return") === "1";
    reload(justReturned);
    if (justReturned) {
      addToast("Stripe onboarding complete — verifying...", "success");
      const url = new URL(window.location.href);
      url.searchParams.delete("stripe_return");
      window.history.replaceState({}, "", url.toString());
    }
  }, [enabled, reload, addToast]);

  const onboard = useCallback(async () => {
    setOnboardLoading(true);
    try {
      const returnURL = typeof window !== "undefined"
        ? `${window.location.origin}${window.location.pathname}?stripe_return=1`
        : undefined;
      const resp = await startStripeOnboarding(returnURL, selectedCountry || undefined);
      window.location.href = resp.url;
    } catch (e) {
      addToast(`Stripe onboarding failed: ${(e as Error).message}`);
      setOnboardLoading(false);
    }
  }, [selectedCountry, addToast]);

  const withdraw = useCallback(async () => {
    setWithdrawLoading(true);
    onWithdrawStart?.(withdrawMethod);
    try {
      const resp = await withdrawStripe(withdrawAmount, withdrawMethod);
      onWithdrawSuccess?.(withdrawMethod);
      addToast(`Withdrawal submitted — ${resp.eta || "processing"}`, "success");
      setWithdrawOpen(false);
      await Promise.all([onAfterWithdraw?.(), reload(false)]);
    } catch (e) {
      onWithdrawError?.();
      addToast(`${(e as Error).message}`);
    }
    setWithdrawLoading(false);
  }, [withdrawAmount, withdrawMethod, addToast, onAfterWithdraw, reload, onWithdrawStart, onWithdrawSuccess, onWithdrawError]);

  const openWithdraw = useCallback((defaultAmount = "10") => {
    setWithdrawAmount(defaultAmount);
    setWithdrawMethod(status?.instant_eligible ? "instant" : "standard");
    setWithdrawOpen(true);
  }, [status?.instant_eligible]);

  return {
    status,
    withdrawals,
    onboardLoading,
    selectedCountry,
    setSelectedCountry,
    withdrawOpen,
    setWithdrawOpen,
    withdrawAmount,
    setWithdrawAmount,
    withdrawMethod,
    setWithdrawMethod,
    withdrawLoading,
    reload,
    onboard,
    withdraw,
    openWithdraw,
  };
}

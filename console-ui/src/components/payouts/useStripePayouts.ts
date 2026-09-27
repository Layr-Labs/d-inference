"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { startStripeOnboarding, createStripeDashboardLink, unlinkStripeAccount } from "@/lib/api";
import { classifyDashboardError, classifyOnboardError } from "./payout-copy";
import { useStripeWithdrawal } from "./useStripeWithdrawal";
import type { StripePayoutsOptions, UseStripePayouts } from "./payouts-types";
export type { StripePayoutsOptions, UseStripePayouts } from "./payouts-types";

// Bank setup and destination management, shared by billing and earnings.
export function useStripePayouts(opts: StripePayoutsOptions): UseStripePayouts {
  const { addToast, enabled = true } = opts;
  const withdrawal = useStripeWithdrawal(opts);
  const { status, reload } = withdrawal;
  const [onboardLoading, setOnboardLoading] = useState(false);
  const [selectedCountry, setSelectedCountry] = useState("");

  // Once a Stripe Express account exists its country is locked — pre-select it.
  useEffect(() => {
    if (status?.stripe_account_country) {
      setSelectedCountry(status.stripe_account_country);
    }
  }, [status?.stripe_account_country]);

  const onboard = useCallback(async () => {
    setOnboardLoading(true);
    try {
      const returnURL = typeof window !== "undefined"
        ? `${window.location.origin}${window.location.pathname}?stripe_return=1`
        : undefined;
      const resp = await startStripeOnboarding(returnURL, selectedCountry || undefined);
      window.location.href = resp.url;
    } catch (e) {
      const p = classifyOnboardError(e);
      addToast(p.message);
      if (p.refreshStatus) await reload(false);
      setOnboardLoading(false);
    }
  }, [selectedCountry, addToast, reload]);

  // Changing the payout bank account happens in Stripe's Express Dashboard,
  // reached through a single-use login link. The tab is opened synchronously
  // inside the click gesture, because opening it after the await would be
  // swallowed by the popup blocker; `opener = null` disowns it before it ever
  // points at Stripe. Every navigation uses replace() so the credential never
  // lands in session history, and a blocked or closed tab falls back to this
  // one rather than burning a link that can't be reissued.
  const [dashboardLoading, setDashboardLoading] = useState(false);

  // The dashboard opens in another tab, so this one keeps rendering whatever
  // destination it loaded before the bank change — and openWithdraw seeds the
  // method from that same stale instant_eligible, which can push a card-only
  // instant payout at an account that now has a bank. Arm a one-shot refresh
  // for when the user comes back. refresh=1, not the cached read: the
  // account.updated webhook that mirrors the new destination may not have
  // landed yet. The listener lives in an effect (not inside openDashboard) so
  // it is torn down if the page unmounts before the user ever returns.
  const dashboardReturnPending = useRef(false);
  useEffect(() => {
    if (!enabled) return;
    const onVisible = () => {
      if (document.visibilityState !== "visible") return;
      if (!dashboardReturnPending.current) return;
      dashboardReturnPending.current = false;
      void reload(true);
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [enabled, reload]);

  const openDashboard = useCallback(async () => {
    setDashboardLoading(true);
    const tab = window.open("", "_blank");
    if (tab) tab.opener = null;
    try {
      const { url } = status?.payout_rail === "global"
        ? await startStripeOnboarding(`${window.location.origin}${window.location.pathname}?stripe_return=1`, status.stripe_account_country)
        : await createStripeDashboardLink();
      if (!url) throw new Error("Stripe didn't return a dashboard link.");
      if (tab && !tab.closed) {
        tab.location.replace(url);
        dashboardReturnPending.current = true;
      } else {
        // Same-tab fallback: this page unloads, so there is nothing to keep
        // fresh — coming back remounts and reloads from scratch.
        window.location.replace(url);
      }
    } catch (e) {
      tab?.close();
      const p = classifyDashboardError(e);
      addToast(p.message);
      if (p.refreshStatus) await reload(false);
    }
    setDashboardLoading(false);
  }, [addToast, reload, status?.payout_rail, status?.stripe_account_country]);

  const [unlinkLoading, setUnlinkLoading] = useState(false);
  const unlink = useCallback(async () => {
    setUnlinkLoading(true);
    try {
      await unlinkStripeAccount();
      setSelectedCountry("");
      addToast("Stripe account unlinked — you can now set up payouts again", "success");
      await reload(false);
    } catch (e) {
      addToast(`Unlink failed: ${(e as Error).message}`);
    }
    setUnlinkLoading(false);
  }, [addToast, reload]);

  return { ...withdrawal, onboardLoading, selectedCountry, setSelectedCountry, onboard, openDashboard, dashboardLoading, unlink, unlinkLoading };
}

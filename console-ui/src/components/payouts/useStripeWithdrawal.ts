"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { fetchStripeStatus, fetchStripeWithdrawals, fetchBankWithdrawalQuote, withdrawStripe, type BankWithdrawalQuote, type StripeStatus, type StripeWithdrawal } from "@/lib/api";
import { classifyWithdrawError, withdrawSuccessMessage } from "./payout-copy";
import { loadBankConfirmation, saveBankConfirmation, clearBankConfirmation } from "./bank-withdrawal-recovery";
import type { StripePayoutsOptions, WithdrawMethod } from "./payouts-types";

// Status loading restores the durable confirmation before enabling withdrawals.
// Bank onboarding and destination changes are handled by useStripePayouts.
export function useStripeWithdrawal(opts: StripePayoutsOptions) {
  const { addToast, enabled = true, onAfterWithdraw, onWithdrawStart, onWithdrawSuccess, onWithdrawError } = opts;
  const toastRef = useRef(addToast);
  useEffect(() => { toastRef.current = addToast; }, [addToast]);
  const [recoveryLoaded, setRecoveryLoaded] = useState(false);
  const [status, setStatus] = useState<StripeStatus | null>(null);
  const [withdrawals, setWithdrawals] = useState<StripeWithdrawal[]>([]);
  const [withdrawOpen, setWithdrawOpen] = useState(false);
  const [withdrawAmount, setWithdrawAmountState] = useState("10");
  const [withdrawQuote, setWithdrawQuote] = useState<BankWithdrawalQuote | null>(null);
  const [withdrawConfirmationPending, setWithdrawConfirmationPending] = useState(false);
  const setWithdrawAmount = useCallback((value: string) => { if (!withdrawConfirmationPending) { setWithdrawAmountState(value); setWithdrawQuote(null); } }, [withdrawConfirmationPending]);
  const [withdrawMethod, setWithdrawMethod] = useState<WithdrawMethod>("standard");
  const [withdrawLoading, setWithdrawLoading] = useState(false);
  const reload = useCallback(async (refresh = false) => {
    setRecoveryLoaded(false);
    try {
      const [s, wds] = await Promise.all([
        fetchStripeStatus(refresh),
        fetchStripeWithdrawals(20).catch(() => [] as StripeWithdrawal[]),
      ]);
      const saved = s.account_id ? loadBankConfirmation(s.account_id) : null;
      if (saved) {
        setWithdrawAmountState(saved.amount_usd);
        setWithdrawQuote(saved);
        setWithdrawConfirmationPending(true);
      } else {
        setWithdrawQuote(null);
        setWithdrawConfirmationPending(false);
      }
      setStatus(saved ? { ...s, payout_rail: "global", payout_currency: saved.currency, destination_last4: saved.destination_last4 } : s);
      setWithdrawals(wds);
      setRecoveryLoaded(true);
    } catch (e) {
      // Silent — Stripe Payouts is optional infrastructure.
      console.warn("stripe status fetch failed:", (e as Error).message);
    }
  }, []);

  // On mount (when enabled), load status and detect a return from the
  // Stripe-hosted onboarding flow (?stripe_return=1 → refresh + toast).
  useEffect(() => {
    if (!enabled) {
      setRecoveryLoaded(false);
      setStatus(null);
      return;
    }
    const params = typeof window !== "undefined" ? new URLSearchParams(window.location.search) : null;
    const justReturned = params?.get("stripe_return") === "1";
    reload(justReturned);
    if (justReturned) {
      toastRef.current("Stripe onboarding complete — verifying...", "success");
      const url = new URL(window.location.href);
      url.searchParams.delete("stripe_return");
      window.history.replaceState({}, "", url.toString());
    }
  }, [enabled, reload]);

  const withdraw = useCallback(async () => {
    setWithdrawLoading(true);
    const global = status?.payout_rail === "global";
    try {
      if (!enabled || !recoveryLoaded) throw new Error("We are still checking your previous withdrawals. Please refresh your payout details before withdrawing.");
      const saved = status?.account_id ? loadBankConfirmation(status.account_id) : null;
      if (saved && saved.id !== withdrawQuote?.id) {
        setWithdrawAmountState(saved.amount_usd);
        setWithdrawQuote(saved);
        setWithdrawConfirmationPending(true);
        setStatus(current => current ? { ...current, payout_rail: "global", payout_currency: saved.currency, destination_last4: saved.destination_last4 } : current);
        addToast("Check your existing withdrawal before starting another.");
        return;
      }
      if (global && (!withdrawQuote || Number(withdrawQuote.amount_usd) !== Number(withdrawAmount) || (Date.parse(withdrawQuote.expires_at) <= Date.now() && !withdrawConfirmationPending))) {
        setWithdrawQuote(await fetchBankWithdrawalQuote(withdrawAmount));
        return;
      }
      onWithdrawStart?.(withdrawMethod);
      if (global) {
        if (!withdrawQuote) throw new Error("Review your withdrawal before confirming.");
        saveBankConfirmation(status?.account_id ?? "", withdrawQuote);
        setWithdrawConfirmationPending(true);
      }
      const resp = await withdrawStripe(withdrawAmount, global ? "standard" : withdrawMethod, global ? withdrawQuote?.id : undefined);
      if (global && withdrawQuote) clearBankConfirmation(status?.account_id ?? "", withdrawQuote.id);
      if (resp.refunded) {
        addToast("The withdrawal could not be completed. The funds are back in your available earnings.", "error");
      } else {
        onWithdrawSuccess?.(withdrawMethod);
        addToast(withdrawSuccessMessage(resp), "success");
      }
      setWithdrawOpen(false);
      setWithdrawConfirmationPending(false);
      setWithdrawQuote(null);
      await Promise.all([onAfterWithdraw?.(), reload(false)]);
    } catch (e) {
      onWithdrawError?.();
      const p = classifyWithdrawError(e);
      addToast(p.message);
      if (["quote_expired", "payout_changed", "quote_required", "insufficient_withdrawable"].includes(p.code)) {
        try {
          if (global && withdrawQuote) clearBankConfirmation(status?.account_id ?? "", withdrawQuote.id);
          setWithdrawQuote(null);
          setWithdrawConfirmationPending(false);
        } catch (storageError) {
          addToast((storageError as Error).message);
        }
      }
      if (p.closeModal) setWithdrawOpen(false);
      if (p.refreshStatus) await reload(status?.payout_rail === "global");
      // Keep the quote ID after a lost response so retrying confirmation
      // resolves the same withdrawal instead of creating another debit.
    } finally {
      setWithdrawLoading(false);
    }
  }, [enabled, recoveryLoaded, status?.account_id, status?.payout_rail, withdrawQuote, withdrawConfirmationPending, withdrawAmount, withdrawMethod, addToast, onAfterWithdraw, reload, onWithdrawStart, onWithdrawSuccess, onWithdrawError]);

  const openWithdraw = useCallback((defaultAmount = "10") => {
    if (!withdrawConfirmationPending) { setWithdrawAmount(defaultAmount); setWithdrawQuote(null); }
    setWithdrawMethod(status?.instant_eligible ? "instant" : "standard");
    setWithdrawOpen(true);
  }, [status?.instant_eligible, setWithdrawAmount, withdrawConfirmationPending]);

  return { status, withdrawals, withdrawOpen, setWithdrawOpen, withdrawAmount, setWithdrawAmount, withdrawMethod, setWithdrawMethod, withdrawLoading, withdrawQuote, withdrawConfirmationPending, reload, withdraw, openWithdraw };
}

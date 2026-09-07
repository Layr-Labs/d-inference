"use client";

import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { usePathname } from "next/navigation";
import { useAuthContext } from "@/components/providers/PrivyClientProvider";
import { applyReferral } from "@/lib/api/referrals";
import { useToastStore } from "@/hooks/useToast";
import { captureReferral, clearReferral, normalizeReferral, readReferral } from "./attribution";

type AttributionState = {
  code: string | null;
  status: "idle" | "applying" | "applied" | "error";
  error: string | null;
};
type Attribution = AttributionState & { apply: (code?: string) => Promise<boolean>; dismiss: () => void };
const initialState: AttributionState = { code: null, status: "idle", error: null };
const Context = createContext<Attribution>({ ...initialState, apply: async () => false, dismiss: () => {} });

export function ReferralAttributionProvider({ children }: { children: React.ReactNode }) {
  const { ready, authenticated, user, getAccessToken } = useAuthContext();
  const accountID = (user as { id?: string } | null)?.id ?? null;
  const account = authenticated ? accountID : null;
  const pathname = usePathname();
  const [state, setState] = useState<AttributionState>(initialState);
  const attempted = useRef(new Set<string>());
  const inFlight = useRef(false);
  const activeAccount = useRef(account);
  const previousAccount = useRef(account);
  activeAccount.current = account;

  useEffect(() => {
    if (previousAccount.current === account) return;
    previousAccount.current = account;
    setState((previous) => ({ ...initialState, code: previous.status === "applied" ? null : previous.code }));
  }, [account]);

  useEffect(() => {
    const code = captureReferral(window.location.search);
    if (code) setState((previous) => previous.code === code ? previous : { code, status: "idle", error: null });
  }, [pathname]);

  const apply = useCallback(async (manualCode?: string): Promise<boolean> => {
    const code = normalizeReferral(manualCode ?? state.code);
    if (!code || !ready || !authenticated || !account || inFlight.current) return false;
    inFlight.current = true;
    attempted.current.add(`${account}:${code}`);
    setState({ code, status: "applying", error: null });
    try {
      const token = await getAccessToken();
      if (!token) throw new Error("Your session is not ready. Please try again.");
      if (activeAccount.current !== account) return false;
      await applyReferral(token, code);
      if (activeAccount.current !== account) return false;
      clearReferral(code);
      setState({ code, status: "applied", error: null });
      useToastStore.getState().addToast(`Referral ${code} applied. View it in the Open Sales Program.`, "success");
      return true;
    } catch (error) {
      if (activeAccount.current === account) {
        setState({ code, status: "error", error: error instanceof Error ? error.message : "Unable to apply referral. Please try again." });
        useToastStore.getState().addToast("Your referral could not be applied. Visit the Open Sales Program to review or retry it.", "info");
      }
      return false;
    } finally {
      inFlight.current = false;
      if (activeAccount.current !== account) setState({ ...initialState, code: readReferral() });
    }
  }, [state.code, ready, authenticated, account, getAccessToken]);

  useEffect(() => {
    if (ready && authenticated && account && state.code && state.status === "idle" && !attempted.current.has(`${account}:${state.code}`)) {
      void apply();
    }
  }, [ready, authenticated, account, state, apply]);

  const dismiss = useCallback(() => {
    if (inFlight.current) return;
    if (state.code) clearReferral(state.code);
    setState(initialState);
  }, [state.code]);

  const visibleState = previousAccount.current === account ? state : initialState;
  return <Context.Provider value={{ ...visibleState, apply, dismiss }}>{children}</Context.Provider>;
}

export const useReferralAttribution = () => useContext(Context);

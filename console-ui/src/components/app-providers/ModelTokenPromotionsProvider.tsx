"use client";

import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { useAuthContext } from "./PrivyClientProvider";

import { fetchModelTokenPromotions, type ModelTokenGrant, type ModelTokenOffer } from "@/lib/api/model-token-promotions";
export type { ModelTokenGrant, ModelTokenOffer } from "@/lib/api/model-token-promotions";

interface PromotionState {
  grants: ModelTokenGrant[];
  offers: ModelTokenOffer[];
  ready: boolean;
  claimingModel: string | null;
  error: string | null;
  refresh: () => void;
  claim: (model: string) => void;
}
const EMPTY = { grants: [] as ModelTokenGrant[], offers: [] as ModelTokenOffer[], ready: false, claimingModel: null as string | null, error: null as string | null };
const PromotionContext = createContext<PromotionState>({ ...EMPTY, ready: true, refresh: () => {}, claim: () => {} });
export const PROMOTION_USAGE_EVENT = "darkbloom-promotion-usage";
export function useModelTokenPromotions() { return useContext(PromotionContext); }

export function ModelTokenPromotionsProvider({ children }: { children: React.ReactNode }) {
  const { authenticated, user, getAccessToken } = useAuthContext();
  const account = authenticated ? user?.id ?? null : null;
  const identity = useRef(account);
  identity.current = account;
  const sequence = useRef(0);
  const pendingClaim = useRef<{ account: string; sequence: number } | null>(null);
  const [state, setState] = useState({ ...EMPTY, account: null as string | null });

  const load = useCallback(async (model?: string) => {
    if (!account || pendingClaim.current?.account === account) return;
    const requestSequence = ++sequence.current;
    const current = () => identity.current === account && sequence.current === requestSequence;
    if (model) {
      pendingClaim.current = { account, sequence: requestSequence };
      setState((prior) => ({ ...(prior.account === account ? prior : EMPTY), account, claimingModel: model, error: null }));
    }
    try {
      const token = await getAccessToken();
      if (!current()) return;
      if (!token) throw new Error("Please sign in again to view or claim model tokens.");
      const data = await fetchModelTokenPromotions(token, model);
      if (current()) setState({ account, grants: data.grants, offers: data.offers, ready: true, claimingModel: null, error: null });
    } catch (error) {
      if (current()) setState((prior) => ({ ...(prior.account === account ? prior : EMPTY), account, claimingModel: null, error: error instanceof Error ? error.message : "Unable to load model tokens." }));
    } finally {
      if (pendingClaim.current?.sequence === requestSequence) pendingClaim.current = null;
    }
  }, [account, getAccessToken]);

  useEffect(() => {
    const requestSequence = sequence;
    void load();
    const refresh = () => { void load(); };
    window.addEventListener(PROMOTION_USAGE_EVENT, refresh);
    window.addEventListener("focus", refresh);
    const timer = window.setInterval(refresh, 60_000);
    return () => {
      ++requestSequence.current;
      window.clearInterval(timer);
      window.removeEventListener(PROMOTION_USAGE_EVENT, refresh);
      window.removeEventListener("focus", refresh);
    };
  }, [load]);

  const visible = account && state.account === account ? state : EMPTY;
  return <PromotionContext.Provider value={{ ...visible, ready: !account || visible.ready,
    refresh: () => { void load(); }, claim: (model) => { void load(model); },
  }}>{children}</PromotionContext.Provider>;
}

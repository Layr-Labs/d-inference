"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "@/lib/api/errors";
import { fetchReferralInfo, fetchReferralStats, type ReferralInfo, type ReferralStats } from "@/lib/api/referrals";

type AccountData = { account: string | null; info: ReferralInfo | null; stats: ReferralStats | null; loading: boolean; error: string | null };
const empty: AccountData = { account: null, info: null, stats: null, loading: false, error: null };

export function useReferralAccount(account: string | null, getAccessToken: () => Promise<string | null>, attributionStatus: string) {
  const [data, setData] = useState<AccountData>(empty);
  const request = useRef(0);
  const activeAccount = useRef(account);
  const mounted = useRef(true);
  activeAccount.current = account;
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  const refresh = useCallback(async () => {
    if (!mounted.current || activeAccount.current !== account) return;
    const current = ++request.current;
    const stillCurrent = () => mounted.current && activeAccount.current === account && current === request.current;
    if (!account) { setData(empty); return; }
    setData((previous) => ({ ...(previous.account === account ? previous : empty), account, loading: true, error: null }));
    try {
      const token = await getAccessToken();
      if (!stillCurrent()) return;
      if (!token) throw new Error("Your session is not ready. Please try again.");
      const [info, stats] = await Promise.all([
        fetchReferralInfo(token),
        fetchReferralStats(token).catch((error: unknown) => {
          if (error instanceof ApiError && error.status === 404) return null;
          throw error;
        }),
      ]);
      if (info.code && !stats) throw new Error("Your referral totals are unavailable. Please try again.");
      if (stillCurrent()) setData({ account, info, stats, loading: false, error: null });
    } catch (error) {
      if (stillCurrent()) setData({ ...empty, account, error: error instanceof Error ? error.message : "Unable to load referrals." });
    }
  }, [account, getAccessToken]);

  useEffect(() => {
    void refresh();
    // This ref is a request generation, not a DOM ref; invalidate every request
    // on account change or unmount, including a manual refresh still in flight.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    return () => { request.current++; };
  }, [refresh, attributionStatus]);

  return { ...(data.account === account ? data : { ...empty, loading: !!account }), refresh };
}

import { managementHeaders } from "../http/proxy-client";
import { apiErrorFromBody } from "./errors";

export interface ReferralInfo {
  code: string;
  share_percent: number;
  reward_basis: "consumer_spend";
  referred_by: string;
}

export interface ReferralStats {
  code: string;
  share_percent: number;
  reward_basis: "consumer_spend";
  total_referred: number;
  total_rewards_micro_usd: number;
  total_rewards_usd: string;
  total_referred_spend_micro_usd: number;
  total_referred_spend_usd: string;
  balance_micro_usd: number;
  balance_usd: string;
}

async function referralRequest<T>(token: string, action: string, code?: string): Promise<T> {
  const res = await fetch(`/api/referral/${action}`, {
    method: code === undefined ? "GET" : "POST",
    headers: managementHeaders(token),
    ...(code === undefined ? {} : { body: JSON.stringify({ code }) }),
    cache: "no-store",
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw apiErrorFromBody(data, res.status, "Unable to load referrals. Please try again.");
  return data as T;
}

export const fetchReferralInfo = (token: string) => referralRequest<ReferralInfo>(token, "info");
export const fetchReferralStats = (token: string) => referralRequest<ReferralStats>(token, "stats");
export const registerReferral = (token: string, code: string) => referralRequest<{ code: string }>(token, "register", code);
export const applyReferral = (token: string, code: string) => referralRequest<{ status: "applied"; code: string }>(token, "apply", code);

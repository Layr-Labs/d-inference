"use client";

import { useAuthContext } from "@/components/providers/PrivyClientProvider";
import { ReferralRegistration, referralButtonClass } from "./ReferralRegistration";
import { ReferralEarnings } from "./ReferralEarnings";
import { ReferralApply } from "./ReferralApply";
import { useReferralAccount } from "./useReferralAccount";
import { useReferralAttribution } from "./ReferralAttributionProvider";

export function ReferralAccountPanel() {
  const { ready, authenticated, user, getAccessToken, login } = useAuthContext();
  const accountID = (user as { id?: string } | null)?.id ?? null;
  const account = authenticated ? accountID : null;
  const attribution = useReferralAttribution();
  const revision = attribution.status === "applied" ? attribution.code ?? "applied" : "pending";
  const data = useReferralAccount(account, getAccessToken, revision);

  if (!ready) return <p role="status" className="py-8 text-sm text-text-secondary">Loading your account…</p>;
  if (!authenticated) return (
    <div className="py-8">
      {attribution.code && <p className="mb-4 text-sm text-text-secondary">Referral code {attribution.code} is saved and will be applied after you sign in.</p>}
      <button onClick={login} className={referralButtonClass}>Sign in to get your link</button>
    </div>
  );
  if (!account) return <p role="status" className="py-8 text-sm text-text-secondary">Sign in with a Darkbloom account to manage referrals.</p>;
  if (data.loading) return <p role="status" className="py-8 text-sm text-text-secondary">Loading referrals…</p>;
  if (data.error) return (
    <div className="py-8">
      <p role="alert" className="text-sm text-red-500">{data.error}</p>
      <button onClick={data.refresh} className="mt-3 min-h-10 text-sm font-medium text-accent-brand hover:underline">Try again</button>
    </div>
  );
  if (!data.info) return null;
  return (
    <>
      {data.stats ? <ReferralEarnings stats={data.stats} /> : <ReferralRegistration accountID={account} getAccessToken={getAccessToken} onRegistered={data.refresh} />}
      <ReferralApply referredBy={data.info.referred_by} />
    </>
  );
}

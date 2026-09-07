"use client";

import { useState, type FormEvent } from "react";
import { useReferralAttribution } from "./ReferralAttributionProvider";
import { normalizeReferral } from "./attribution";
import { referralButtonClass, referralInputClass } from "./ReferralRegistration";

export function ReferralApply({ referredBy }: { referredBy: string }) {
  const attribution = useReferralAttribution();
  const [code, setCode] = useState("");
  const [validationError, setValidationError] = useState<string | null>(null);
  const savedCode = attribution.status === "applied" ? null : attribution.code;
  const busy = attribution.status === "applying";
  const applied = referredBy || (attribution.status === "applied" ? attribution.code : null);

  async function apply(event: FormEvent) {
    event.preventDefault(); setValidationError(null);
    const normalized = normalizeReferral(savedCode ?? code);
    if (!normalized) { setValidationError("Enter a valid referral code using letters, numbers, or hyphens."); return; }
    await attribution.apply(normalized);
  }

  return (
    <section className="py-7">
      <h2 className="text-lg font-medium text-text-primary">Who introduced you?</h2>
      {applied ? <>
        <p role="status" className="mt-3 text-sm text-text-secondary">Referred by {applied}. They earn rewards on your billed token usage at no extra cost to you.</p>
        {savedCode && savedCode !== applied && <div className="mt-3 text-sm text-text-secondary">
          <p>The saved code {savedCode} cannot replace your existing referrer.</p>
          <button type="button" onClick={attribution.dismiss} disabled={busy} className="min-h-10 text-accent-brand hover:underline">Remove saved code</button>
        </div>}
      </> : (
        <>
          <p className="mt-2 text-sm leading-relaxed text-text-secondary">Apply the code of the person who introduced you to Darkbloom. One referrer per account; it cannot be changed after it is applied.</p>
          <form onSubmit={apply} className="mt-5">
            <label htmlFor="apply-referral" className="mb-2 block text-sm font-medium">Referral code you received</label>
            <div className="flex flex-col gap-3 sm:flex-row">
              <input id="apply-referral" value={savedCode ?? code} onChange={(event) => setCode(event.target.value)} readOnly={!!savedCode} maxLength={20} required disabled={busy} autoComplete="off" spellCheck={false} className={referralInputClass} placeholder="THEIR-CODE" />
              <button disabled={busy} className={referralButtonClass}>{busy ? "Applying…" : "Apply referral code"}</button>
            </div>
            {savedCode && <div className="mt-2 flex flex-wrap items-center gap-x-3 text-xs text-text-secondary"><span>Saved from the first referral link you opened.</span><button type="button" onClick={attribution.dismiss} disabled={busy} className="min-h-9 text-accent-brand hover:underline">Remove saved code</button></div>}
            {(validationError || attribution.error) && <p role="alert" className="mt-3 text-sm text-red-500">{validationError || attribution.error}</p>}
          </form>
        </>
      )}
      <p className="mt-4 text-xs leading-relaxed text-text-tertiary">Referral codes reward the referrer. Invite codes add promotional credits and are redeemed separately in Billing.</p>
    </section>
  );
}

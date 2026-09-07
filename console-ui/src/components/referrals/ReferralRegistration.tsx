"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import { registerReferral } from "@/lib/api/referrals";
import { normalizeRegistrationCode } from "./attribution";

export const referralInputClass = "min-h-11 w-full rounded-lg border border-border-default bg-bg-primary px-3 text-sm text-text-primary placeholder:text-text-tertiary focus:border-accent-brand focus:outline-none focus:ring-1 focus:ring-accent-brand";
export const referralButtonClass = "inline-flex min-h-11 shrink-0 items-center justify-center rounded-lg bg-accent-brand px-4 text-sm font-medium text-white hover:bg-accent-brand-hover disabled:opacity-50 dark:text-bg-primary";

export function ReferralRegistration({ accountID, getAccessToken, onRegistered }: { accountID: string; getAccessToken: () => Promise<string | null>; onRegistered: () => Promise<void> }) {
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const lifetime = useRef({ accountID, generation: 0, mounted: true });
  if (lifetime.current.accountID !== accountID) {
    lifetime.current = { accountID, generation: lifetime.current.generation + 1, mounted: true };
  }
  useEffect(() => {
    lifetime.current.mounted = true;
    return () => { lifetime.current.mounted = false; lifetime.current.generation++; };
  }, []);
  useEffect(() => { setCode(""); setBusy(false); setError(null); }, [accountID]);

  async function register(event: FormEvent) {
    event.preventDefault();
    const normalized = normalizeRegistrationCode(code);
    if (!normalized) { setError("Use 3–20 letters, numbers, or hyphens. Start and end with a letter or number."); return; }
    const generation = lifetime.current.generation;
    const stillCurrent = () => lifetime.current.mounted && lifetime.current.generation === generation;
    setBusy(true); setError(null);
    try {
      const token = await getAccessToken();
      if (!stillCurrent()) return;
      if (!token) throw new Error("Your session is not ready. Please try again.");
      await registerReferral(token, normalized);
      if (!stillCurrent()) return;
      await onRegistered();
    } catch (error) {
      if (stillCurrent()) setError(error instanceof Error ? error.message : "Unable to create your referral link.");
    } finally {
      if (stillCurrent()) setBusy(false);
    }
  }

  return (
    <section className="border-b border-border-dim py-7">
      <h2 className="text-lg font-medium text-text-primary">Create your referral link</h2>
      <p className="mt-2 text-sm leading-relaxed text-text-secondary">Choose a code people will remember. Your code is permanent and belongs to your account.</p>
      <form onSubmit={register} className="mt-5">
        <label htmlFor="register-referral" className="mb-2 block text-sm font-medium">Your referral code</label>
        <div className="flex flex-col gap-3 sm:flex-row">
          <input id="register-referral" value={code} onChange={(event) => setCode(event.target.value)} minLength={3} maxLength={20} required autoComplete="off" spellCheck={false} aria-describedby="referral-code-help" className={referralInputClass} placeholder="YOUR-NAME" disabled={busy} />
          <button disabled={busy} className={referralButtonClass}>{busy ? "Creating…" : "Create referral link"}</button>
        </div>
        <p id="referral-code-help" className="mt-2 text-xs text-text-tertiary">3–20 letters, numbers, or hyphens. No spaces.</p>
        {error && <p role="alert" className="mt-3 text-sm text-red-500">{error}</p>}
      </form>
    </section>
  );
}

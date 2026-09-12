"use client";

import { useState, useCallback, useEffect } from "react";
import Link from "next/link";
import { Ticket, X, Check, Loader2 } from "lucide-react";
import { redeemInviteCode } from "@/lib/api";
import { trackEvent } from "@/lib/google-analytics";

export const INVITE_DISMISSED_KEY = "darkbloom_invite_dismissed";
/** Fired on dismissal so other invitation surfaces can update. */
export const INVITE_DISMISSED_EVENT = "darkbloom-invite-dismissed";

export function InviteCodeBanner() {
  // Match the server on the first paint before reading browser-local state.
  const [dismissed, setDismissed] = useState(true);
  useEffect(() => {
    setDismissed(localStorage.getItem(INVITE_DISMISSED_KEY) === "1");
  }, []);
  const [expanded, setExpanded] = useState(false);
  const [code, setCode] = useState("");
  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState("");
  const [error, setError] = useState("");

  const dismissBanner = useCallback(() => {
    setDismissed(true);
    localStorage.setItem(INVITE_DISMISSED_KEY, "1");
    window.dispatchEvent(new Event(INVITE_DISMISSED_EVENT));
  }, []);

  useEffect(() => {
    if (!success) return;
    const timeout = setTimeout(dismissBanner, 3000);
    return () => clearTimeout(timeout);
  }, [success, dismissBanner]);

  const handleRedeem = useCallback(async () => {
    const trimmed = code.trim().toUpperCase();
    if (!trimmed || loading) return;
    trackEvent("invite_redeem_submitted", { surface: "banner" });
    setLoading(true);
    setError("");
    try {
      const result = await redeemInviteCode(trimmed);
      trackEvent("invite_redeem_succeeded", { surface: "banner", credited_usd: result.credited_usd });
      setSuccess(`$${result.credited_usd} added to your account`);
      setCode("");
    } catch (cause) {
      trackEvent("invite_redeem_failed", { surface: "banner" });
      setError((cause as Error).message);
    } finally {
      setLoading(false);
    }
  }, [code, loading]);

  if (dismissed) return null;

  return (
    <div className="mx-auto mt-6 max-w-md text-xs">
      <div className="flex items-center justify-center gap-2">
        <button
          type="button"
          aria-expanded={expanded}
          onClick={() => {
            if (!expanded) trackEvent("invite_banner_expanded", { source: "header" });
            setExpanded(!expanded);
          }}
          className="flex min-h-8 items-center gap-2 rounded-lg px-2 text-text-secondary hover:bg-bg-secondary hover:text-text-primary"
        >
          <Ticket size={13} />
          Have an invite code? <span className="text-accent-brand">Add credits</span>
        </button>
        <button
          type="button"
          aria-label="Dismiss invite code reminder"
          onClick={() => { trackEvent("invite_banner_dismissed"); dismissBanner(); }}
          className="flex h-8 w-8 items-center justify-center rounded-lg text-text-tertiary hover:bg-bg-secondary hover:text-text-primary"
        ><X size={13} /></button>
      </div>

      {expanded && !success && (
        <form onSubmit={(event) => { event.preventDefault(); void handleRedeem(); }} className="mt-3 rounded-xl border border-border-dim bg-bg-white p-4">
          <label htmlFor="chat-invite-code" className="mb-2 block font-medium text-text-primary">Invite code</label>
          <div className="flex gap-2">
            <input
              id="chat-invite-code"
              type="text"
              value={code}
              onChange={(event) => { setError(""); setCode(event.target.value.replace(/[^A-Za-z0-9-]/g, "").toUpperCase()); }}
              placeholder="INV-XXXXXXXX"
              maxLength={20}
              disabled={loading}
              className="min-w-0 flex-1 rounded-lg border border-border-dim bg-bg-primary px-3 py-2.5 text-sm text-ink placeholder:text-text-tertiary"
              autoFocus
            />
            <button type="submit" disabled={loading || !code.trim()} className="flex items-center gap-2 rounded-lg bg-accent-brand px-4 py-2.5 text-xs font-medium text-white hover:bg-accent-brand-hover disabled:opacity-40 dark:text-bg-primary">
              {loading && <Loader2 size={14} className="animate-spin" />}
              {loading ? "Claiming…" : "Claim"}
            </button>
          </div>
          {error && <p className="mt-2 text-accent-red" role="alert">{error}</p>}
          <p className="mt-3 leading-relaxed text-text-secondary">Redeem a code for inference credits, or <Link href="/billing" className="text-accent-brand underline underline-offset-2">add credits in billing</Link>. A code isn’t required to run a provider.</p>
        </form>
      )}

      {success && <p className="mt-3 flex items-center justify-center gap-2 text-teal" role="status"><Check size={14} />{success}</p>}
    </div>
  );
}

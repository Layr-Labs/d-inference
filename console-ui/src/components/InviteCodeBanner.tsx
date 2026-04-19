"use client";

import { useState, useCallback } from "react";
import { Ticket, X, Check, Loader2 } from "lucide-react";
import { redeemInviteCode } from "@/lib/api";
import { trackEvent } from "@/lib/google-analytics";

const DISMISSED_KEY = "darkbloom_invite_dismissed";

export function InviteCodeBanner() {
  const [dismissed, setDismissed] = useState(() => {
    if (typeof window === "undefined") return true;
    return localStorage.getItem(DISMISSED_KEY) === "1";
  });
  const [expanded, setExpanded] = useState(false);
  const [code, setCode] = useState("");
  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState("");
  const [error, setError] = useState("");

  const dismissBanner = useCallback(() => {
    setDismissed(true);
    localStorage.setItem(DISMISSED_KEY, "1");
  }, []);

  const handleDismiss = useCallback(() => {
    trackEvent("invite_banner_dismissed");
    dismissBanner();
  }, [dismissBanner]);

  const handleRedeem = useCallback(async () => {
    const trimmed = code.trim().toUpperCase();
    if (!trimmed) return;

    trackEvent("invite_redeem_started", {
      surface: "banner",
    });
    setLoading(true);
    setError("");
    try {
      const result = await redeemInviteCode(trimmed);
      trackEvent("invite_redeem_succeeded", {
        surface: "banner",
        credited_usd: result.credited_usd,
      });
      setSuccess(`$${result.credited_usd} added to your account`);
      setCode("");
      setTimeout(() => {
        dismissBanner();
      }, 3000);
    } catch (e) {
      trackEvent("invite_redeem_failed", {
        surface: "banner",
      });
      setError((e as Error).message);
    }
    setLoading(false);
  }, [code, dismissBanner]);

  if (dismissed) return null;

  return (
    <div className="fixed bottom-24 right-3 sm:right-6 z-40 w-[calc(100%-1.5rem)] sm:w-auto sm:max-w-sm message-animate">
      <div className="bg-bg-white border border-border-dim rounded-xl shadow-lg overflow-hidden">
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3">
          <button
            onClick={() => {
              const nextExpanded = !expanded;
              if (nextExpanded) {
                trackEvent("invite_banner_expanded");
              }
              setExpanded(nextExpanded);
            }}
            className="flex items-center gap-2 text-sm font-semibold text-ink"
          >
            <div className="w-7 h-7 rounded-lg bg-gold-light border-2 border-gold flex items-center justify-center">
              <Ticket size={14} className="text-gold" />
            </div>
            Got an invite code?
          </button>
          <button
            onClick={handleDismiss}
            className="p-1 rounded-lg hover:bg-bg-hover text-text-tertiary hover:text-text-primary transition-colors"
          >
            <X size={14} />
          </button>
        </div>

        {/* Expandable input */}
        {!expanded && !success && (
          <div className="px-4 pb-3">
            <button
              onClick={() => {
                trackEvent("invite_banner_expanded", {
                  source: "claim_button",
                });
                setExpanded(true);
              }}
              className="w-full py-2 rounded-lg bg-gold-light border-2 border-gold text-ink text-xs font-bold
                         transition-all"
            >
              Claim invite code
            </button>
          </div>
        )}

        {expanded && !success && (
          <div className="px-4 pb-4 space-y-2">
            <div className="flex gap-2">
              <input
                type="text"
                value={code}
                onChange={(e) => {
                  setError("");
                  setCode(e.target.value.replace(/[^A-Za-z0-9-]/g, "").toUpperCase());
                }}
                placeholder="INV-XXXXXXXX"
                maxLength={20}
                className="flex-1 bg-bg-primary border-2 border-border-dim rounded-lg px-3 py-2 text-ink font-mono text-sm tracking-wider
                           outline-none focus:border-coral transition-colors placeholder:text-text-tertiary/50"
                onKeyDown={(e) => e.key === "Enter" && handleRedeem()}
                autoFocus
              />
              <button
                onClick={handleRedeem}
                disabled={loading || !code.trim()}
                className="px-4 py-2 rounded-lg bg-coral border-2 border-ink text-white text-sm font-bold
                           disabled:opacity-40
                           hover:opacity-90 transition-all"
              >
                {loading ? <Loader2 size={14} className="animate-spin" /> : "Claim"}
              </button>
            </div>
            {error && (
              <p className="text-xs text-accent-red font-semibold">{error}</p>
            )}
          </div>
        )}

        {/* Success */}
        {success && (
          <div className="px-4 pb-4">
            <div className="flex items-center gap-2 text-teal text-sm font-semibold">
              <Check size={14} />
              {success}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

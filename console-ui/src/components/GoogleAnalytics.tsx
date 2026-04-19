"use client";

import { useEffect, useState } from "react";
import Script from "next/script";
import { usePathname } from "next/navigation";
import {
  getGoogleAnalyticsConsentStatus,
  getGoogleAnalyticsMeasurementId,
  getGoogleAnalyticsConsentStorageKey,
  grantGoogleAnalyticsConsent,
  initializeGoogleAnalytics,
  revokeGoogleAnalyticsConsent,
  trackRouteChange,
} from "@/lib/google-analytics";

export function GoogleAnalytics() {
  const pathname = usePathname();
  const measurementId = getGoogleAnalyticsMeasurementId();
  const [hasConsent, setHasConsent] = useState(false);
  const [consentState, setConsentState] = useState<"granted" | "denied" | "unset">(
    "unset",
  );

  useEffect(() => {
    const syncConsentState = () => {
      const nextConsentState = getGoogleAnalyticsConsentStatus();
      setConsentState(nextConsentState);
      setHasConsent(nextConsentState === "granted");
    };

    syncConsentState();
    window.addEventListener("darkbloom-ga-consent-changed", syncConsentState);
    return () =>
      window.removeEventListener("darkbloom-ga-consent-changed", syncConsentState);
  }, []);

  useEffect(() => {
    if (!hasConsent) {
      return;
    }

    initializeGoogleAnalytics();
  }, [hasConsent]);

  useEffect(() => {
    if (!hasConsent || !pathname) {
      return;
    }

    trackRouteChange(pathname);
  }, [hasConsent, pathname]);

  if (!measurementId) {
    return null;
  }

  return (
    <>
      {hasConsent && (
        <Script
          src={`https://www.googletagmanager.com/gtag/js?id=${measurementId}`}
          strategy="afterInteractive"
        />
      )}
      {consentState === "unset" && !hasConsent && (
        <div className="fixed bottom-4 left-4 right-4 z-50 mx-auto max-w-xl rounded-xl border border-border-dim bg-bg-white/95 p-4 shadow-lg backdrop-blur">
          <p className="text-sm text-text-secondary">
            Allow anonymous analytics to help improve Darkbloom&apos;s product experience.
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            <button
              onClick={() => {
                grantGoogleAnalyticsConsent();
                setHasConsent(true);
              }}
              className="rounded-lg bg-coral px-4 py-2 text-sm font-semibold text-white hover:opacity-90 transition-all"
            >
              Allow analytics
            </button>
            <button
              onClick={() => {
                revokeGoogleAnalyticsConsent();
                setHasConsent(false);
              }}
              className="rounded-lg border border-border-dim px-4 py-2 text-sm font-semibold text-text-secondary hover:bg-bg-hover transition-all"
            >
              Decline
            </button>
            <span className="self-center text-xs text-text-tertiary">
              Stored in <code>{getGoogleAnalyticsConsentStorageKey()}</code>
            </span>
          </div>
        </div>
      )}
    </>
  );
}

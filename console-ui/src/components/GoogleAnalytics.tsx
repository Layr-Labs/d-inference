"use client";

import { useEffect, useState } from "react";
import Script from "next/script";
import { usePathname } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import {
  applyGoogleAnalyticsConsentState,
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
  const t = useTranslations("AnalyticsConsent");
  const measurementId = getGoogleAnalyticsMeasurementId();
  const [consentState, setConsentState] = useState<"granted" | "denied" | "unset">(
    () => getGoogleAnalyticsConsentStatus(),
  );
  const [hasConsent, setHasConsent] = useState(consentState === "granted");

  useEffect(() => {
    const syncConsentState = () => {
      const nextConsentState = getGoogleAnalyticsConsentStatus();
      setConsentState(nextConsentState);
      setHasConsent(nextConsentState === "granted");
    };

    syncConsentState();
    window.addEventListener("darkbloom-ga-consent-changed", syncConsentState);
    const onStorage = (event: StorageEvent) => {
      if (event.key === getGoogleAnalyticsConsentStorageKey()) {
        applyGoogleAnalyticsConsentState();
        syncConsentState();
      }
    };
    window.addEventListener("storage", onStorage);
    return () =>
      {
        window.removeEventListener("darkbloom-ga-consent-changed", syncConsentState);
        window.removeEventListener("storage", onStorage);
      };
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
            {t("body")}
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            <button
              onClick={() => {
                grantGoogleAnalyticsConsent();
                setHasConsent(true);
              }}
              className="rounded-lg bg-coral px-4 py-2 text-sm font-semibold text-white hover:opacity-90 transition-all"
            >
              {t("allow")}
            </button>
            <button
              onClick={() => {
                revokeGoogleAnalyticsConsent();
                setHasConsent(false);
              }}
              className="rounded-lg border border-border-dim px-4 py-2 text-sm font-semibold text-text-secondary hover:bg-bg-hover transition-all"
            >
              {t("decline")}
            </button>
            <span className="self-center text-xs text-text-tertiary">
              {t.rich("storedIn", {
                code: (chunks) => <code>{chunks}</code>,
                key: getGoogleAnalyticsConsentStorageKey(),
              })}
            </span>
          </div>
        </div>
      )}
    </>
  );
}

"use client";

import { useEffect } from "react";
import Script from "next/script";
import { usePathname } from "next/navigation";
import {
  getGoogleAnalyticsMeasurementId,
  isGoogleAnalyticsEnabled,
  initializeGoogleAnalytics,
  trackRouteChange,
} from "@/lib/google-analytics";

export function GoogleAnalytics() {
  const pathname = usePathname();

  useEffect(() => {
    initializeGoogleAnalytics();
  }, []);

  useEffect(() => {
    if (!isGoogleAnalyticsEnabled() || !pathname) {
      return;
    }

    trackRouteChange(pathname);
  }, [pathname]);

  const measurementId = getGoogleAnalyticsMeasurementId();
  if (!measurementId) {
    return null;
  }

  return (
    <Script
      src={`https://www.googletagmanager.com/gtag/js?id=${measurementId}`}
      strategy="afterInteractive"
    />
  );
}

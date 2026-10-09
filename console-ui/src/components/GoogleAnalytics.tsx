"use client";

import { useEffect } from "react";
import Script from "next/script";
import { usePathname } from "next/navigation";
import {
  getGoogleAnalyticsMeasurementId,
  initializeGoogleAnalytics,
  trackRouteChange,
} from "@/lib/google-analytics";

export function GoogleAnalytics() {
  const pathname = usePathname();
  const measurementId = getGoogleAnalyticsMeasurementId();

  useEffect(() => {
    if (!measurementId) {
      return;
    }

    initializeGoogleAnalytics();
  }, [measurementId]);

  useEffect(() => {
    if (!measurementId || !pathname) {
      return;
    }

    trackRouteChange(pathname);
  }, [measurementId, pathname]);

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

"use client";

import { useEffect } from "react";
import Script from "next/script";
import { usePathname, useSearchParams } from "next/navigation";
import {
  GA_MEASUREMENT_ID,
  initializeGoogleAnalytics,
  trackPageView,
} from "@/lib/google-analytics";

export function GoogleAnalytics() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const queryString = searchParams.toString();

  useEffect(() => {
    initializeGoogleAnalytics();
  }, []);

  useEffect(() => {
    if (!GA_MEASUREMENT_ID || !pathname) {
      return;
    }

    const pagePath = queryString ? `${pathname}?${queryString}` : pathname;

    trackPageView({
      page_location: window.location.href,
      page_path: pagePath,
      page_title: document.title,
    });
  }, [pathname, queryString]);

  if (!GA_MEASUREMENT_ID) {
    return null;
  }

  return (
    <Script
      src={`https://www.googletagmanager.com/gtag/js?id=${GA_MEASUREMENT_ID}`}
      strategy="afterInteractive"
    />
  );
}

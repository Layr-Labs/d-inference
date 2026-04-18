export const GA_MEASUREMENT_ID =
  process.env.NEXT_PUBLIC_GA_MEASUREMENT_ID?.trim() ?? "";

declare global {
  interface Window {
    dataLayer?: unknown[];
    gtag?: (...args: unknown[]) => void;
    __googleAnalyticsInitialized?: boolean;
  }
}

type GoogleAnalyticsEventParams = Record<
  string,
  string | number | boolean | undefined
>;

function getGtag() {
  if (typeof window === "undefined" || !GA_MEASUREMENT_ID) {
    return null;
  }

  window.dataLayer = window.dataLayer || [];
  window.gtag =
    window.gtag ||
    ((...args: unknown[]) => {
      window.dataLayer?.push(args);
    });

  return window.gtag;
}

export function initializeGoogleAnalytics() {
  const gtag = getGtag();
  if (!gtag || window.__googleAnalyticsInitialized) {
    return;
  }

  gtag("js", new Date());
  gtag("config", GA_MEASUREMENT_ID, {
    send_page_view: false,
  });
  window.__googleAnalyticsInitialized = true;
}

export function trackPageView(params: {
  page_location: string;
  page_path: string;
  page_title?: string;
}) {
  const gtag = getGtag();
  if (!gtag) {
    return;
  }

  gtag("event", "page_view", {
    ...params,
    send_to: GA_MEASUREMENT_ID,
  });
}

export function trackEvent(
  eventName: string,
  params: GoogleAnalyticsEventParams = {},
) {
  const gtag = getGtag();
  if (!gtag) {
    return;
  }

  gtag("event", eventName, params);
}

const ATTRIBUTION_QUERY_PARAMS = new Set([
  "_gl",
  "dclid",
  "fbclid",
  "gbraid",
  "gclid",
  "li_fat_id",
  "mc_cid",
  "mc_eid",
  "msclkid",
  "srsltid",
  "ttclid",
  "wbraid",
]);

declare global {
  interface Window {
    dataLayer?: unknown[];
    gtag?: (...args: unknown[]) => void;
    __googleAnalyticsInitialized?: boolean;
    __googleAnalyticsLastPageLocation?: string;
  }
}

export function getGoogleAnalyticsMeasurementId() {
  return process.env.NEXT_PUBLIC_GA_MEASUREMENT_ID?.trim() ?? "";
}

export function isGoogleAnalyticsEnabled() {
  return Boolean(getGoogleAnalyticsMeasurementId());
}

function getGtag() {
  const measurementId = getGoogleAnalyticsMeasurementId();
  if (typeof window === "undefined" || !measurementId) {
    return null;
  }

  window.dataLayer = window.dataLayer || [];
  window.gtag =
    window.gtag ||
    ((...args: unknown[]) => {
      window.dataLayer?.push(args);
    });

  return {
    gtag: window.gtag,
    measurementId,
  };
}

export function initializeGoogleAnalytics() {
  const analytics = getGtag();
  if (!analytics || window.__googleAnalyticsInitialized) {
    return;
  }

  analytics.gtag("js", new Date());
  analytics.gtag("config", analytics.measurementId, {
    send_page_view: false,
  });
  window.__googleAnalyticsInitialized = true;
}

function isAllowedAttributionParam(name: string) {
  return name.startsWith("utm_") || ATTRIBUTION_QUERY_PARAMS.has(name);
}

export function buildTrackedPageLocation(pathname: string) {
  if (typeof window === "undefined") {
    return "";
  }

  const pageUrl = new URL(pathname, window.location.origin);

  if (window.__googleAnalyticsLastPageLocation) {
    return pageUrl.toString();
  }

  // Keep attribution intact without forwarding arbitrary query params into GA.
  const attributionParams = new URLSearchParams();
  for (const [name, value] of new URLSearchParams(window.location.search)) {
    if (isAllowedAttributionParam(name)) {
      attributionParams.append(name, value);
    }
  }

  const attributionQuery = attributionParams.toString();
  if (attributionQuery) {
    pageUrl.search = attributionQuery;
  }

  return pageUrl.toString();
}

export function trackRouteChange(pathname: string) {
  const pageLocation = buildTrackedPageLocation(pathname);
  if (!pageLocation) {
    return;
  }

  trackPageView({
    page_location: pageLocation,
    page_title: document.title,
  });
}

function trackPageView(params: {
  page_location: string;
  page_title?: string;
}) {
  const analytics = getGtag();
  if (!analytics) {
    return;
  }

  const pageReferrer =
    window.__googleAnalyticsLastPageLocation || document.referrer || undefined;

  analytics.gtag("event", "page_view", {
    ...params,
    page_referrer: pageReferrer,
    send_to: analytics.measurementId,
  });

  window.__googleAnalyticsLastPageLocation = params.page_location;
}

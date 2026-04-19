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

const UTM_QUERY_PARAMS = new Set([
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_term",
  "utm_content",
  "utm_id",
  "utm_source_platform",
  "utm_creative_format",
  "utm_marketing_tactic",
]);

const GA_CONSENT_STORAGE_KEY = "darkbloom_ga_consent";

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
  return Boolean(getGoogleAnalyticsMeasurementId()) && hasGoogleAnalyticsConsent();
}

export function hasGoogleAnalyticsConsent() {
  if (typeof window === "undefined") {
    return false;
  }

  return window.localStorage.getItem(GA_CONSENT_STORAGE_KEY) === "granted";
}

export function grantGoogleAnalyticsConsent() {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.setItem(GA_CONSENT_STORAGE_KEY, "granted");
}

export function revokeGoogleAnalyticsConsent() {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.setItem(GA_CONSENT_STORAGE_KEY, "denied");
}

export function getGoogleAnalyticsConsentStorageKey() {
  return GA_CONSENT_STORAGE_KEY;
}

function getGtag() {
  const measurementId = getGoogleAnalyticsMeasurementId();
  if (typeof window === "undefined" || !measurementId || !hasGoogleAnalyticsConsent()) {
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
  return UTM_QUERY_PARAMS.has(name) || ATTRIBUTION_QUERY_PARAMS.has(name);
}

function sanitizeReferrer(referrer: string) {
  if (!referrer) {
    return undefined;
  }

  try {
    const referrerUrl = new URL(referrer);
    referrerUrl.search = "";
    referrerUrl.hash = "";
    return referrerUrl.toString();
  } catch {
    return undefined;
  }
}

function sanitizeTrackedLocation(location: string) {
  try {
    const url = new URL(location);
    const attributionParams = new URLSearchParams();

    for (const [name, value] of url.searchParams) {
      if (isAllowedAttributionParam(name)) {
        attributionParams.append(name, value);
      }
    }

    url.search = attributionParams.toString();
    url.hash = "";
    return url.toString();
  } catch {
    return undefined;
  }
}

function getTrackedCurrentLocation() {
  if (typeof window === "undefined") {
    return undefined;
  }

  return sanitizeTrackedLocation(window.location.href);
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

type GoogleAnalyticsEventValue = string | number | boolean | undefined;

type GoogleAnalyticsEventParams = Record<string, GoogleAnalyticsEventValue>;

function sanitizeEventParams(params: GoogleAnalyticsEventParams = {}) {
  const sanitized: GoogleAnalyticsEventParams = {};

  for (const [key, value] of Object.entries(params)) {
    if (value === undefined) {
      continue;
    }
    sanitized[key] = value;
  }

  return sanitized;
}

export function trackEvent(
  eventName: string,
  params: GoogleAnalyticsEventParams = {},
) {
  const analytics = getGtag();
  if (!analytics || !eventName) {
    return;
  }

  analytics.gtag("event", eventName, {
    page_location: getTrackedCurrentLocation(),
    page_referrer:
      (window.__googleAnalyticsLastPageLocation
        ? sanitizeTrackedLocation(window.__googleAnalyticsLastPageLocation)
        : undefined) || sanitizeReferrer(document.referrer),
    ...sanitizeEventParams(params),
    send_to: analytics.measurementId,
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
    (window.__googleAnalyticsLastPageLocation
      ? sanitizeTrackedLocation(window.__googleAnalyticsLastPageLocation)
      : undefined) ||
    sanitizeReferrer(document.referrer);

  analytics.gtag("event", "page_view", {
    ...params,
    page_referrer: pageReferrer,
    send_to: analytics.measurementId,
  });

  window.__googleAnalyticsLastPageLocation = params.page_location;
}

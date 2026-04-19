import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  buildTrackedPageLocation,
  getGoogleAnalyticsConsentStatus,
  grantGoogleAnalyticsConsent,
  hasGoogleAnalyticsConsent,
  initializeGoogleAnalytics,
  isGoogleAnalyticsEnabled,
  revokeGoogleAnalyticsConsent,
  trackEvent,
  trackRouteChange,
} from "@/lib/google-analytics";

declare global {
  interface Window {
    __googleAnalyticsInitialized?: boolean;
    __googleAnalyticsCurrentPageLocation?: string;
    __googleAnalyticsCurrentPageReferrer?: string;
    dataLayer?: unknown[];
    gtag?: (...args: unknown[]) => void;
  }
}

describe("google analytics helpers", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.stubEnv("NEXT_PUBLIC_GA_MEASUREMENT_ID", "G-TEST123");
    window.__googleAnalyticsInitialized = undefined;
    window.__googleAnalyticsCurrentPageLocation = undefined;
    window.__googleAnalyticsCurrentPageReferrer = undefined;
    window.dataLayer = [];
    window.gtag = undefined;
    localStorage.removeItem("darkbloom_ga_consent");
    window.history.replaceState({}, "", "/?token=secret&utm_source=search&gclid=abc123");
    document.title = "Darkbloom";
  });

  it("enables analytics only when the measurement id exists", () => {
    expect(isGoogleAnalyticsEnabled()).toBe(false);
  });

  it("requires explicit consent before enabling analytics", () => {
    expect(getGoogleAnalyticsConsentStatus()).toBe("unset");
    expect(hasGoogleAnalyticsConsent()).toBe(false);
    grantGoogleAnalyticsConsent();
    expect(getGoogleAnalyticsConsentStatus()).toBe("granted");
    expect(hasGoogleAnalyticsConsent()).toBe(true);
    expect(isGoogleAnalyticsEnabled()).toBe(true);
    revokeGoogleAnalyticsConsent();
    expect(getGoogleAnalyticsConsentStatus()).toBe("denied");
    expect(hasGoogleAnalyticsConsent()).toBe(false);
    expect(window.__googleAnalyticsInitialized).toBe(false);
  });

  it("keeps only allowed attribution params on the initial page view", () => {
    const origin = window.location.origin;
    grantGoogleAnalyticsConsent();
    const trackedLocation = buildTrackedPageLocation("/pricing");

    expect(trackedLocation).toBe(
      `${origin}/pricing?utm_source=search&gclid=abc123`,
    );
  });

  it("drops unapproved utm-style params on the initial page view", () => {
    const origin = window.location.origin;
    grantGoogleAnalyticsConsent();
    window.history.replaceState(
      {},
      "",
      "/?utm_source=search&utm_secret=leak&utm_campaign=spring&gclid=abc123",
    );

    const trackedLocation = buildTrackedPageLocation("/pricing");

    expect(trackedLocation).toBe(
      `${origin}/pricing?utm_source=search&utm_campaign=spring&gclid=abc123`,
    );
  });

  it("drops query params after the initial page view", () => {
    const origin = window.location.origin;
    grantGoogleAnalyticsConsent();
    window.__googleAnalyticsCurrentPageLocation = `${origin}/?utm_source=search&gclid=abc123`;
    window.history.replaceState({}, "", "/settings?invite=abc&utm_campaign=spring");

    const trackedLocation = buildTrackedPageLocation("/settings");

    expect(trackedLocation).toBe(`${origin}/settings`);
  });

  it("initializes gtag with manual pageview mode and tracks sanitized routes", () => {
    const origin = window.location.origin;
    grantGoogleAnalyticsConsent();
    Object.defineProperty(document, "referrer", {
      configurable: true,
      value: `${origin}/login?next=%2Fbilling&invite=secret&utm_source=mail`,
    });
    initializeGoogleAnalytics();
    trackRouteChange("/billing");

    expect(window.dataLayer).toEqual([
      ["js", expect.any(Date)],
      ["config", "G-TEST123", { send_page_view: false }],
      [
        "event",
        "page_view",
        {
          page_location: `${origin}/billing?utm_source=search&gclid=abc123`,
          page_referrer: `${origin}/login`,
          page_title: "Darkbloom",
          send_to: "G-TEST123",
        },
      ],
    ]);
  });

  it("uses the sanitized initial page location as the next page referrer", () => {
    const origin = window.location.origin;
    grantGoogleAnalyticsConsent();
    Object.defineProperty(document, "referrer", {
      configurable: true,
      value: `${origin}/login?next=%2Fbilling&invite=secret`,
    });
    window.history.replaceState(
      {},
      "",
      "/?utm_source=search&utm_secret=leak&utm_campaign=spring&gclid=abc123",
    );
    initializeGoogleAnalytics();
    trackRouteChange("/billing");
    trackRouteChange("/settings");

    expect(window.dataLayer).toEqual([
      ["js", expect.any(Date)],
      ["config", "G-TEST123", { send_page_view: false }],
      [
        "event",
        "page_view",
        {
          page_location:
            `${origin}/billing?utm_source=search&utm_campaign=spring&gclid=abc123`,
          page_referrer: `${origin}/login`,
          page_title: "Darkbloom",
          send_to: "G-TEST123",
        },
      ],
      [
        "event",
        "page_view",
        {
          page_location: `${origin}/settings`,
          page_referrer:
            `${origin}/billing?utm_source=search&utm_campaign=spring&gclid=abc123`,
          page_title: "Darkbloom",
          send_to: "G-TEST123",
        },
      ],
    ]);
  });

  it("attaches sanitized page context to custom events", () => {
    const origin = window.location.origin;
    grantGoogleAnalyticsConsent();
    Object.defineProperty(document, "referrer", {
      configurable: true,
      value: `${origin}/login?next=%2Fbilling&invite=secret`,
    });
    window.history.replaceState(
      {},
      "",
      "/?utm_source=search&utm_secret=leak&utm_campaign=spring&gclid=abc123",
    );

    initializeGoogleAnalytics();
    trackEvent("login_cta_clicked", {
      source: "login_page",
    });

    expect(window.dataLayer).toEqual([
      ["js", expect.any(Date)],
      ["config", "G-TEST123", { send_page_view: false }],
      [
        "event",
        "login_cta_clicked",
        {
          source: "login_page",
          page_location:
            `${origin}/?utm_source=search&utm_campaign=spring&gclid=abc123`,
          page_referrer: `${origin}/login`,
          send_to: "G-TEST123",
        },
      ],
    ]);
  });

  it("uses the tracked current page context for custom events after navigation", () => {
    const origin = window.location.origin;
    grantGoogleAnalyticsConsent();
    Object.defineProperty(document, "referrer", {
      configurable: true,
      value: `${origin}/login?next=%2Fbilling&invite=secret`,
    });
    window.history.replaceState(
      {},
      "",
      "/?utm_source=search&utm_secret=leak&utm_campaign=spring&gclid=abc123",
    );

    initializeGoogleAnalytics();
    trackRouteChange("/billing");
    trackEvent("chat_submit", {
      model: "mlx-community/gemma-4-26b-a4b-it-8bit",
    });

    expect(window.dataLayer).toEqual([
      ["js", expect.any(Date)],
      ["config", "G-TEST123", { send_page_view: false }],
      [
        "event",
        "page_view",
        {
          page_location:
            `${origin}/billing?utm_source=search&utm_campaign=spring&gclid=abc123`,
          page_referrer: `${origin}/login`,
          page_title: "Darkbloom",
          send_to: "G-TEST123",
        },
      ],
      [
        "event",
        "chat_submit",
        {
          model: "mlx-community/gemma-4-26b-a4b-it-8bit",
          page_location:
            `${origin}/billing?utm_source=search&utm_campaign=spring&gclid=abc123`,
          page_referrer: `${origin}/login`,
          send_to: "G-TEST123",
        },
      ],
    ]);
  });
});

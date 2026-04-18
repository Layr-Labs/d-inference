import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  buildTrackedPageLocation,
  initializeGoogleAnalytics,
  isGoogleAnalyticsEnabled,
  trackRouteChange,
} from "@/lib/google-analytics";

declare global {
  interface Window {
    __googleAnalyticsInitialized?: boolean;
    __googleAnalyticsLastPageLocation?: string;
    dataLayer?: unknown[];
    gtag?: (...args: unknown[]) => void;
  }
}

describe("google analytics helpers", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.stubEnv("NEXT_PUBLIC_GA_MEASUREMENT_ID", "G-TEST123");
    window.__googleAnalyticsInitialized = undefined;
    window.__googleAnalyticsLastPageLocation = undefined;
    window.dataLayer = [];
    window.gtag = undefined;
    window.history.replaceState({}, "", "/?token=secret&utm_source=search&gclid=abc123");
    document.title = "Darkbloom";
  });

  it("enables analytics only when the measurement id exists", () => {
    expect(isGoogleAnalyticsEnabled()).toBe(true);
  });

  it("keeps only allowed attribution params on the initial page view", () => {
    const origin = window.location.origin;
    const trackedLocation = buildTrackedPageLocation("/pricing");

    expect(trackedLocation).toBe(
      `${origin}/pricing?utm_source=search&gclid=abc123`,
    );
  });

  it("drops query params after the initial page view", () => {
    const origin = window.location.origin;
    window.__googleAnalyticsLastPageLocation = `${origin}/?utm_source=search&gclid=abc123`;
    window.history.replaceState({}, "", "/settings?invite=abc&utm_campaign=spring");

    const trackedLocation = buildTrackedPageLocation("/settings");

    expect(trackedLocation).toBe(`${origin}/settings`);
  });

  it("initializes gtag with manual pageview mode and tracks sanitized routes", () => {
    const origin = window.location.origin;
    Object.defineProperty(document, "referrer", {
      configurable: true,
      value: "https://google.com/",
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
          page_referrer: "https://google.com/",
          page_title: "Darkbloom",
          send_to: "G-TEST123",
        },
      ],
    ]);
  });
});

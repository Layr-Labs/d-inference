"use client";

import { useEffect } from "react";
import { useAuth } from "@/hooks/useAuth";

/**
 * Initializes Datadog Real User Monitoring (RUM) when the required env vars
 * are set. Tracks: page views, user interactions, browser errors, resources,
 * long tasks, and session replay.
 *
 * Env vars:
 *   NEXT_PUBLIC_DD_APPLICATION_ID -- DD RUM application ID
 *   NEXT_PUBLIC_DD_CLIENT_TOKEN   -- DD RUM client token
 *   NEXT_PUBLIC_DD_SITE           -- DD site (default "datadoghq.com")
 *
 * When authenticated, the user's identity (id + email) is attached to the
 * RUM session for user-scoped debugging in Datadog.
 */
export function DatadogRUM() {
  const { user, authenticated } = useAuth();

  useEffect(() => {
    const applicationId = process.env.NEXT_PUBLIC_DD_APPLICATION_ID;
    const clientToken = process.env.NEXT_PUBLIC_DD_CLIENT_TOKEN;

    if (!applicationId || !clientToken) {
      return;
    }

    const site = process.env.NEXT_PUBLIC_DD_SITE || "datadoghq.com";

    async function initRUM() {
      const { datadogRum } = await import("@datadog/browser-rum");
      if (datadogRum.getInternalContext()) {
        return;
      }
      datadogRum.init({
        applicationId: applicationId as string,
        clientToken: clientToken as string,
        site,
        service: "darkbloom-console",
        env: process.env.NEXT_PUBLIC_DD_ENV || "production",
        version: process.env.NEXT_PUBLIC_APP_VERSION || "dev",
        sessionSampleRate: 100,
        sessionReplaySampleRate: 20,
        trackUserInteractions: true,
        trackResources: true,
        trackLongTasks: true,
        defaultPrivacyLevel: "mask-user-input",
      });
    }

    initRUM().catch(() => {
      // DD RUM init failed — silently degrade.
    });
  }, []);

  // Track user identity when authenticated.
  useEffect(() => {
    if (!authenticated || !user) return;

    const applicationId = process.env.NEXT_PUBLIC_DD_APPLICATION_ID;
    if (!applicationId) return;

    async function setUser() {
      const { datadogRum } = await import("@datadog/browser-rum");
      datadogRum.setUser({
        id: user?.userId || user?.id || "",
        email: user?.email?.address || "",
      });
    }

    setUser().catch(() => {
      // Silently degrade.
    });
  }, [authenticated, user]);

  return null;
}

"use client";

import { useEffect } from "react";
import { useAuth } from "@/hooks/useAuth";

export function privacySafeRumConfig(
  applicationId: string,
  clientToken: string,
  site: string,
) {
  return {
    applicationId,
    clientToken,
    site,
    service: "darkbloom-console",
    env: process.env.NEXT_PUBLIC_DD_ENV || "production",
    version: process.env.NEXT_PUBLIC_APP_VERSION || "dev",
    sessionSampleRate: 100,
    sessionReplaySampleRate: 0,
    startSessionReplayRecordingManually: true,
    trackUserInteractions: true,
    trackResources: true,
    trackLongTasks: true,
    enablePrivacyForActionName: true,
    defaultPrivacyLevel: "mask" as const,
  };
}

/**
 * Initializes metadata-only Datadog RUM when configured. Session replay is
 * disabled and all DOM text is masked so prompts, responses, and rehydrated
 * history cannot leave the browser through observability.
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
      if (!datadogRum.getInternalContext()) {
        datadogRum.init(privacySafeRumConfig(applicationId, clientToken, site));
      }
      // Defense in depth for hot reloads or a previously initialized SDK.
      datadogRum.stopSessionReplayRecording();
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

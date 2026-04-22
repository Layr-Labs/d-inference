"use client";

import { useEffect } from "react";
import { installGlobalHandlers, emit } from "@/lib/telemetry";

/**
 * Mounts once at app start. Installs window.error /
 * unhandledrejection forwarders that send events to the
 * coordinator via /api/telemetry, and emits a session_start log.
 *
 * When Datadog RUM is active (NEXT_PUBLIC_DD_APPLICATION_ID set), browser
 * errors are captured natively by RUM. The coordinator pipeline remains as
 * a secondary path for operational telemetry from providers/app.
 */
export function TelemetryInitializer() {
  useEffect(() => {
    installGlobalHandlers();
    emit({
      kind: "log",
      severity: "info",
      message: "console session start",
      fields: {
        url: window.location.href,
        user_agent: navigator.userAgent,
        route: window.location.pathname,
      },
    });
  }, []);
  return null;
}

"use client";

import { useEffect } from "react";
import { installGlobalHandlers, emit } from "@/lib/telemetry";

/**
 * Mounts once at app start. Installs window.error /
 * unhandledrejection forwarders that send events to the
 * coordinator via /api/telemetry, and emits a session_start log.
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

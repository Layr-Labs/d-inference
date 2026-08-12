"use client";

import { useEffect } from "react";
import { installGlobalHandlers, emit } from "@/lib/telemetry";

/**
 * Compatibility mount for the disabled client-telemetry facade. No browser
 * error, URL, stack, or session data leaves the page through this component.
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

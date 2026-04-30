"use client";

import { useEffect } from "react";
import { emit } from "@/lib/telemetry";

/**
 * Next.js global error boundary. Renders a fallback UI and reports the
 * exception to the coordinator. Only fires when an unrecoverable error
 * escapes every other boundary.
 */
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    emit({
      kind: "http_error",
      severity: "fatal",
      message: error.message || "unknown render error",
      fields: {
        error_class: error.name,
        route: typeof window !== "undefined" ? window.location.pathname : "",
      },
      stack: error.stack,
    });
  }, [error]);

  return (
    <html lang="en">
      <body>
        <div
          style={{
            padding: "2rem",
            fontFamily: "system-ui, sans-serif",
            color: "#fff",
            background: "#0a0a0a",
            minHeight: "100vh",
          }}
        >
          <h1>Something went wrong</h1>
          <p>The error has been reported automatically.</p>
          <pre
            style={{
              fontSize: "0.875rem",
              opacity: 0.6,
              marginTop: "1rem",
              maxWidth: "640px",
              overflow: "auto",
            }}
          >
            {error.message}
          </pre>
          <button
            onClick={reset}
            style={{
              marginTop: "1.5rem",
              padding: "0.5rem 1rem",
              background: "#fff",
              color: "#0a0a0a",
              border: "none",
              borderRadius: "0.25rem",
              cursor: "pointer",
            }}
          >
            Try again
          </button>
        </div>
      </body>
    </html>
  );
}

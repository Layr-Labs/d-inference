// Browser-side telemetry client.
//
// Sends a debounced batch of events to /api/telemetry, which proxies to the
// coordinator. The server-side allowlist is authoritative; we also filter
// client-side so we don't waste bandwidth on fields that will be dropped.

import {
  TELEMETRY_ALLOWED_FIELDS,
  type TelemetryEvent,
  type TelemetryKind,
  type TelemetrySeverity,
} from "./telemetry-types";

const MAX_BUFFER = 200;
const FLUSH_DEBOUNCE_MS = 2000;
const INGEST_PATH = "/api/telemetry";

const sessionId = (() => {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  const buf = new Uint8Array(16);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => b.toString(16).padStart(2, "0")).join("");
})();

let buffer: TelemetryEvent[] = [];
let flushTimer: ReturnType<typeof setTimeout> | null = null;
let initialized = false;

function nowIso(): string {
  return new Date().toISOString();
}

function newId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  // Fallback to a pseudo-UUID; server still mints a real one if missing.
  return `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function filterFields(input: Record<string, unknown> | undefined): Record<string, unknown> | undefined {
  if (!input) return undefined;
  const out: Record<string, unknown> = {};
  let any = false;
  for (const [k, v] of Object.entries(input)) {
    if (TELEMETRY_ALLOWED_FIELDS.has(k)) {
      out[k] = v;
      any = true;
    }
  }
  return any ? out : undefined;
}

function scheduleFlush() {
  if (flushTimer) return;
  flushTimer = setTimeout(flushBuffer, FLUSH_DEBOUNCE_MS);
}

async function flushBuffer() {
  flushTimer = null;
  if (buffer.length === 0) return;
  const batch = buffer.splice(0, Math.min(buffer.length, 100));
  const body = JSON.stringify({ events: batch });

  // Use sendBeacon when available — survives page unload.
  if (typeof navigator !== "undefined" && "sendBeacon" in navigator) {
    const blob = new Blob([body], { type: "application/json" });
    const ok = navigator.sendBeacon(INGEST_PATH, blob);
    if (ok) return;
  }

  try {
    await fetch(INGEST_PATH, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      keepalive: true,
    });
  } catch {
    // Requeue oldest-first up to the cap; newer events stay in place so live
    // errors after a network hiccup aren't drowned by replay.
    buffer = [...batch, ...buffer].slice(0, MAX_BUFFER);
    scheduleFlush();
  }
}

export interface EmitOptions {
  kind: TelemetryKind;
  severity: TelemetrySeverity;
  message: string;
  fields?: Record<string, unknown>;
  stack?: string;
  requestId?: string;
}

export function emit(opts: EmitOptions) {
  if (typeof window === "undefined") return;
  const event: TelemetryEvent = {
    id: newId(),
    timestamp: nowIso(),
    source: "console",
    severity: opts.severity,
    kind: opts.kind,
    message: opts.message,
    version: process.env.NEXT_PUBLIC_APP_VERSION ?? "dev",
    session_id: sessionId,
    request_id: opts.requestId,
    fields: filterFields(opts.fields),
    stack: opts.stack,
  };
  buffer.push(event);
  if (buffer.length > MAX_BUFFER) {
    buffer.shift();
  }
  scheduleFlush();
}

/** Register global handlers. Idempotent. */
export function installGlobalHandlers() {
  if (initialized || typeof window === "undefined") return;
  initialized = true;

  window.addEventListener("error", (ev) => {
    emit({
      kind: "http_error",
      severity: "error",
      message: ev.message || "window.error",
      fields: {
        url: ev.filename ?? location.href,
        route: location.pathname,
      },
      stack: ev.error instanceof Error ? ev.error.stack : undefined,
    });
  });

  window.addEventListener("unhandledrejection", (ev) => {
    const reason = ev.reason as unknown;
    const msg =
      reason instanceof Error
        ? reason.message
        : typeof reason === "string"
          ? reason
          : JSON.stringify(reason);
    emit({
      kind: "http_error",
      severity: "error",
      message: `unhandled promise rejection: ${msg.slice(0, 200)}`,
      fields: { route: location.pathname },
      stack: reason instanceof Error ? reason.stack : undefined,
    });
  });

  // Flush on page hide — sendBeacon covers the unload edge.
  window.addEventListener("pagehide", () => {
    void flushBuffer();
  });
}

/** Exposed for tests. */
export function _resetForTest() {
  buffer = [];
  if (flushTimer) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  initialized = false;
}

/** Exposed for tests. */
export function _bufferSize(): number {
  return buffer.length;
}

// Client-safe coordinator base URL resolution.
//
// The server resolver lives in lib/server/coordinator.ts (it imports
// next/server and must never be bundled to the client). This module is the
// browser counterpart: it honors the user's localStorage override, then the
// public env var, then the prod default — collapsing the
// `localStorage || NEXT_PUBLIC || "https://api.darkbloom.dev"` chain that was
// copy-pasted across settings, setup, earnings, encryption, etc. (proposal F6).

import { STORAGE_KEYS } from "./constants";

const DEFAULT_COORDINATOR_URL = "https://api.darkbloom.dev";

/** The build-time coordinator URL (env, with a prod default). SSR-safe. */
export const PUBLIC_COORDINATOR_URL =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || DEFAULT_COORDINATOR_URL;

/**
 * The coordinator URL the browser should talk to: the user's localStorage
 * override when present, else {@link PUBLIC_COORDINATOR_URL}. Falls back to the
 * public URL during SSR (no window).
 */
export function clientCoordinatorUrl(): string {
  if (typeof window === "undefined") return PUBLIC_COORDINATOR_URL;
  return window.localStorage.getItem(STORAGE_KEYS.coordinatorUrl) || PUBLIC_COORDINATOR_URL;
}

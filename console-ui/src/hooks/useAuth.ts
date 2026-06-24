"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useAuthContext } from "@/components/providers/PrivyClientProvider";
import { trackEvent } from "@/lib/google-analytics";
import { STORAGE_KEYS } from "@/lib/constants";

const API_KEY_STORAGE = STORAGE_KEYS.apiKey;
const OLD_API_KEY_STORAGE = STORAGE_KEYS.legacyApiKey;
const COORD_URL_STORAGE = STORAGE_KEYS.coordinatorUrl;

// How long to stop re-attempting auto-provision after a failed/rate-limited
// response, so a page that mounts useAuth many times cannot turn one failure
// into a sustained request storm.
const PROVISION_FAILURE_COOLDOWN_MS = 30_000;

// Module-level (one per browser tab) so EVERY useAuth instance shares a single
// in-flight provision. The provider dashboard mounts useAuth many times at once
// (the fleet hook, one per machine's RemoveMachineButton, the sidebar, RUM),
// and a provider account often has no inference key yet — so without coalescing
// each instance fires POST /api/auth/keys simultaneously. That burst trips the
// coordinator's financial rate limit, every response then comes back without an
// api_key, the localStorage guard never engages, and the burst repeats: a
// browser-side self-DoS. One shared promise + a post-failure cooldown bounds it
// to a single request that, on success, persists the key for all callers.
let provisionInFlight: Promise<string | null> | null = null;
let provisionBlockedUntil = 0;

// Clear the provision backoff/in-flight state. Called on logout so a fast
// re-login isn't blocked by a stale cooldown from the previous session.
export function resetConsoleKeyProvisionBackoff(): void {
  provisionInFlight = null;
  provisionBlockedUntil = 0;
}

// Provision (or reuse) the console's inference API key, deduped across all
// concurrent callers in the tab. Resolves to the key, or null when none could
// be obtained (no token, rate-limited, or error) — callers treat null as
// "not ready".
async function provisionConsoleKey(
  getToken: () => Promise<string | null>,
): Promise<string | null> {
  if (typeof window === "undefined") return null;

  const existing = localStorage.getItem(API_KEY_STORAGE);
  if (existing) return existing;

  // Coalesce: hand every concurrent caller the same in-flight request.
  if (provisionInFlight) return provisionInFlight;
  // Back off after a recent failure instead of hammering the endpoint.
  if (Date.now() < provisionBlockedUntil) return null;

  provisionInFlight = (async () => {
    try {
      const token = await getToken().catch(() => null);
      if (!token) return null;
      const res = await fetch("/api/auth/keys", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
        },
      });
      const data = (await res.json().catch(() => ({}))) as { api_key?: string };
      if (res.ok && data.api_key) {
        localStorage.setItem(API_KEY_STORAGE, data.api_key);
        return data.api_key;
      }
      // Rate-limited / error / keyless response: arm the cooldown so a
      // multi-mount page can't spin on it.
      provisionBlockedUntil = Date.now() + PROVISION_FAILURE_COOLDOWN_MS;
      return null;
    } catch (err) {
      console.warn("[useAuth] Key provisioning failed:", err);
      provisionBlockedUntil = Date.now() + PROVISION_FAILURE_COOLDOWN_MS;
      return null;
    } finally {
      provisionInFlight = null;
    }
  })();

  return provisionInFlight;
}

export function useAuth() {
  const { ready, authenticated, user, login, logout: privyLogout, getAccessToken } = useAuthContext();
  const [apiKeyReady, setApiKeyReady] = useState(false);

  // Derive useful fields from the Privy user
  const email = (user as { email?: { address?: string } } | null)?.email?.address || null;

  const displayName = email || null;

  // Single provisioning path: fetch a fresh inference key with the Privy token
  // and store it. Used by both the mount effect and the key-expired handler so
  // the sequence lives in one place (proposal F8).
  const provisionApiKey = useCallback(async () => {
    const key = await provisionConsoleKey(getAccessToken);
    setApiKeyReady(!!key);
  }, [getAccessToken]);

  // Migrate old API key and auto-provision on auth.
  useEffect(() => {
    if (!authenticated || typeof window === "undefined") return;

    const oldKey = localStorage.getItem(OLD_API_KEY_STORAGE);
    if (oldKey && !localStorage.getItem(API_KEY_STORAGE)) {
      localStorage.setItem(API_KEY_STORAGE, oldKey);
      localStorage.removeItem(OLD_API_KEY_STORAGE);
    }

    if (localStorage.getItem(API_KEY_STORAGE)) {
      setApiKeyReady(true);
      return;
    }

    provisionApiKey();
  }, [authenticated, provisionApiKey]);

  // Re-provision API key when it expires (401 from streamChat).
  useEffect(() => {
    if (!authenticated) return;
    const handleExpired = () => {
      setApiKeyReady(false);
      provisionApiKey();
    };
    window.addEventListener("darkbloom-key-expired", handleExpired);
    return () => window.removeEventListener("darkbloom-key-expired", handleExpired);
  }, [authenticated, provisionApiKey]);

  // Reset when logged out
  useEffect(() => {
    if (!authenticated) setApiKeyReady(false);
  }, [authenticated]);

  // Track login_success event once when the user authenticates
  const hasTrackedLogin = useRef(false);
  useEffect(() => {
    if (authenticated && !hasTrackedLogin.current) {
      hasTrackedLogin.current = true;
      trackEvent("login_success", { method: email ? "email" : "unknown" });
    }
    if (!authenticated) {
      hasTrackedLogin.current = false;
    }
  }, [authenticated, email]);

  // Clear all app-specific localStorage on login to prevent session poisoning
  // (e.g. attacker pre-sets coordinator URL before victim logs in).
  useEffect(() => {
    if (!authenticated || typeof window === "undefined") return;
    localStorage.removeItem(COORD_URL_STORAGE);
  }, [authenticated]);

  const logout = useCallback(async () => {
    if (typeof window !== "undefined") {
      localStorage.removeItem(API_KEY_STORAGE);
      localStorage.removeItem(OLD_API_KEY_STORAGE);
      localStorage.removeItem(COORD_URL_STORAGE);
    }
    // Drop any provision cooldown/in-flight so a re-login provisions promptly.
    resetConsoleKeyProvisionBackoff();
    await privyLogout();
  }, [privyLogout]);

  return {
    ready,
    authenticated,
    apiKeyReady,
    user,
    login,
    logout,
    getAccessToken,
    email,
    displayName,
  };
}

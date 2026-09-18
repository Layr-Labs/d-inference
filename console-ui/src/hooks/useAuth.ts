"use client";

import { useCallback, useEffect, useRef } from "react";
import { useAuthContext } from "@/components/app-providers/PrivyClientProvider";
import { trackEvent } from "@/lib/google-analytics";
import { STORAGE_KEYS } from "@/lib/storage-keys";
import { clearConsoleApiKey, writeUntrackedConsoleApiKey } from "@/lib/console-api-key";

const API_KEY_STORAGE = STORAGE_KEYS.apiKey;
const OLD_API_KEY_STORAGE = STORAGE_KEYS.legacyApiKey;
const COORD_URL_STORAGE = STORAGE_KEYS.coordinatorUrl;

export function useAuth() {
  const { ready, authenticated, user, login, logout: privyLogout, getAccessToken } = useAuthContext();

  // Derive useful fields from the Privy user
  const email = user?.email?.address || null;

  const displayName = email || null;

  // Preserve legacy secrets for explicit API-key workflows. Identity hooks must
  // never mint inference keys as a side effect of mounting shared UI.
  useEffect(() => {
    if (!authenticated || typeof window === "undefined") return;
    const oldKey = localStorage.getItem(OLD_API_KEY_STORAGE);
    if (oldKey && !localStorage.getItem(API_KEY_STORAGE)) {
      writeUntrackedConsoleApiKey(oldKey);
      localStorage.removeItem(OLD_API_KEY_STORAGE);
    }
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
      clearConsoleApiKey();
      localStorage.removeItem(COORD_URL_STORAGE);
    }
    await privyLogout();
  }, [privyLogout]);

  return {
    ready,
    authenticated,
    sessionReady: ready && authenticated,
    user,
    login,
    logout,
    getAccessToken,
    email,
    displayName,
  };
}

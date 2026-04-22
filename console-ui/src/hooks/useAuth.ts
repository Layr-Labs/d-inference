"use client";

import { useCallback, useEffect, useState } from "react";
import { useAuthContext } from "@/components/providers/PrivyClientProvider";

const API_KEY_STORAGE = "darkbloom_api_key";
const OLD_API_KEY_STORAGE = "eigeninference_api_key";
const COORD_URL_STORAGE = "darkbloom_coordinator_url";

export function useAuth() {
  const { ready, authenticated, user, login, logout: privyLogout, getAccessToken } = useAuthContext();
  const [apiKeyReady, setApiKeyReady] = useState(false);

  // Derive useful fields from the Privy user
  const email = (user as { email?: { address?: string } } | null)?.email?.address || null;

  const displayName = email || null;

  // Migrate old API key and auto-provision on auth
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

    getAccessToken().then((token) => {
      if (!token) return;
      fetch("/api/auth/keys", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
        },
      })
        .then((res) => res.json())
        .then((data) => {
          if (data.api_key) {
            localStorage.setItem(API_KEY_STORAGE, data.api_key);
            setApiKeyReady(true);
          } else {
            console.warn("[useAuth] Key provisioning returned no api_key:", data);
            setApiKeyReady(false);
          }
        })
        .catch((err) => {
          console.warn("[useAuth] Key provisioning failed:", err);
          setApiKeyReady(false);
        });
    });
  }, [authenticated, getAccessToken]);

  // Re-provision API key when it expires (401 from streamChat)
  useEffect(() => {
    if (!authenticated) return;
    const handleExpired = () => {
      setApiKeyReady(false);
      getAccessToken().then((token) => {
        if (!token) return;
        fetch("/api/auth/keys", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
          },
        })
          .then((res) => res.json())
          .then((data) => {
            if (data.api_key) {
              localStorage.setItem(API_KEY_STORAGE, data.api_key);
              setApiKeyReady(true);
            } else {
              setApiKeyReady(false);
            }
          })
          .catch(() => setApiKeyReady(false));
      });
    };
    window.addEventListener("darkbloom-key-expired", handleExpired);
    return () => window.removeEventListener("darkbloom-key-expired", handleExpired);
  }, [authenticated, getAccessToken]);

  // Reset when logged out
  useEffect(() => {
    if (!authenticated) setApiKeyReady(false);
  }, [authenticated]);

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

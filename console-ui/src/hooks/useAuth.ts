"use client";

import { useEffect, useMemo, useState } from "react";
import { useAuthContext } from "@/components/providers/PrivyClientProvider";

const API_KEY_STORAGE = "eigeninference_api_key";
const OLD_API_KEY_STORAGE = "eigeninference_api_key";

export function useAuth() {
  const { ready, authenticated, user, login, logout, getAccessToken } = useAuthContext();
  const [apiKeyReady, setApiKeyReady] = useState(false);

  // Derive useful fields from the Privy user
  const email = (user as { email?: { address?: string } } | null)?.email?.address || null;

  const walletAddress = useMemo(() => {
    if (!user) return null;
    const u = user as {
      wallet?: { address?: string };
      linkedAccounts?: Array<{ type: string; chainType?: string; address?: string }>;
    };
    if (u.wallet?.address) return u.wallet.address;
    const solana = u.linkedAccounts?.find(
      (a) => a.type === "wallet" && a.chainType === "solana"
    );
    return solana?.address || null;
  }, [user]);

  const displayName = email || (walletAddress ? `${walletAddress.slice(0, 6)}...${walletAddress.slice(-4)}` : null);

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
          }
          setApiKeyReady(true);
        })
        .catch(() => {
          setApiKeyReady(true);
        });
    });
  }, [authenticated, getAccessToken]);

  // Reset when logged out
  useEffect(() => {
    if (!authenticated) setApiKeyReady(false);
  }, [authenticated]);

  return {
    ready,
    authenticated,
    apiKeyReady,
    user,
    login,
    logout,
    email,
    walletAddress,
    displayName,
  };
}
